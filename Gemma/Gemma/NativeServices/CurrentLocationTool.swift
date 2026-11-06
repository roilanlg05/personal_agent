import Foundation
import CoreLocation

public final class CurrentLocationTool: AgentTool, Sendable {
    public static let name = "get_current_location"
    public static let description = """
    Obtiene la ubicación actual en tiempo real con dirección física y resolución de \
    lugares conocidos. Estados: 'certain' (coincide con un lugar guardado), 'ambiguous' \
    (varios lugares guardados caen en el mismo radio: pregunta al usuario), 'unknown' \
    (hay coordenadas pero ningún lugar guardado cerca), 'permission_denied' (el usuario \
    no ha concedido el permiso de ubicación: pídeselo), 'timeout' (el GPS no respondió a \
    tiempo) y 'error' (otro fallo). En los tres últimos NO hay ubicación: no la inventes.
    """
    public static let parameters: [AgentToolParam] = []

    private let locationService: LocationService

    public init(locationService: LocationService = .shared) {
        self.locationService = locationService
    }

    public func run(argsJSON: String) async -> String {
        do {
            let info = try await locationService.getCurrentLocationInfo()
            let addr = info.address
            let city = info.city

            switch info.resolution {
            case .certain(let place, let distance):
                return ToolJSONOutput.object([
                    "status": "certain",
                    "place": place.name,
                    "distance_meters": Int(distance),
                    "address": addr,
                    "city": city,
                    "coordinate": [
                        "latitude": info.coordinate.latitude,
                        "longitude": info.coordinate.longitude
                    ]
                ])
            case .ambiguous(let candidates):
                let names = candidates.map { $0.place.name }.joined(separator: " o ")
                return ToolJSONOutput.object([
                    "status": "ambiguous",
                    "question": "¿Estamos en \(names)?",
                    "candidates": candidates.map {
                        ["name": $0.place.name, "distance_meters": Int($0.distanceMeters)]
                    },
                    "address": addr,
                    "city": city,
                    "coordinate": [
                        "latitude": info.coordinate.latitude,
                        "longitude": info.coordinate.longitude
                    ]
                ])
            case .unknown(let coord, let nearest):
                return ToolJSONOutput.object([
                    "status": "unknown",
                    "address": addr,
                    "city": city,
                    "nearest_known_place": nearest.map {
                        ["name": $0.0.name, "distance_meters": Int($0.1)]
                    },
                    "coordinate": ["latitude": coord.latitude, "longitude": coord.longitude]
                ])
            }
        } catch let error as LocationProviderError {
            // El agente necesita el motivo para poder explicárselo al usuario: pedir el
            // permiso no es lo mismo que reintentar.
            switch error {
            case .permissionDenied:
                return ToolJSONOutput.object([
                    "status": "permission_denied",
                    "message": error.localizedDescription
                ])
            case .timedOut:
                return ToolJSONOutput.object([
                    "status": "timeout",
                    "message": error.localizedDescription
                ])
            case .unavailable:
                return ToolJSONOutput.object([
                    "status": "error",
                    "message": error.localizedDescription
                ])
            }
        } catch {
            return ToolJSONOutput.object([
                "status": "error",
                "message": error.localizedDescription
            ])
        }
    }
}
