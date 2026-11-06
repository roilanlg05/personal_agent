import Foundation
import CoreLocation

public final class SavePlaceTool: AgentTool, Sendable {
    public static let name = "save_place"
    public static let description = """
    Guarda o actualiza un lugar conocido (ej. 'Casa de Marcos', 'Oficina') con sus \
    coordenadas geográficas. Si ya existe un lugar con ese nombre, lo actualiza en vez \
    de duplicarlo y responde con status 'updated'; si es nuevo responde 'saved'. \
    Si no se dan coordenadas, usa la ubicación actual; si tampoco se puede obtener, \
    responde con un error explicando el motivo.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "name", type: .string, description: "Nombre amigable del lugar (ej. 'Casa de Marcos')", required: true),
        AgentToolParam(name: "latitude", type: .number, description: "Latitud del lugar (opcional, si se omite usa la ubicación actual)", required: false),
        AgentToolParam(name: "longitude", type: .number, description: "Longitud del lugar (opcional, si se omite usa la ubicación actual)", required: false),
        AgentToolParam(name: "radius_meters", type: .number, description: "Radio de tolerancia en metros (por defecto 25m)", required: false)
    ]

    private let placeStore: PlaceStore
    private let locationService: LocationService

    public init(placeStore: PlaceStore = .shared, locationService: LocationService = .shared) {
        self.placeStore = placeStore
        self.locationService = locationService
    }

    var placeStoreForTesting: PlaceStore { placeStore }
    var locationServiceForTesting: LocationService { locationService }

    public func run(argsJSON: String) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = dict["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolJSONOutput.error("Se requiere el argumento 'name'.")
        }

        var lat = dict["latitude"] as? Double
        var lon = dict["longitude"] as? Double
        let radius = dict["radius_meters"] as? Double ?? 25.0

        var locationFailure: String? = nil
        if lat == nil || lon == nil {
            do {
                let current = try await locationService.getCurrentLocationInfo()
                lat = current.coordinate.latitude
                lon = current.coordinate.longitude
            } catch {
                locationFailure = error.localizedDescription
            }
        }

        guard let finalLat = lat, let finalLon = lon else {
            let reason = locationFailure.map { " Motivo: \($0)" } ?? ""
            return ToolJSONOutput.error(
                "No se pudieron obtener coordenadas para el lugar. Proporcione 'latitude' y 'longitude'.\(reason)"
            )
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // La descripción del tool promete "guarda o actualiza": antes siempre se creaba
        // un `KnownPlace` con un UUID nuevo, así que nunca actualizaba y el almacén
        // acumulaba un duplicado por cada vez que el usuario repetía el nombre.
        let existing = placeStore.place(named: trimmedName)
        let place = KnownPlace(
            id: existing?.id ?? UUID().uuidString,
            name: trimmedName,
            latitude: finalLat,
            longitude: finalLon,
            uncertaintyRadiusMeters: radius,
            visitCount: (existing?.visitCount ?? 0) + 1,
            lastVisitedAt: Date()
        )

        placeStore.save(place: place)

        let recordId = PlaceStore.record(for: place).recordId
        return ToolJSONOutput.object([
            "status": existing == nil ? "saved" : "updated",
            // Si sigue en la cola de subida, se dice: el lugar está en este dispositivo
            // pero el servidor todavía no lo sabe.
            "sync": MirrorStatus.describe(kind: MirrorKind.place, recordId: recordId),
            "sync_note": MirrorStatus.note(kind: MirrorKind.place, recordId: recordId),
            "place": [
                "id": place.id,
                "name": place.name,
                "latitude": place.latitude,
                "longitude": place.longitude,
                "uncertainty_radius_meters": place.uncertaintyRadiusMeters,
                "visit_count": place.visitCount
            ]
        ])
    }
}
