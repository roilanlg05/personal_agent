import Foundation
import CoreLocation
#if canImport(MapKit)
import MapKit
#endif

/// A dónde tiene que llegar el usuario.
public struct ReminderDestination: Sendable, Equatable {
    /// Como lo llamó el usuario: "el trabajo", "casa de mi madre".
    public let name: String
    /// Coordenada, si ya se conoce. Si no, se resuelve por el nombre.
    public let coordinate: CLLocationCoordinate2D?

    public init(name: String, coordinate: CLLocationCoordinate2D? = nil) {
        self.name = name
        self.coordinate = coordinate
    }

    public static func == (lhs: ReminderDestination, rhs: ReminderDestination) -> Bool {
        lhs.name == rhs.name
            && lhs.coordinate?.latitude == rhs.coordinate?.latitude
            && lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }
}

public enum ReminderLeadTimeError: Error, LocalizedError, Equatable {
    /// El compromiso es para una hora que ya pasó.
    case dueDateInThePast
    /// No se pudo calcular una ruta hasta ese destino.
    case routeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .dueDateInThePast:
            return "Esa hora ya pasó."
        case .routeUnavailable(let name):
            return "No se pudo calcular cuánto se tarda en llegar a '\(name)'."
        }
    }
}

/// En qué se basó el aviso. El usuario tiene derecho a saberlo: un aviso calculado con
/// el tráfico y uno puesto a una hora fija no merecen la misma confianza.
public enum ReminderLeadTimeBasis: String, Sendable {
    /// Se calculó el tiempo de viaje real hasta el destino.
    case travelTime = "travel_time"
    /// No había destino, o no había ruta: se avisa con la antelación por omisión.
    case fixedHourBefore = "fixed_lead_time"
}

/// Cuándo hay que avisar, y por qué.
public struct ReminderPlan: Sendable, Equatable {
    /// Hora del compromiso.
    public let due: Date
    /// Momento en que Gemma avisa.
    public let alertAt: Date
    /// Hora límite para salir, si se conoce el viaje.
    public let leaveBy: Date?
    /// Duración del viaje en segundos, si se pudo calcular.
    public let travelTime: TimeInterval?
    public let basis: ReminderLeadTimeBasis
    /// `true` si el aviso sale ya porque la hora de salida ideal pasó.
    public let isLate: Bool

    /// Texto del aviso, con las horas en la zona del usuario.
    ///
    /// Dice la hora de salida y la de llegada porque es lo que el usuario necesita
    /// decidir en ese momento: "tienes que salir a las 08:15 para llegar a las 08:30".
    public func message(title: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone

        guard let leaveBy else {
            return "Recuerda: \(title) a las \(formatter.string(from: due))."
        }
        let leave = formatter.string(from: leaveBy)
        let arrive = formatter.string(from: due)
        if isLate {
            return "Sal ya para \(title): tendrías que haber salido a las \(leave) para llegar a las \(arrive)."
        }
        return "Para llegar a \(title) a las \(arrive), tienes que salir como máximo a las \(leave)."
    }
}

/// Cuánto se tarda en llegar a un sitio.
public protocol TravelTimeEstimating: Sendable {
    func travelTime(to destination: ReminderDestination) async throws -> TimeInterval
}

/// Decide cuándo avisar de un recordatorio.
///
/// Dos reglas, las que pidió el usuario:
///
/// - **Con lugar:** se estima el viaje, se calcula la hora límite de salida
///   (`due - viaje`) y se avisa con `departureBuffer` de margen antes de esa hora. Así
///   el aviso llega a tiempo de ponerse el abrigo, no cuando ya habría que estar en la
///   calle.
/// - **Sin lugar, o sin ruta:** se avisa `fallbackLeadTime` antes de la hora.
///
/// Es puro salvo la estimación del viaje, que se inyecta, para que las reglas se puedan
/// probar sin mapas ni red.
public struct ReminderLeadTimeCalculator: Sendable {
    private let estimator: any TravelTimeEstimating
    private let departureBuffer: TimeInterval
    private let fallbackLeadTime: TimeInterval

    public init(
        estimator: any TravelTimeEstimating = MapKitTravelTimeEstimator(),
        departureBuffer: TimeInterval = 15 * 60,
        fallbackLeadTime: TimeInterval = 60 * 60
    ) {
        self.estimator = estimator
        self.departureBuffer = departureBuffer
        self.fallbackLeadTime = fallbackLeadTime
    }

    public func plan(
        due: Date,
        destination: ReminderDestination?,
        now: Date = Date()
    ) async throws -> ReminderPlan {
        guard due > now else { throw ReminderLeadTimeError.dueDateInThePast }

        if let destination {
            // Si el mapa no sabe llegar, el usuario no se queda sin aviso: se usa la
            // antelación fija. Quedarse callado sería el peor resultado.
            if let travel = try? await estimator.travelTime(to: destination) {
                let leaveBy = due.addingTimeInterval(-travel)
                let ideal = leaveBy.addingTimeInterval(-departureBuffer)
                let late = ideal <= now
                return ReminderPlan(
                    due: due,
                    alertAt: late ? now : ideal,
                    leaveBy: leaveBy,
                    travelTime: travel,
                    basis: .travelTime,
                    isLate: late
                )
            }
        }

        let ideal = due.addingTimeInterval(-fallbackLeadTime)
        let late = ideal <= now
        return ReminderPlan(
            due: due,
            alertAt: late ? now : ideal,
            leaveBy: nil,
            travelTime: nil,
            basis: .fixedHourBefore,
            isLate: late
        )
    }
}

/// Estima el viaje con MapKit, en coche y con el tráfico previsto.
public final class MapKitTravelTimeEstimator: TravelTimeEstimating, Sendable {
    private let originProvider: (any WeatherLocationProviding)?

    /// `originProvider` da el punto de partida: sin él no hay ruta que calcular, así que
    /// por omisión se usa la ubicación real del usuario.
    public init(originProvider: (any WeatherLocationProviding)? = LocationServiceWeatherLocation()) {
        self.originProvider = originProvider
    }

    public func travelTime(to destination: ReminderDestination) async throws -> TimeInterval {
        #if canImport(MapKit)
        guard let originProvider else {
            throw ReminderLeadTimeError.routeUnavailable(destination.name)
        }
        let origin = try await originProvider.currentCoordinate().coordinate
        let target = try await coordinate(for: destination)

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: target))
        request.transportType = .automobile
        // La hora de salida es ahora: es cuando el usuario decide si se mueve.
        request.departureDate = Date()

        let response = try await MKDirections(request: request).calculateETA()
        return response.expectedTravelTime
        #else
        throw ReminderLeadTimeError.routeUnavailable(destination.name)
        #endif
    }

    private func coordinate(for destination: ReminderDestination) async throws -> CLLocationCoordinate2D {
        if let coordinate = destination.coordinate { return coordinate }
        // Se reutiliza el geocodificador del clima: resuelve "el trabajo" igual que
        // resuelve "La Habana", y una pieza menos que mantener.
        do {
            return try await CLPlaceGeocoder().coordinate(forPlace: destination.name).coordinate
        } catch {
            throw ReminderLeadTimeError.routeUnavailable(destination.name)
        }
    }
}
