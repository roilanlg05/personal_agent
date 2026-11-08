import Foundation

/// Navega la sesión del navegador del agente a una URL.
public final class BrowserOpenTool: AgentTool, Sendable {
    public static let name = "browser_open"
    public static let timeout: TimeInterval = 60 // puede incluir el primer arranque del navegador

    public static let description = """
    Abre una URL en el navegador del agente (sesión persistente) para interactuar con \
    la página: después usa browser_snapshot para ver sus elementos. Para solo leer el \
    texto de una página usa read_webpage, que es más rápido. Solo admite URLs http y \
    https. Estados: 'success' (la página cargó; 'title' y 'url' dicen dónde terminó), \
    \(AgentBrowserToolOutput.statesSentence) \(AgentBrowserToolOutput.honestyNotice) \
    \(AgentBrowserToolOutput.untrustedContentNotice)
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
        // El 'title' lo controla quien sirve la página, igual que su texto: lleva la marca
        // como cualquier otro texto derivado de una página, y llega justo cuando el modelo
        // está decidiendo qué hacer a continuación.
        return ToolJSONOutput.object([
            "status": "success",
            "title": fields["title"] as? String,
            "url": fields["url"] as? String ?? url,
            "content_is_untrusted": true
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
    'selector'; 'url' es la página en la que está el navegador, cuando se puede saber), \
    'no_content' (la página no tiene elementos que mostrar: dilo tal \
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
        if CancelAlarmTool.coerceBool(args["interactive_only"]) ?? true { command.append("-i") }
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
            // `origin` es esquema+host: dos páginas del mismo sitio lo comparten, así que como
            // respuesta a «¿dónde estoy?» da falsos negativos. La URL completa, cuando el CLI
            // la trae, es la buena, y es además la que `Agent.cortaLaCola` compara para decidir
            // si las `@eN` de la ronda siguen valiendo. Se dan las dos: el campo viejo no se
            // retira, y un valor que no sea una página web (`isAllowedWebURL`) no se reporta,
            // para que una URL ilegible no pueda fabricar un cambio de página que no hubo.
            "url": AgentBrowserToolOutput.isAllowedWebURL(fields["url"] as? String ?? "")
                ? fields["url"] as? String : nil,
            "origin": fields["origin"] as? String,
            "truncated": clipped.truncated,
            "message": clipped.truncated
                ? "El snapshot se recortó a \(Self.snapshotLimit) caracteres. Acota con 'selector' para ver el resto."
                : nil,
            "content_is_untrusted": true
        ])
    }
}

/// Cierra la sesión del navegador del agente, SOLO si el usuario lo ha pedido en este turno.
///
/// El candado no está en el prompt a propósito: ver `BrowserCloseIntent` para por qué. La página
/// abierta es muchas veces el entregable (un vídeo puesto, una página para leer, un carrito a
/// revisar), y el modelo la destruía al dar el turno por terminado.
public final class BrowserCloseTool: AgentTool, Sendable {
    public static let name = "browser_close"
    public static let timeout: TimeInterval = 30

    public static let description = """
    Cierra el navegador del agente y termina la sesión; las referencias '@eN' dejan de \
    valer. SOLO funciona si el usuario ha pedido cerrar en este turno: en cualquier otro caso \
    devuelve 'refused' y la página se queda abierta, lo cual es deliberado y no es un fallo que \
    haya que reintentar. No lo llames para "limpiar" al terminar una tarea. Estados: 'success' \
    (el navegador se cerró), 'refused' (el usuario no lo ha pedido; la página sigue abierta), \
    \(AgentBrowserToolOutput.statesSentence) \(AgentBrowserToolOutput.honestyNotice)
    """
    public static let parameters: [AgentToolParam] = []

    private let service: AgentBrowserService
    /// Lo pone el arnés una vez por turno, leyendo el mensaje del usuario. `false` por defecto:
    /// quien registre la herramienta sin decir nada no puede cerrar nada.
    private let userAskedToClose: Bool

    public init(service: AgentBrowserService, userAskedToClose: Bool = false) {
        self.service = service
        self.userAskedToClose = userAskedToClose
    }

    public func run(argsJSON: String) async -> String {
        guard userAskedToClose else {
            return ToolJSONOutput.object([
                "status": "refused",
                "message": "No se ha cerrado el navegador y la página sigue abierta, porque el "
                    + "mensaje del usuario en este turno no pedía cerrarla. Esto no es un fallo: "
                    + "muchas veces la página abierta ES lo que el usuario pidió. NO vuelvas a "
                    + "intentarlo. Si crees que sí quiere cerrarla, no insistas con la herramienta: "
                    + "dile en una línea que se lo cierras si te lo dice (por ejemplo «cierra el "
                    + "navegador») y termina.",
            ])
        }
        let outcome = await service.run(command: ["close"], sessioned: true, timeout: Self.timeout)
        if case .failure(let json) = AgentBrowserToolOutput.resolve(outcome) { return json }
        return ToolJSONOutput.object(["status": "success", "message": "Navegador cerrado."])
    }
}

