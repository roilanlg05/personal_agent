import Foundation

#if os(macOS)

/// Espera a que la página abierta alcance un estado. No devuelve texto de la página, así
/// que no lleva el aviso de contenido no confiable.
public final class BrowserWaitTool: AgentTool, Sendable {
    public static let name = "browser_wait"
    /// Deliberadamente por encima de los 25 s de espera interna del CLI: así, si la espera
    /// expira, el mensaje que ve el modelo es el del CLI (que dice qué se esperaba) y no
    /// un genérico "superó el plazo".
    public static let timeout: TimeInterval = 40

    public static let description = """
    Espera a que la página abierta en el navegador del agente alcance un estado, antes \
    de seguir. Indica exactamente uno de estos criterios: 'text' (espera a que aparezca \
    ese texto), 'url_pattern' (espera a que la URL coincida con el patrón, por ejemplo \
    '**/panel'), 'selector' (espera a que el elemento exista; referencia '@eN' o \
    selector CSS) o 'milliseconds' (pausa fija, solo si no hay nada mejor que esperar). \
    Úsala tras un clic o una navegación que tarda en terminar. Estados: 'success' (se \
    alcanzó el estado), \(AgentBrowserToolOutput.statesSentence) Si la espera expira el \
    estado es 'refused': la página no llegó a ese estado; díselo al usuario, no lo \
    des por hecho. Si no hay página abierta, usa browser_open primero. \
    \(AgentBrowserToolOutput.honestyNotice)
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "text", type: .string, description: "Texto que debe aparecer en la página", required: false),
        AgentToolParam(name: "url_pattern", type: .string, description: "Patrón de URL a esperar (ej. '**/panel')", required: false),
        AgentToolParam(name: "selector", type: .string, description: "Referencia '@eN' o selector CSS del elemento a esperar", required: false),
        AgentToolParam(name: "milliseconds", type: .number, description: "Milisegundos de pausa fija", required: false)
    ]

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)

        // Criterios presentes, ya traducidos a los argumentos que el CLI espera tras `wait`.
        var criteria: [(parameter: String, value: String, arguments: [String])] = []
        if let text = AgentBrowserToolOutput.nonEmpty(args["text"]) {
            criteria.append(("text", text, ["--text", text]))
        }
        if let pattern = AgentBrowserToolOutput.nonEmpty(args["url_pattern"]) {
            criteria.append(("url_pattern", pattern, ["--url", pattern]))
        }
        if let selector = AgentBrowserToolOutput.nonEmpty(args["selector"]) {
            criteria.append(("selector", selector, [selector]))
        }
        // `is Bool` NO sirve aquí: `JSONSerialization` puentea los números como `NSNumber`,
        // y un `NSNumber` que vale 0 o 1 satisface `is Bool`, así que descartaba en silencio
        // un `{"milliseconds":1}` bien formado. El booleano de verdad llega como `CFBoolean`.
        if let ms = args["milliseconds"] as? NSNumber,
           CFGetTypeID(ms as CFTypeRef) != CFBooleanGetTypeID() {
            guard ms.doubleValue >= 0, ms.doubleValue.isFinite else {
                return AgentBrowserToolOutput.invalidArguments("'milliseconds' debe ser un número positivo.")
            }
            criteria.append(("milliseconds", "\(ms.intValue)", ["\(ms.intValue)"]))
        }

        guard criteria.count == 1, let criterion = criteria.first else {
            return AgentBrowserToolOutput.invalidArguments(
                "Indica exactamente uno de 'text', 'url_pattern', 'selector' o 'milliseconds' "
                + "(recibí \(criteria.count)).")
        }
        if AgentBrowserToolOutput.looksLikeCLIFlag(criterion.value) {
            return AgentBrowserToolOutput.flagRefusal(parameter: criterion.parameter, value: criterion.value)
        }

        let outcome = await service.run(command: ["wait"] + criterion.arguments,
                                        sessioned: true, timeout: Self.timeout)
        if case .failure(let json) = AgentBrowserToolOutput.resolve(outcome) { return json }
        return ToolJSONOutput.object(["status": "success", "message": "La página alcanzó el estado esperado."])
    }
}

/// Lee un dato concreto de la página abierta (texto, HTML, valor, título, URL o recuento).
public final class BrowserGetTool: AgentTool, Sendable {
    public static let name = "browser_get"
    /// Tope de los campos que pueden traer un bloque de página entero.
    public static let contentLimit = 8_000
    /// Qué valores de `what` se recortan. `title` y `url` son cortos por construcción.
    static let clippedWhat: Set<String> = ["text", "html", "value"]
    public static let timeout: TimeInterval = 30
    /// Lista cerrada de lo que se puede leer; cada nombre es también la clave de `data`.
    static let allowedWhat = ["text", "html", "value", "title", "url", "count"]

    public static let description = """
    Lee un dato concreto de la página abierta en el navegador del agente. 'what' elige \
    qué: 'text' (texto de un elemento), 'html' (HTML de un elemento), 'value' (valor de \
    un campo), 'title' (título de la página), 'url' (URL actual) o 'count' (cuántos \
    elementos coinciden con el selector). 'text', 'html' y 'value' se recortan a \
    \(contentLimit) caracteres: si 'truncated' es true no leíste el dato entero, así que \
    acota con un 'selector' más concreto en vez de darlo por completo. \
    'text', 'html', 'value' y 'count' necesitan 'selector' (referencia '@eN' o selector \
    CSS); 'title' y 'url' no. Sirve para comprobar el resultado de una acción sin pedir \
    un snapshot completo. Estados: 'success' (el dato va en 'value'; 'truncated' indica \
    si se recortó), 'no_content' (el dato está vacío o no existe: dilo tal cual), \
    \(AgentBrowserToolOutput.statesSentence) Si no hay página abierta, usa browser_open \
    primero. \(AgentBrowserToolOutput.honestyNotice) \(AgentBrowserToolOutput.untrustedContentNotice)
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "what", type: .string, description: "Qué leer: 'text', 'html', 'value', 'title', 'url' o 'count'", required: true),
        AgentToolParam(name: "selector", type: .string, description: "Referencia '@eN' o selector CSS del elemento; obligatorio salvo para 'title' y 'url'", required: false)
    ]

    private let service: AgentBrowserService

    public init(service: AgentBrowserService) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)

        guard let what = AgentBrowserToolOutput.nonEmpty(args["what"]), Self.allowedWhat.contains(what) else {
            return AgentBrowserToolOutput.invalidArguments(
                "Se requiere 'what', uno de: \(Self.allowedWhat.joined(separator: ", ")).")
        }
        let needsSelector = what != "title" && what != "url"
        let selector = AgentBrowserToolOutput.nonEmpty(args["selector"])
        if needsSelector && selector == nil {
            return AgentBrowserToolOutput.invalidArguments(
                "Para leer '\(what)' hace falta 'selector' (una referencia '@eN' o un selector CSS).")
        }
        if let selector, needsSelector, AgentBrowserToolOutput.looksLikeCLIFlag(selector) {
            return AgentBrowserToolOutput.flagRefusal(parameter: "selector", value: selector)
        }

        var command = ["get", what]
        if needsSelector, let selector { command.append(selector) }
        let outcome = await service.run(command: command, sessioned: true, timeout: Self.timeout)
        let data: Data
        switch AgentBrowserToolOutput.resolve(outcome) {
        case .failure(let json): return json
        case .data(let ok): data = ok
        }

        // Una clave ausente es un estado propio, no un valor vacío.
        let raw = AgentBrowserService.fields(data)[what]
        if let count = raw as? Int, what == "count" {
            return ToolJSONOutput.object(["status": "success", "what": what, "value": count])
        }
        guard let text = raw as? String, !text.isEmpty else {
            return AgentBrowserToolOutput.noContent("La página no devolvió ningún '\(what)'.",
                                                    extra: ["what": what])
        }
        // El tope vale para los tres campos que pueden traer página entera, no solo para
        // 'html': un 'get text' sobre un contenedor vuelca la página igual que el HTML.
        let clipped = Self.clippedWhat.contains(what)
            ? AgentBrowserToolOutput.truncate(text, limit: Self.contentLimit)
            : (text, false)
        return ToolJSONOutput.object([
            "status": "success",
            "what": what,
            "value": clipped.0,
            "truncated": clipped.1,
            "message": clipped.1 ? "El '\(what)' se recortó a \(Self.contentLimit) caracteres. Acota con 'selector'." : nil,
            "content_is_untrusted": true
        ])
    }
}

#endif
