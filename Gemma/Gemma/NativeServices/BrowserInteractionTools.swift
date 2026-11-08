import Foundation

/// Piezas comunes a las tres herramientas de interacción: ninguna devuelve texto de la
/// página, así que ninguna lleva el aviso de contenido no confiable.
private enum InteractionSupport {
    static let timeout: TimeInterval = 30

    /// Plazo del `get url` que sigue a una acción con éxito. Es una lectura inmediata del
    /// estado del navegador, no trabajo de página: con los 30 s de la acción, un `get url`
    /// colgado doblaría la espera del turno para averiguar un dato auxiliar.
    static let urlTimeout: TimeInterval = 10

    /// La URL en la que la página quedó DESPUÉS de una acción con éxito, o `nil` cuando no se
    /// puede saber.
    ///
    /// POR QUÉ EXISTE. `Agent.cortaLaCola` corta la cola de acciones pendientes de la ronda
    /// cuando la página ha cambiado bajo las referencias `@eN` que el modelo tenía planificadas,
    /// y lo decide comparando la URL de antes con la de después. Pero `click`, `fill` y `press`
    /// devolvían `{"status":"success","message":"…"}` y tiraban el resto: sin URL, la rama de
    /// comparación no se disparaba nunca, y el clic es justo la acción que navega más a menudo.
    /// Esta función es la cañería que le lleva el dato: lo demás ya estaba escrito y probado.
    ///
    /// DE DÓNDE SALE LA URL, medido contra el CLI 0.41.2 vendorizado:
    ///   1. Del propio resultado de la acción, si lo trae. Ni `agent-browser click --help`, ni
    ///      `references/commands.md`, ni la guía oficial (`docs/agent-browser/core-skill-0.41.2.md`)
    ///      documentan una URL en la salida de `click`/`fill`/`press`, y en la tabla de cadenas
    ///      del binario las claves vecinas del manejador de `click` son `clicked`, `newTab` y
    ///      `dialogOpened`, sin URL ninguna. Aun así se mira primero: si una versión del CLI la
    ///      trajera, es un dato que ya viaja y pedirlo otra vez sería gastar un viaje de balde.
    ///   2. Si no la trae, se pregunta con `get url`, que sí la da (`BrowserGetTool` lee de ahí
    ///      su `what=url`). Cuesta una orden más del CLI por interacción —y con el navegador en
    ///      el i3, un viaje de red más—, y vale la pena: una ronda del agente malgastada
    ///      disparando `@eN` viejas contra una página nueva cuesta mucho más que eso.
    ///
    /// LA DUDA NO INVENTA. Un `get url` fallido, un campo ausente o un valor que no es una
    /// página web (`isAllowedWebURL`: http/https con host) devuelven `nil`, y entonces la
    /// herramienta omite la clave `url`. Omitirla hace que `cortaLaCola` caiga en su rama que NO
    /// corta, que es el lado barato del error; lo que nunca puede pasar es que un valor que no
    /// se supo leer se convierta en un corte, ni en una URL inventada que el modelo lea como la
    /// página en la que está.
    static func urlPosterior(_ datos: Data, service: AgentBrowserService) async -> String? {
        if let propia = urlSiEsUnaPagina(AgentBrowserService.fields(datos)["url"]) { return propia }
        let outcome = await service.run(command: ["get", "url"], sessioned: true, timeout: urlTimeout)
        guard case .ok(let data) = outcome else { return nil }
        return urlSiEsUnaPagina(AgentBrowserService.fields(data)["url"])
    }

    /// El valor si es una URL http(s) con host; `nil` en cualquier otro caso.
    static func urlSiEsUnaPagina(_ valor: Any?) -> String? {
        guard let texto = valor as? String,
              AgentBrowserToolOutput.isAllowedWebURL(texto) else { return nil }
        return texto
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
    página haya hecho lo esperado: compruébalo con un snapshot; 'url', si está, dice en qué \
    página quedó el navegador tras el clic), \
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
        guard let selector = AgentBrowserToolOutput.nonEmpty(args["selector"]) else {
            return AgentBrowserToolOutput.invalidArguments(AgentBrowserToolOutput.missingSelectorMessage)
        }
        if AgentBrowserToolOutput.looksLikeCLIFlag(selector) {
            return AgentBrowserToolOutput.flagRefusal(parameter: "selector", value: selector)
        }

        let outcome = await service.run(command: ["click", selector], sessioned: true, timeout: Self.timeout)
        let datos: Data
        switch AgentBrowserToolOutput.resolve(outcome) {
        case .failure(let json): return json
        case .data(let ok): datos = ok
        }
        return ToolJSONOutput.object([
            "status": "success",
            "url": await InteractionSupport.urlPosterior(datos, service: service),
            "message": "Clic ejecutado en '\(selector)'."
        ])
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
    ejemplo '--json'): en ese caso devuelve 'error'. Estados: 'success' (el campo se \
    rellenó; 'url', si está, dice en qué página quedó el navegador), \(AgentBrowserToolOutput.statesSentence) \(AgentBrowserToolOutput.honestyNotice)
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
        guard let selector = AgentBrowserToolOutput.nonEmpty(args["selector"]) else {
            return AgentBrowserToolOutput.invalidArguments(AgentBrowserToolOutput.missingSelectorMessage)
        }
        // Ausente es un error de argumentos; vacío es válido (vaciar el campo).
        guard let text = args["text"] as? String else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'text' (usa una cadena vacía para vaciar el campo).")
        }
        // El CLI se come estos valores como flags y aun así reporta éxito.
        if AgentBrowserToolOutput.looksLikeCLIFlag(text) {
            return AgentBrowserToolOutput.flagRefusal(parameter: "text", value: text)
        }
        if AgentBrowserToolOutput.looksLikeCLIFlag(selector) {
            return AgentBrowserToolOutput.flagRefusal(parameter: "selector", value: selector)
        }

        let outcome = await service.run(command: ["fill", selector, text], sessioned: true, timeout: Self.timeout)
        let datos: Data
        switch AgentBrowserToolOutput.resolve(outcome) {
        case .failure(let json): return json
        case .data(let ok): datos = ok
        }
        return ToolJSONOutput.object([
            "status": "success",
            "url": await InteractionSupport.urlPosterior(datos, service: service),
            "message": "Campo '\(selector)' rellenado."
        ])
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
    esperabas; 'url', si está, dice en qué página quedó el navegador), \(AgentBrowserToolOutput.statesSentence) Si no hay página abierta, usa \
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
        guard let key = AgentBrowserToolOutput.nonEmpty(args["key"]) else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'key' (ej. 'Enter' o 'Control+a').")
        }
        if AgentBrowserToolOutput.looksLikeCLIFlag(key) {
            return AgentBrowserToolOutput.flagRefusal(parameter: "key", value: key)
        }

        let outcome = await service.run(command: ["press", key], sessioned: true, timeout: Self.timeout)
        let datos: Data
        switch AgentBrowserToolOutput.resolve(outcome) {
        case .failure(let json): return json
        case .data(let ok): datos = ok
        }
        return ToolJSONOutput.object([
            "status": "success",
            "url": await InteractionSupport.urlPosterior(datos, service: service),
            "message": "Tecla '\(key)' pulsada."
        ])
    }
}

