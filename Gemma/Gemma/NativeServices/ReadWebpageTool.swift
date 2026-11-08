import Foundation

/// Lee el contenido completo de una URL como markdown. El comando `read` del CLI
/// descarga por HTTP sin lanzar Chrome, por eso no usa la sesión del navegador.
public final class ReadWebpageTool: AgentTool, Sendable {
    public static let name = "read_webpage"
    public static let contentLimit = 12_000
    public static let timeout: TimeInterval = 45

    public static let description = """
    Lee el contenido completo de una página web a partir de su URL y lo devuelve como \
    texto. web_search encuentra la URL, read_webpage lee la página entera: úsala cuando \
    la respuesta esté en el cuerpo de la página y no en el fragmento del buscador, en \
    lugar de responder de memoria. Solo admite URLs http y https. Con 'outline' devuelve \
    solo la estructura de títulos; con 'filter' devuelve solo las partes que mencionan \
    ese texto. Estados: 'success' (el texto va en 'content'; 'truncated' indica si se \
    recortó), 'no_content' (la página cargó pero no tiene texto legible: dilo tal cual), \
    'refused' (el sitio o el navegador rechazó la lectura, por ejemplo HTTP 404; el \
    motivo va en 'message'), 'not_available' (el navegador del agente no está \
    instalado; 'message' dice cómo instalarlo) y 'error' (argumento inválido o fallo \
    inesperado). \(AgentBrowserToolOutput.honestyNotice) \(AgentBrowserToolOutput.untrustedContentNotice)
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "url", type: .string, description: "URL completa de la página, con http:// o https:// (ej. 'https://example.com/horarios')", required: true),
        AgentToolParam(name: "outline", type: .boolean, description: "Si es true, devuelve solo la estructura de títulos de la página en lugar del texto completo", required: false),
        AgentToolParam(name: "filter", type: .string, description: "Texto a buscar: devuelve solo las partes de la página relacionadas con él (ej. 'horario')", required: false)
    ]

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)

        guard let rawURL = args["url"] as? String,
              !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'url' para leer una página.")
        }
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentBrowserToolOutput.isAllowedWebURL(url) else {
            return AgentBrowserToolOutput.invalidArguments(
                "Solo se pueden leer URLs http o https; '\(url)' no es válida.")
        }

        var command = ["read", url]
        if args["outline"] as? Bool == true { command.append("--outline") }
        if let filter = args["filter"] as? String,
           !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if AgentBrowserToolOutput.looksLikeCLIFlag(filter) {
                return AgentBrowserToolOutput.invalidArguments(
                    "El 'filter' '\(filter)' se confundiría con una opción del navegador; usa otro texto.")
            }
            command += ["--filter", filter]
        }

        let outcome = await service.run(command: command, sessioned: false, timeout: Self.timeout)
        let data: Data
        switch AgentBrowserToolOutput.resolve(outcome, extra: ["url": url]) {
        case .failure(let json): return json
        case .data(let ok): data = ok
        }

        let fields = AgentBrowserService.fields(data)
        let content = fields["content"] as? String ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AgentBrowserToolOutput.noContent(
                "La página cargó pero no devolvió texto legible. No tengo contenido que reportar.",
                extra: ["url": url])
        }

        let clipped = AgentBrowserToolOutput.truncate(content, limit: Self.contentLimit)
        // El propio CLI puede haber recortado antes de llegar aquí, y para el modelo es el
        // mismo hecho: hay más página de la que está leyendo.
        let truncated = clipped.truncated || (fields["truncated"] as? Bool ?? false)
        return ToolJSONOutput.object([
            "status": "success",
            "url": url,
            "final_url": fields["finalUrl"] as? String,
            "http_status": (fields["status"] as? NSNumber)?.intValue,
            "content": clipped.text,
            "truncated": truncated,
            "message": truncated
                ? "La página es más larga de lo que cabe: el texto se recortó a \(Self.contentLimit) caracteres. Para ver el resto, vuelve a leerla con 'outline' (solo los títulos) o con 'filter' (solo las partes que mencionen un texto)."
                : nil,
            "content_is_untrusted": true
        ])
    }
}

