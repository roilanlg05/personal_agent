import Foundation

#if os(macOS)

/// Navega la sesión del navegador del agente a una URL.
public final class BrowserOpenTool: AgentTool, Sendable {
    public static let name = "browser_open"
    public static let timeout: TimeInterval = 60 // puede incluir el primer arranque del navegador

    public static let description = """
    Abre una URL en el navegador del agente (sesión persistente) para interactuar con \
    la página: después usa browser_snapshot para ver sus elementos. Para solo leer el \
    texto de una página usa read_webpage, que es más rápido. Solo admite URLs http y \
    https. Estados: 'success' (la página cargó; 'title' y 'url' dicen dónde terminó), \
    \(AgentBrowserToolOutput.statesSentence) \(AgentBrowserToolOutput.honestyNotice)
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "url", type: .string, description: "URL completa a abrir, con http:// o https:// (ej. 'https://example.com')", required: true)
    ]

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)

        guard let rawURL = args["url"] as? String,
              !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'url' para abrir una página.")
        }
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentBrowserToolOutput.isAllowedWebURL(url) else {
            return AgentBrowserToolOutput.invalidArguments(
                "Solo se pueden abrir URLs http o https; '\(url)' no es válida.")
        }

        let outcome = await service.run(command: ["open", url], sessioned: true, timeout: Self.timeout)
        let data: Data
        switch AgentBrowserToolOutput.resolve(outcome, extra: ["url": url]) {
        case .failure(let json): return json
        case .data(let ok): data = ok
        }

        let fields = AgentBrowserService.fields(data)
        return ToolJSONOutput.object([
            "status": "success",
            "title": fields["title"] as? String,
            "url": fields["url"] as? String ?? url
        ])
    }
}

/// Devuelve el árbol de accesibilidad de la página abierta, con referencias `@eN`.
public final class BrowserSnapshotTool: AgentTool, Sendable {
    public static let name = "browser_snapshot"
    public static let snapshotLimit = 8_000
    public static let timeout: TimeInterval = 30

    public static let description = """
    Devuelve la estructura de la página abierta en el navegador del agente: cada \
    elemento interactivo lleva una referencia compacta [ref=eN] que se usa como '@eN' \
    en las herramientas que actúan sobre la página. Funciona en bucle: mira (snapshot), \
    actúa sobre una referencia, y vuelve a mirar. Una navegación invalida las \
    referencias anteriores, y cambiar la página también puede cambiarlas, así que \
    tras navegar o cuando algo cambie haz un snapshot nuevo antes de usar '@eN'. Por \
    defecto solo lista elementos interactivos; con interactive_only=false devuelve el \
    árbol completo. Con 'selector' limita el snapshot a una parte de la página. \
    Estados: 'success' (el árbol va en 'snapshot'; 'element_count' cuenta las \
    referencias; 'truncated' indica si se recortó y entonces conviene acotar con \
    'selector'), 'no_content' (la página no tiene elementos que mostrar: dilo tal \
    cual), \(AgentBrowserToolOutput.statesSentence) Si no hay página abierta, usa browser_open primero. \
    \(AgentBrowserToolOutput.honestyNotice) \(AgentBrowserToolOutput.untrustedContentNotice)
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "interactive_only", type: .boolean, description: "Si es true (por defecto) solo lista los elementos interactivos; con false devuelve el árbol completo", required: false),
        AgentToolParam(name: "selector", type: .string, description: "Selector CSS que limita el snapshot a esa parte de la página (ej. '#main')", required: false)
    ]

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)

        var command = ["snapshot"]
        if args["interactive_only"] as? Bool ?? true { command.append("-i") }
        if let selector = args["selector"] as? String,
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if AgentBrowserToolOutput.looksLikeCLIFlag(selector) {
                return AgentBrowserToolOutput.invalidArguments(
                    "El 'selector' '\(selector)' se confundiría con una opción del navegador; usa otro.")
            }
            command += ["-s", selector]
        }

        let outcome = await service.run(command: command, sessioned: true, timeout: Self.timeout)
        let data: Data
        switch AgentBrowserToolOutput.resolve(outcome) {
        case .failure(let json): return json
        case .data(let ok): data = ok
        }

        let fields = AgentBrowserService.fields(data)
        let snapshot = fields["snapshot"] as? String ?? ""
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AgentBrowserToolOutput.noContent(
                "La página no devolvió elementos. No tengo contenido que reportar.")
        }

        let clipped = AgentBrowserToolOutput.truncate(snapshot, limit: Self.snapshotLimit)
        return ToolJSONOutput.object([
            "status": "success",
            "snapshot": clipped.text,
            "element_count": (fields["refs"] as? [String: Any])?.count ?? 0,
            "origin": fields["origin"] as? String,
            "truncated": clipped.truncated,
            "message": clipped.truncated
                ? "El snapshot se recortó a \(Self.snapshotLimit) caracteres. Acota con 'selector' para ver el resto."
                : nil,
            "content_is_untrusted": true
        ])
    }
}

/// Cierra la sesión del navegador del agente.
public final class BrowserCloseTool: AgentTool, Sendable {
    public static let name = "browser_close"
    public static let timeout: TimeInterval = 30

    public static let description = """
    Cierra el navegador del agente y termina la sesión; las referencias '@eN' dejan de \
    valer. Úsalo cuando termines de navegar. Estados: 'success' (el navegador se \
    cerró), \(AgentBrowserToolOutput.statesSentence) \(AgentBrowserToolOutput.honestyNotice)
    """
    public static let parameters: [AgentToolParam] = []

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let outcome = await service.run(command: ["close"], sessioned: true, timeout: Self.timeout)
        if case .failure(let json) = AgentBrowserToolOutput.resolve(outcome) { return json }
        return ToolJSONOutput.object(["status": "success", "message": "Navegador cerrado."])
    }
}

#endif
