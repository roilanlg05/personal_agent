import Foundation

#if os(macOS)

/// Piezas comunes a las tres herramientas de interacción: ninguna devuelve texto de la
/// página, así que ninguna lleva el aviso de contenido no confiable.
private enum InteractionSupport {
    static let timeout: TimeInterval = 30

    /// Mensaje de rechazo cuando un argumento sería absorbido por el parseador de flags
    /// del CLI. El CLI no tiene separador `--`, y además daría el fallo por bueno.
    static func flagRefusal(parameter: String, value: String) -> String {
        ToolJSONOutput.object([
            "status": "refused",
            "message": "El navegador no puede recibir '\(value)' como '\(parameter)': su interfaz de "
                + "línea de comandos lo interpretaría como una opción propia y daría por hecha una "
                + "acción que no ocurrió. No se ejecutó nada; usa otro valor."
        ])
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// Hace clic en un elemento de la página abierta.
public final class BrowserClickTool: AgentTool, Sendable {
    public static let name = "browser_click"
    public static let timeout: TimeInterval = InteractionSupport.timeout

    public static let description = """
    Hace clic en un elemento de la página abierta en el navegador del agente. Usa la \
    referencia '@eN' que te dio browser_snapshot (también acepta un selector CSS). Tras \
    el clic la página puede cambiar o navegar: haz un browser_snapshot nuevo antes de \
    usar otras referencias. Estados: 'success' (el clic se ejecutó; no implica que la \
    página haya hecho lo esperado: compruébalo con un snapshot), \
    \(AgentBrowserToolOutput.statesSentence) Si no hay página abierta, usa browser_open \
    primero. \(AgentBrowserToolOutput.honestyNotice)
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "selector", type: .string, description: "Referencia '@eN' de browser_snapshot (ej. '@e3') o selector CSS del elemento", required: true)
    ]

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)
        guard let selector = InteractionSupport.nonEmpty(args["selector"]) else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'selector' (una referencia '@eN' o un selector CSS).")
        }
        if AgentBrowserToolOutput.looksLikeCLIFlag(selector) {
            return InteractionSupport.flagRefusal(parameter: "selector", value: selector)
        }

        let outcome = await service.run(command: ["click", selector], sessioned: true, timeout: Self.timeout)
        if case .failure(let json) = AgentBrowserToolOutput.resolve(outcome) { return json }
        return ToolJSONOutput.object(["status": "success", "message": "Clic ejecutado en '\(selector)'."])
    }
}

/// Escribe texto en un campo de la página abierta.
public final class BrowserFillTool: AgentTool, Sendable {
    public static let name = "browser_fill"
    public static let timeout: TimeInterval = InteractionSupport.timeout

    public static let description = """
    Escribe texto en un campo de formulario de la página abierta, reemplazando lo que \
    hubiera. Usa la referencia '@eN' de browser_snapshot (o un selector CSS). Con text \
    vacío ('') vacía el campo. PROHIBIDO usarla para contraseñas, tokens, claves o \
    códigos de verificación: el texto viaja como argumento de un proceso y es visible en \
    la lista de procesos del sistema. Si una tarea exige autenticarse, pide al usuario \
    que lo haga o que te indique cómo proceder; nunca inventes credenciales. No envía el \
    formulario: para eso usa browser_click o browser_press con Enter. El navegador no \
    puede recibir como texto o selector valores idénticos a sus propias opciones (por \
    ejemplo '--json'): en ese caso devuelve 'refused'. Estados: 'success' (el campo se \
    rellenó), \(AgentBrowserToolOutput.statesSentence) \(AgentBrowserToolOutput.honestyNotice)
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "selector", type: .string, description: "Referencia '@eN' de browser_snapshot (ej. '@e2') o selector CSS del campo", required: true),
        AgentToolParam(name: "text", type: .string, description: "Texto a escribir; cadena vacía para vaciar el campo. Nunca contraseñas ni tokens", required: true)
    ]

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)
        guard let selector = InteractionSupport.nonEmpty(args["selector"]) else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'selector' (una referencia '@eN' o un selector CSS).")
        }
        // Ausente es un error de argumentos; vacío es válido (vaciar el campo).
        guard let text = args["text"] as? String else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'text' (usa una cadena vacía para vaciar el campo).")
        }
        // El CLI se come estos valores como flags y aun así reporta éxito.
        if AgentBrowserToolOutput.looksLikeCLIFlag(text) {
            return InteractionSupport.flagRefusal(parameter: "text", value: text)
        }
        if AgentBrowserToolOutput.looksLikeCLIFlag(selector) {
            return InteractionSupport.flagRefusal(parameter: "selector", value: selector)
        }

        let outcome = await service.run(command: ["fill", selector, text], sessioned: true, timeout: Self.timeout)
        if case .failure(let json) = AgentBrowserToolOutput.resolve(outcome) { return json }
        return ToolJSONOutput.object(["status": "success", "message": "Campo '\(selector)' rellenado."])
    }
}

/// Pulsa una tecla o combinación en la página abierta.
public final class BrowserPressTool: AgentTool, Sendable {
    public static let name = "browser_press"
    public static let timeout: TimeInterval = InteractionSupport.timeout

    public static let description = """
    Pulsa una tecla o combinación de teclas en la página abierta, por ejemplo 'Enter' \
    para enviar un formulario, 'Tab', 'Escape' o 'Control+a'. Tras pulsar, la página \
    puede cambiar: haz un browser_snapshot nuevo antes de usar otras referencias. \
    Estados: 'success' (la tecla se pulsó; no implica que la página reaccionara como \
    esperabas), \(AgentBrowserToolOutput.statesSentence) Si no hay página abierta, usa \
    browser_open primero. \(AgentBrowserToolOutput.honestyNotice)
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "key", type: .string, description: "Tecla o combinación (ej. 'Enter', 'Tab', 'Control+a')", required: true)
    ]

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)
        guard let key = InteractionSupport.nonEmpty(args["key"]) else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'key' (ej. 'Enter' o 'Control+a').")
        }
        if AgentBrowserToolOutput.looksLikeCLIFlag(key) {
            return InteractionSupport.flagRefusal(parameter: "key", value: key)
        }

        let outcome = await service.run(command: ["press", key], sessioned: true, timeout: Self.timeout)
        if case .failure(let json) = AgentBrowserToolOutput.resolve(outcome) { return json }
        return ToolJSONOutput.object(["status": "success", "message": "Tecla '\(key)' pulsada."])
    }
}

#endif
