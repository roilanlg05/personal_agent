import Foundation

public final class WebSearchTool: AgentTool, Sendable {
    public static let name = "web_search"
    public static let description = """
    Busca información en vivo en internet. Estados: 'success' (hay resultados en \
    'results'), 'no_results' (la búsqueda funcionó pero no encontró nada: dilo tal cual, \
    no rellenes con lo que creas saber) y 'error' (la búsqueda falló, por ejemplo sin \
    red; el motivo va en 'message' y NO hay resultados). Nunca presentes un estado \
    distinto de 'success' como información obtenida de internet.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Términos o pregunta para buscar en internet (ej. 'horario del partido Real Madrid hoy', 'precio de Bitcoin')", required: true),
        AgentToolParam(name: "max_results", type: .integer, description: "Cantidad máxima de resultados a retornar (por defecto 3, máximo 10)", required: false)
    ]

    private let searchService: WebSearchService

    public init(searchService: WebSearchService = WebSearchService()) {
        self.searchService = searchService
    }

    public func run(argsJSON: String) async -> String {
        guard let query = parseString(named: "query", from: argsJSON) else {
            return ToolJSONOutput.error("Se requiere 'query' para buscar en la web.")
        }

        let maxResults = parseInt(named: "max_results", from: argsJSON) ?? 3

        do {
            let results = try await searchService.search(query: query, maxResults: maxResults)
            if results.isEmpty {
                return ToolJSONOutput.object([
                    "status": "no_results",
                    "query": query,
                    "count": 0,
                    "message": "La búsqueda se realizó correctamente pero no devolvió ningún resultado."
                ])
            }
            return ToolJSONOutput.object([
                "status": "success",
                "query": query,
                "count": results.count,
                "results": results.map {
                    ["title": $0.title, "snippet": $0.snippet, "url": $0.url]
                }
            ])
        } catch {
            return ToolJSONOutput.object([
                "status": "error",
                "query": query,
                "message": "No se pudo buscar en la web: \(error.localizedDescription)"
            ])
        }
    }

    private func parseString(named name: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let val = dict[name] as? String, !val.isEmpty else {
            return nil
        }
        return val
    }

    private func parseInt(named name: String, from json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let i = dict[name] as? Int { return i }
        if let n = dict[name] as? NSNumber { return n.intValue }
        if let s = dict[name] as? String { return Int(s) }
        return nil
    }
}
