import Foundation

public final class ListPlacesTool: AgentTool, Sendable {
    public static let name = "list_places"
    public static let description = "Lista todos los lugares conocidos y guardados en Gemma."
    public static let parameters: [AgentToolParam] = []

    private let placeStore: PlaceStore

    public init(placeStore: PlaceStore = .shared) {
        self.placeStore = placeStore
    }

    var placeStoreForTesting: PlaceStore { placeStore }

    public func run(argsJSON: String) async -> String {
        let formatter = ISO8601DateFormatter()
        let places: [[String: Any]] = placeStore.list().map { place in
            [
                "id": place.id,
                "name": place.name,
                "latitude": place.latitude,
                "longitude": place.longitude,
                "uncertainty_radius_meters": place.uncertaintyRadiusMeters,
                "visit_count": place.visitCount,
                "last_visited_at": formatter.string(from: place.lastVisitedAt)
            ]
        }
        return ToolJSONOutput.object([
            "status": "ok",
            "count": places.count,
            "places": places
        ])
    }
}
