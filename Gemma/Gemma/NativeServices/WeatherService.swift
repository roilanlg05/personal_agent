import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

public struct WeatherSnapshot: Codable, Sendable, Equatable {
    public let temperatureCelsius: Double
    public let condition: String
    public let symbolName: String
    public let humidityPercentage: Double
    public let windSpeedKmh: Double
    public let uvIndex: Int
    public let precipitationChance: Double
    public let summary: String

    public init(
        temperatureCelsius: Double,
        condition: String,
        symbolName: String = "sun.max",
        humidityPercentage: Double,
        windSpeedKmh: Double,
        uvIndex: Int,
        precipitationChance: Double,
        summary: String
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.condition = condition
        self.symbolName = symbolName
        self.humidityPercentage = humidityPercentage
        self.windSpeedKmh = windSpeedKmh
        self.uvIndex = uvIndex
        self.precipitationChance = precipitationChance
        self.summary = summary
    }
}

/// Por qué no hay clima. Nunca se sustituye por un valor inventado: el modelo se cree
/// literalmente lo que devuelve el tool y se lo repite al usuario como un hecho.
public enum WeatherServiceError: Error, LocalizedError, Equatable {
    /// No se sabe dónde está el usuario y no se dieron coordenadas.
    case unknownLocation
    /// Llegó media coordenada, o una fuera de rango.
    case invalidCoordinates(String)
    /// El nombre del lugar no se pudo convertir en coordenadas.
    case placeNotFound(String)
    /// WeatherKit no está disponible (falta el entitlement, versión de SO, etc.).
    case providerUnavailable(String)
    /// El momento que se pidió ya pasó: no hay pronóstico que dar de algo pasado.
    case periodInThePast(String)
    /// El servicio contestó, pero sin ninguna hora para ese periodo.
    case noForecastData(String)

    public var errorDescription: String? {
        switch self {
        case .unknownLocation:
            return "No sé dónde estás. Dime la ciudad, o concede el permiso de ubicación."
        case .invalidCoordinates(let reason):
            return "Coordenadas no válidas: \(reason)"
        case .placeNotFound(let name):
            return "No encontré ningún lugar llamado '\(name)'. Pídele al usuario que lo escriba de otra forma."
        case .providerUnavailable(let reason):
            return "El servicio de clima no está disponible: \(reason)"
        case .periodInThePast(let period):
            return "'\(period)' ya pasó. Pregúntale al usuario de qué momento quiere el pronóstico."
        case .noForecastData(let period):
            return "No hay datos de pronóstico para \(period). No inventes una previsión."
        }
    }
}

/// De dónde salió el sitio que se midió.
///
/// Va en la salida del tool porque el modelo tiene que poder decirle al usuario de qué
/// sitio le está hablando. Antes el tool devolvía como "location" la etiqueta que el
/// propio modelo había escrito, así que podía pedir "Miami", recibir el clima de donde
/// estaba el usuario, y contarlo como el clima de Miami.
public enum WeatherLocationSource: String, Sendable {
    case currentLocation = "current_location"
    case coordinates
    case placeName = "place_name"
}

/// Una medición de clima junto con el sitio que de verdad se midió.
public struct WeatherReading: Sendable {
    public let snapshot: WeatherSnapshot
    public let coordinate: CLLocationCoordinate2D
    /// Nombre que el sistema da a ese punto. Nunca lo que escribió el modelo.
    public let resolvedPlace: String?
    public let source: WeatherLocationSource
}

/// Convierte un nombre de lugar en coordenadas.
public protocol PlaceGeocoding: Sendable {
    func coordinate(forPlace name: String) async throws -> (coordinate: CLLocationCoordinate2D, resolvedName: String)
}

/// De dónde sale la ubicación actual del usuario.
///
/// Es un protocolo propio y no `LocationService` directamente para que las pruebas
/// puedan fijar una ciudad conocida sin tocar CoreLocation.
public protocol WeatherLocationProviding: Sendable {
    func currentCoordinate() async throws -> (coordinate: CLLocationCoordinate2D, city: String?)
}

public final class CLPlaceGeocoder: PlaceGeocoding, Sendable {
    public init() {}

