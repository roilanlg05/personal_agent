import Foundation
import CoreLocation

public struct UserLocationInfo: Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let horizontalAccuracy: Double
    public let address: String?
    public let city: String?
    public let resolution: SpatialResolutionResult

    public init(
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracy: Double,
        address: String? = nil,
        city: String? = nil,
        resolution: SpatialResolutionResult
    ) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.address = address
        self.city = city
        self.resolution = resolution
    }
}

/// Motivos por los que no hay ubicación. El agente necesita distinguirlos para poder
/// explicarle al usuario qué hacer: pedir el permiso, reintentar, o teclear la dirección.
public enum LocationProviderError: Error, LocalizedError, Equatable {
    /// El usuario denegó (o el sistema restringió) el acceso a la ubicación.
    case permissionDenied
    /// Se agotó el plazo sin que llegara ninguna posición.
    case timedOut(seconds: Double)
    /// El servicio de localización no está disponible en este dispositivo o sesión.
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Gemma no tiene permiso para usar tu ubicación. Puedes concederlo en Ajustes."
        case .timedOut(let seconds):
            return "No se pudo obtener la ubicación en \(Int(seconds)) segundos."
        case .unavailable(let reason):
            return "El servicio de ubicación no está disponible: \(reason)"
        }
    }
}

public protocol LocationProvider: Sendable {
    func requestCurrentLocation() async throws -> CLLocation
    func reverseGeocode(location: CLLocation) async -> (address: String?, city: String?)
}

/// La parte de `CLLocationManager` que `CoreLocationProvider` necesita.
///
/// Existe para poder probar la máquina de estados de autorización y el plazo máximo sin
/// un `CLLocationManager` real, que en un test nunca entrega callbacks.
public protocol LocationHardware: AnyObject {
    var hardwareAuthorizationStatus: CLAuthorizationStatus { get }
    func requestAuthorization()
    func requestOneShotLocation()
}

extension CLLocationManager: LocationHardware {
    public var hardwareAuthorizationStatus: CLAuthorizationStatus { authorizationStatus }
    public func requestAuthorization() { requestWhenInUseAuthorization() }
    public func requestOneShotLocation() { requestLocation() }
}

/// Ubicación real del dispositivo.
///
/// Tres fallos que colgaban el turno del agente para siempre y que esta versión evita:
///
/// 1. La continuación se guardaba en una sola variable sin comprobar si ya había otra
///    pendiente. Dos llamadas solapadas (`get_current_location` y `save_place` sin
///    coordenadas) pisaban la primera, que nunca se reanudaba: continuación filtrada y
///    llamada eterna. Ahora hay un diccionario de peticiones en espera, se lanza una
///    sola petición al hardware y **todas** reciben la misma posición.
/// 2. Con `authorizationStatus == .notDetermined` se pedía el permiso y acto seguido la
///    ubicación, antes de que el usuario hubiera contestado al diálogo: no llegaba
///    ningún callback. Ahora se espera a `locationManagerDidChangeAuthorization` y solo
///    entonces se pide la posición.
/// 3. No había plazo máximo en ningún punto del camino. Ahora cada petición expira y
///    devuelve `LocationProviderError.timedOut`.
public final class CoreLocationProvider: NSObject, CLLocationManagerDelegate, LocationProvider, @unchecked Sendable {
    private let hardware: any LocationHardware
    private let geocoder = CLGeocoder()
    private let timeout: TimeInterval
    private let lock = NSLock()

    /// Peticiones en espera, por identificador: así un plazo agotado reanuda solo la suya.
    private var waiters: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    /// `true` mientras se espera la respuesta del usuario al diálogo de permiso.
    private var awaitingAuthorization = false
    /// `true` cuando ya se le pidió una posición al hardware y aún no ha llegado.
    private var fixInFlight = false
    /// Peticiones que expiraron antes de llegar a registrarse. Sin esto, una petición
    /// que se registra después de su propio plazo quedaría suspendida para siempre.
    private var preFailed: [UUID: Error] = [:]

    public init(hardware: (any LocationHardware)? = nil, timeout: TimeInterval = 12.0) {
        if let hardware {
            self.hardware = hardware
            self.timeout = timeout
            super.init()
        } else {
            let manager = CLLocationManager()
            self.hardware = manager
            self.timeout = timeout
            super.init()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
        }
    }

