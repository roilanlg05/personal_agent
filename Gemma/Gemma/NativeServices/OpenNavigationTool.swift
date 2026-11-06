import Foundation

public final class OpenNavigationTool: AgentTool, Sendable {
    public static let name = "open_navigation"
    public static let description = """
    Abre Apple Maps para navegar hacia un lugar conocido o dirección. Estados: \
    'navigating' (se abrió Maps con el lugar guardado), 'navigating_search' (se abrió \
    Maps buscando el texto dado), 'ambiguous' (varios lugares coinciden: pregunta al \
    usuario y vuelve a llamar) y 'failed' (el sistema no pudo abrir Maps).
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "destination", type: .string, description: "Nombre del lugar conocido (ej. 'Casa de Marcos') o dirección hacia donde navegar", required: true)
    ]

    private let placeStore: PlaceStore
    private let urlOpener: any AppURLOpening

    /// `urlOpener` es `AppURLOpening` (asíncrono) y no un cierre sincrónico porque
    /// `run(argsJSON:)` corre fuera del actor principal: tocar `UIApplication` desde ahí
    /// dispara el comprobador de hilo principal y puede terminar en caída.
    public init(
        placeStore: PlaceStore = .shared,
        urlOpener: any AppURLOpening = SystemAppURLOpener()
    ) {
        self.placeStore = placeStore
        self.urlOpener = urlOpener
    }

    var placeStoreForTesting: PlaceStore { placeStore }

    public func run(argsJSON: String) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let destination = dict["destination"] as? String,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolJSONOutput.error("Se requiere el argumento 'destination'.")
        }

        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = placeStore.search(query: trimmed)

        if matches.count > 1 {
            // Caso de conflicto / ambigüedad: múltiples lugares coinciden (ej. varios Marcos)
            let candidateNames = matches.map { $0.name }
            return ToolJSONOutput.object([
                "status": "ambiguous",
                "message": "Se encontraron varios lugares que coinciden con '\(trimmed)': "
                    + "\(candidateNames.joined(separator: ", ")). ¿A cuál te refieres?",
                "candidates": candidateNames
            ])
        } else if let place = matches.first {
            // Un único lugar conocido coincide
            let urlString = "maps://?daddr=\(place.latitude),\(place.longitude)&dirflg=d"
            guard let url = URL(string: urlString) else {
                return ToolJSONOutput.error("No se pudo generar la URL de navegación.")
            }
            let opened = await urlOpener.openURL(url)
            return ToolJSONOutput.object([
                "status": opened ? "navigating" : "failed",
                "opened": opened,
                "place": place.name,
                "coordinate": ["latitude": place.latitude, "longitude": place.longitude],
                "message": opened ? nil : "El sistema no pudo abrir Apple Maps."
            ])
        } else {
            // No coincide con un lugar guardado: buscar en Apple Maps directamente
            let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            let urlString = "maps://?q=\(escaped)"
            guard let url = URL(string: urlString) else {
                return ToolJSONOutput.error("No se pudo generar la URL de navegación.")
            }
            let opened = await urlOpener.openURL(url)
            return ToolJSONOutput.object([
                "status": opened ? "navigating_search" : "failed",
                "opened": opened,
                "query": trimmed,
                "message": opened ? nil : "El sistema no pudo abrir Apple Maps."
            ])
        }
    }
}