    public func coordinate(forPlace name: String) async throws -> (coordinate: CLLocationCoordinate2D, resolvedName: String) {
        let placemarks = try? await CLGeocoder().geocodeAddressString(name)
        guard let placemark = placemarks?.first, let location = placemark.location else {
            throw WeatherServiceError.placeNotFound(name)
        }
        // Se prefiere el nombre que da el sistema: si el usuario escribió "la habana",
        // el usuario merece leer "La Habana, Cuba" y saber que se acertó.
        let resolved = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .first ?? name
        return (location.coordinate, resolved)
    }
}

/// Adaptador sobre el servicio de ubicación compartido.
public final class LocationServiceWeatherLocation: WeatherLocationProviding, Sendable {
    private let locationService: LocationService

    public init(locationService: LocationService = .shared) {
        self.locationService = locationService
    }

    public func currentCoordinate() async throws -> (coordinate: CLLocationCoordinate2D, city: String?) {
        let info = try await locationService.getCurrentLocationInfo()
        return (info.coordinate, info.city ?? info.address)
    }
}

public protocol WeatherProviding: Sendable {
    func weather(for coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot
}

public final class MockWeatherProvider: WeatherProviding, @unchecked Sendable {
    private let lock = NSLock()
    public var cannedSnapshot: WeatherSnapshot?
    public var shouldThrowError: Error?

    /// Coordenadas con las que se consultó. Sirve para comprobar que el servicio usa la
    /// ubicación real del usuario y no unas coordenadas fijas.
    public private(set) var requestedCoordinates: [CLLocationCoordinate2D] = []

    public init(cannedSnapshot: WeatherSnapshot? = nil) {
        self.cannedSnapshot = cannedSnapshot
    }

    public func weather(for coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        lock.lock()
        requestedCoordinates.append(coordinate)
        lock.unlock()

        if let err = shouldThrowError {
            throw err
        }
        if let snapshot = cannedSnapshot {
            return snapshot
        }
        return WeatherSnapshot(
            temperatureCelsius: 22.5,
            condition: "Parcialmente nublado",
            symbolName: "cloud.sun.fill",
            humidityPercentage: 55.0,
            windSpeedKmh: 12.0,
            uvIndex: 4,
            precipitationChance: 10.0,
            summary: "22.5°C, Parcialmente nublado. Viento 12 km/h, probabilidad de lluvia 10%."
        )
    }
}

public final class SystemWeatherProvider: WeatherProviding, Sendable {
    public init() {}

    /// Propaga el fallo de WeatherKit en lugar de devolver un clima de adorno.
    ///
    /// Antes, cualquier error (entitlement ausente, sin red) se convertía en una
    /// constante de 21°C y "Despejado" que la salida del tool no distinguía de una
    /// medición real: el agente se lo contaba al usuario como el tiempo de ahora mismo.
    public func weather(for coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        #if canImport(WeatherKit)
        if #available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *) {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let weatherService = WeatherKit.WeatherService.shared
            let weather = try await weatherService.weather(for: location)
            let current = weather.currentWeather
            let tempC = current.temperature.converted(to: .celsius).value
            let windKmh = current.wind.speed.converted(to: .kilometersPerHour).value
            let precip = weather.hourlyForecast.first?.precipitationChance ?? 0.0

            return WeatherSnapshot(
                temperatureCelsius: (tempC * 10).rounded() / 10,
                condition: current.condition.description,
                symbolName: current.symbolName,
                humidityPercentage: (current.humidity * 100).rounded(),
                windSpeedKmh: (windKmh * 10).rounded() / 10,
                uvIndex: current.uvIndex.value,
                precipitationChance: (precip * 100).rounded(),
                summary: "\(Int(tempC))°C, \(current.condition.description). Viento \(Int(windKmh)) km/h."
            )
        }
        throw WeatherServiceError.providerUnavailable("WeatherKit requiere iOS 16 o macOS 13.")
        #else
        throw WeatherServiceError.providerUnavailable("WeatherKit no está disponible en esta plataforma.")
        #endif
    }
}

public final class WeatherService: Sendable {
    private let provider: any WeatherProviding
    private let forecastProvider: any WeatherForecastProviding
    private let locationProvider: (any WeatherLocationProviding)?
    private let geocoder: any PlaceGeocoding