    /// Cuántas peticiones están esperando ahora mismo. Solo para pruebas.
    var pendingRequestCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    public func requestCurrentLocation() async throws -> CLLocation {
        switch hardware.hardwareAuthorizationStatus {
        case .denied, .restricted:
            throw LocationProviderError.permissionDenied
        default:
            break
        }

        let id = UUID()
        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { try await self.awaitFix(id: id) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, self.timeout) * 1_000_000_000))
                // Reanudar la continuación pendiente es obligatorio: sin esto quedaría
                // filtrada y el motor de concurrencia avisaría de ello.
                self.fail(id: id, with: LocationProviderError.timedOut(seconds: self.timeout))
                throw LocationProviderError.timedOut(seconds: self.timeout)
            }
            guard let first = try await group.next() else {
                throw LocationProviderError.unavailable("sin respuesta del proveedor")
            }
            group.cancelAll()
            return first
        }
    }

    private func awaitFix(id: UUID) async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let alreadyFailed = preFailed.removeValue(forKey: id) {
                lock.unlock()
                continuation.resume(throwing: alreadyFailed)
                return
            }
            waiters[id] = continuation
            let status = hardware.hardwareAuthorizationStatus
            let shouldAskAuthorization = (status == .notDetermined) && !awaitingAuthorization && !fixInFlight
            let shouldAskLocation = (status != .notDetermined) && !fixInFlight
            if shouldAskAuthorization { awaitingAuthorization = true }
            if shouldAskLocation { fixInFlight = true }
            lock.unlock()

            // Una sola petición en vuelo: las llamadas solapadas se encolan y comparten
            // la misma posición cuando llegue.
            if shouldAskAuthorization {
                hardware.requestAuthorization()
            } else if shouldAskLocation {
                hardware.requestOneShotLocation()
            }
        }
    }

    /// Reanuda una única petición con un error, si sigue esperando.
    private func fail(id: UUID, with error: Error) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        if continuation == nil {
            // Expiró antes de registrarse: se deja apuntado para rechazarla al llegar.
            preFailed[id] = error
        }
        if waiters.isEmpty {
            awaitingAuthorization = false
            fixInFlight = false
        }
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func failAll(with error: Error) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        awaitingAuthorization = false
        fixInFlight = false
        lock.unlock()
        for continuation in pending.values { continuation.resume(throwing: error) }
    }

    // MARK: - Puntos de entrada de los callbacks (también usados por las pruebas)

    func handleLocations(_ locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        awaitingAuthorization = false
        fixInFlight = false
        lock.unlock()
        for continuation in pending.values { continuation.resume(returning: location) }
    }

    func handleFailure(_ error: Error) {
        failAll(with: error)
    }

    func handleAuthorizationChange() {
        lock.lock()
        guard awaitingAuthorization, !waiters.isEmpty else {
            lock.unlock()
            return
        }
        let status = hardware.hardwareAuthorizationStatus
        switch status {
        case .notDetermined:
            // El usuario todavía no ha contestado: seguir esperando.
            lock.unlock()
        case .denied, .restricted:
            lock.unlock()
            failAll(with: LocationProviderError.permissionDenied)
        default:
            awaitingAuthorization = false
            fixInFlight = true
            lock.unlock()
            hardware.requestOneShotLocation()
        }
    }

    public func reverseGeocode(location: CLLocation) async -> (address: String?, city: String?) {
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let first = placemarks.first else {
            return (nil, nil)
        }
        let street = [first.subThoroughfare, first.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let address = street.isEmpty ? first.name : street
        return (address, first.locality)
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        handleLocations(locations)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        handleFailure(error)
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange()
    }
}

public final class LocationService: Sendable {
    public let placeStore: PlaceStore
    public let spatialResolver: SpatialResolver
    public let dwellDetector: DwellDetector
    private let locationProvider: any LocationProvider

    /// Servicio único de la app: comparte el almacén de lugares con los tools y es el
    /// que `WeatherService` usa para saber dónde está el usuario de verdad.
    public static let shared = LocationService()

    public init(
        placeStore: PlaceStore = .shared,
        locationProvider: any LocationProvider = CoreLocationProvider(),
        onDwellEvent: (@Sendable (DwellEvent) -> Void)? = nil
    ) {
        self.placeStore = placeStore
        self.spatialResolver = SpatialResolver(placeStore: placeStore)
        self.locationProvider = locationProvider
        self.dwellDetector = DwellDetector(dwellDurationThreshold: 900.0) { event in
            onDwellEvent?(event)
        }
    }

    public func getCurrentLocationInfo() async throws -> UserLocationInfo {
        let location = try await locationProvider.requestCurrentLocation()
        let coord = location.coordinate
        let accuracy = location.horizontalAccuracy

        // Registrar en dwell detector para aprendizaje de estancias
        dwellDetector.recordPosition(coordinate: coord, timestamp: location.timestamp)

        let (address, city) = await locationProvider.reverseGeocode(location: location)
        let resolution = spatialResolver.resolve(coordinate: coord, horizontalAccuracy: accuracy)

        return UserLocationInfo(
            coordinate: coord,
            horizontalAccuracy: accuracy,
            address: address,
            city: city,
            resolution: resolution
        )
    }
}