    /// `locationProvider` apunta por omisión a la ubicación real del usuario, para que
    /// "¿qué tiempo hace?" mida donde está. Antes era `nil` y el servicio caía en unas
    /// coordenadas fijas de San Francisco.
    public init(
        provider: any WeatherProviding = SystemWeatherProvider(),
        forecastProvider: any WeatherForecastProviding = SystemWeatherForecastProvider(),
        locationProvider: (any WeatherLocationProviding)? = LocationServiceWeatherLocation(),
        geocoder: any PlaceGeocoding = CLPlaceGeocoder()
    ) {
        self.provider = provider
        self.forecastProvider = forecastProvider
        self.locationProvider = locationProvider
        self.geocoder = geocoder
    }

    /// El sitio que se va a medir, resuelto a coordenadas.
    ///
    /// Orden de preferencia: coordenadas explícitas, luego nombre de lugar, luego la
    /// ubicación actual. Media coordenada es un error, no una invitación a usar el GPS:
    /// callarse ahí entregaba el clima de otro sitio sin avisar.
    ///
    /// Lo comparten la medición de ahora y el pronóstico: el usuario pregunta por el
    /// mismo sitio de las dos maneras, y la resolución no debe diferir entre ellas.
    private func resolveLocation(
        latitude: Double?,
        longitude: Double?,
        place: String?
    ) async throws -> (coordinate: CLLocationCoordinate2D, resolvedPlace: String?, source: WeatherLocationSource) {
        if latitude != nil || longitude != nil {
            guard let lat = latitude, let lon = longitude else {
                throw WeatherServiceError.invalidCoordinates(
                    "Hacen falta latitud y longitud juntas; llegó solo una."
                )
            }
            guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw WeatherServiceError.invalidCoordinates(
                    "Latitud debe estar entre -90 y 90, y longitud entre -180 y 180."
                )
            }
            // Sin nombre: las coordenadas son el dato, y el nombre que hubiera puesto
            // el modelo no las describe necesariamente. El tool reporta la coordenada.
            return (CLLocationCoordinate2D(latitude: lat, longitude: lon), nil, .coordinates)
        }

        if let place, !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let resolved = try await geocoder.coordinate(forPlace: place)
            return (resolved.coordinate, resolved.resolvedName, .placeName)
        }

        guard let locationProvider else {
            // Sin coordenadas, sin nombre y sin ubicación: se dice que no se sabe.
            // Inventar una ciudad era el peor de los resultados posibles.
            throw WeatherServiceError.unknownLocation
        }
        let current = try await locationProvider.currentCoordinate()
        return (current.coordinate, current.city, .currentLocation)
    }

    /// Mide el clima de ahora y dice de qué punto es la medición.
    public func reading(
        latitude: Double?,
        longitude: Double?,
        place: String?
    ) async throws -> WeatherReading {
        let location = try await resolveLocation(latitude: latitude, longitude: longitude, place: place)
        return WeatherReading(
            snapshot: try await provider.weather(for: location.coordinate),
            coordinate: location.coordinate,
            resolvedPlace: location.resolvedPlace,
            source: location.source
        )
    }

    /// Pronostica un momento concreto y dice de qué sitio y de qué horas habla.
    ///
    /// Si el servicio no devuelve ni una hora del periodo pedido, lanza
    /// `noForecastData` en vez de un resumen vacío: un resumen de cero horas se leería
    /// como "0°C y sin lluvia", que es peor que admitir que no se sabe.
    public func forecast(
        period: WeatherPeriod,
        latitude: Double? = nil,
        longitude: Double? = nil,
        place: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) async throws -> WeatherForecastReading {
        guard let interval = period.interval(now: now, timeZone: timeZone) else {
            throw WeatherServiceError.periodInThePast(period.spanishName)
        }
        let location = try await resolveLocation(latitude: latitude, longitude: longitude, place: place)
        let hours = try await forecastProvider.hourlyForecast(
            for: location.coordinate,
            interval: interval
        )
        guard let summary = WeatherForecastSummary(interval: interval, hours: hours) else {
            throw WeatherServiceError.noForecastData(period.spanishName)
        }
        return WeatherForecastReading(
            period: period,
            summary: summary,
            coordinate: location.coordinate,
            resolvedPlace: location.resolvedPlace,
            source: location.source
        )
    }

    var locationProviderForTesting: (any WeatherLocationProviding)? { locationProvider }

    public func getWeather(latitude: Double?, longitude: Double?) async throws -> WeatherSnapshot {
        try await reading(latitude: latitude, longitude: longitude, place: nil).snapshot
    }
}
