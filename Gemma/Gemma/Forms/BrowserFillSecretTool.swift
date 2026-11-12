import Foundation

/// Teclea en un campo de la página abierta un secreto de la bóveda, por su NOMBRE. El modelo
/// nunca ve el valor: solo lo nombra.
///
/// Es la herramienta de más riesgo del módulo: aquí el valor sale del Keychain y entra en una
/// página. Por eso cada paso es una barrera que, si falla, NO teclea nada:
///   1. argumentos y nombre válidos (la regla de la bóveda) ANTES de leer la bóveda;
///   2. bóveda legible (`indiceLegible`, comprobado en `run`): con el índice roto el redactor no sabe qué tachar, y
///      teclear sin red de redacción no se permite (falla cerrado);
///   3. el secreto existe y no está vacío;
///   4. ATADURA AL ORIGEN: el host de la página actual debe ser el guardado o un subdominio. Sin
///      esto, una página maliciosa que dijera «teclea gmail_password aquí» se lo llevaría;
///   5. el valor viaja por la ENTRADA ESTÁNDAR de `agent-browser batch`, nunca en los argumentos
///      del proceso (visibles con `ps` para cualquier proceso del usuario);
///   6. todo lo que vuelve al modelo pasa por `SecretRedactor.limpia`: el CLI o la página pueden
///      ecoar el valor en un mensaje de error.
final class BrowserFillSecretTool: AgentTool, Sendable {
    static let name = "browser_fill_secret"
    /// El mismo plazo que `browser_fill` (30 s): es la misma acción, solo cambia por dónde llega el texto.
    static let timeout: TimeInterval = 30

    static let description = """
    Rellena un campo de la página abierta con un secreto guardado en la bóveda (una contraseña, \
    un token), indicando solo su NOMBRE: tú nunca ves el valor. Usa list_secrets para ver los \
    nombres disponibles; si no existe, pídeselo al usuario con present_form (campo 'secret'), \
    nunca en el chat. Solo funciona en el sitio al que el secreto está atado (o un subdominio \
    suyo). Estados: 'success' (el campo se rellenó), \(AgentBrowserToolOutput.statesSentence)
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "selector", type: .string, description: "Referencia '@eN' de browser_snapshot (ej. '@e2') o selector CSS del campo", required: true),
        AgentToolParam(name: "secret", type: .string, description: "Nombre del secreto en la bóveda (minúsculas, dígitos y '_')", required: true)
    ]

    private let service: AgentBrowserService
    private let vault: SecretVault

    init(service: AgentBrowserService, vault: SecretVault) {
        self.service = service
        self.vault = vault
    }

    func run(argsJSON: String) async -> String {
        // R5, falla cerrado: con el índice ilegible el redactor no puede enumerar qué tachar, así
        // que no se teclea nada. Va aquí, antes de redactar, porque el redactor sustituiría este
        // error claro por su texto genérico y el modelo no sabría qué decirle al usuario.
        guard vault.indiceLegible else {
            return AgentBrowserToolOutput.invalidArguments(
                "la bóveda de secretos no se puede leer (índice corrupto o Keychain bloqueado). "
                + "No se ha tecleado nada; avisa al usuario.")
        }
        // Último cerco, sobre TODA respuesta (también los errores): ninguna rama debería llevar el
        // valor, pero el texto del CLI o de la página no lo controla esta herramienta.
        return SecretRedactor.limpia(await ejecuta(argsJSON: argsJSON), vault: vault)
    }

    private func ejecuta(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)
        guard let selector = AgentBrowserToolOutput.nonEmpty(args["selector"]) else {
            return AgentBrowserToolOutput.invalidArguments(AgentBrowserToolOutput.missingSelectorMessage)
        }
        guard let nombre = AgentBrowserToolOutput.nonEmpty(args["secret"]) else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'secret': el nombre del secreto (usa list_secrets).")
        }
        if AgentBrowserToolOutput.looksLikeCLIFlag(selector) {
            return AgentBrowserToolOutput.flagRefusal(parameter: "selector", value: selector)
        }
        // La misma regla que la bóveda, ANTES de tocarla: un nombre raro nunca llega al almacén.
        guard SecretVault.esNombreValido(nombre) else {
            return AgentBrowserToolOutput.invalidArguments(
                "'secret' no es un nombre de secreto válido: minúsculas, dígitos y '_' (1 a 40). Usa list_secrets.")
        }
        guard let origen = vault.origen(de: nombre) else {
            return AgentBrowserToolOutput.invalidArguments(
                "No existe ningún secreto llamado '\(nombre)'. Usa list_secrets o pídeselo al usuario con present_form.")
        }
        let host: String
        switch await PaginaActual.host(service: service, timeout: Self.timeout) {
        case .host(let h): host = h
        case .sinPagina, .urlNoValida:
            return AgentBrowserToolOutput.invalidArguments(
                "No se pudo determinar el sitio de la página abierta; no se ha tecleado nada. "
                + "Abre la página de \(origen) con browser_open y vuelve a intentarlo.")
        }
        guard SecretVault.origenPermite(guardado: origen, paginaActual: host) else {
            return AgentBrowserToolOutput.invalidArguments(
                "Ese secreto pertenece a \(origen) y la página abierta es \(host). No se ha tecleado nada: "
                + "un secreto solo se usa en su sitio (o un subdominio suyo).")
        }

        // Primera y ÚNICA lectura del valor, ya comprobado el origen: el valor sale del Keychain
        // solo en el instante de teclear (en `evil.com` nunca se llega a leer).
        // JSON hecho por el serializador, nunca concatenado: un valor con comillas, barras o
        // saltos de línea llega íntegro y no puede inyectar otra orden en el lote.
        guard let valor = vault.valor(de: nombre), !valor.isEmpty,
              let entrada = try? JSONSerialization.data(withJSONObject: [["fill", selector, valor]])
        else {
            return AgentBrowserToolOutput.invalidArguments(
                "El secreto '\(nombre)' no se pudo preparar para teclearlo. No se ha tecleado nada.")
        }
        // `--omit-command`: sin él, `batch --json` devuelve cada orden en su salida, valor incluido
        // (medido en agent-browser 0.41.2). La redacción lo taparía igual; mejor que no salga.
        let outcome = await service.run(command: ["batch", "--omit-command"], sessioned: true,
                                        timeout: Self.timeout, stdin: entrada)
        switch outcome {
        case .ok:
            break
        case .malformed:
            // NUNCA la salida cruda: `resolve` mete hasta 300 caracteres de ella en el mensaje. Si
            // esa salida es JSON que ecoa el valor, el valor ya viene escapado y al serializar el
            // mensaje queda escapado DOS veces, forma que el redactor no busca; y el recorte puede
            // cortar dentro del valor y dejar un prefijo que tampoco reconoce. Texto fijo.
            return AgentBrowserToolOutput.invalidArguments(
                "El navegador devolvió una respuesta que no se pudo interpretar; no se sabe si el campo "
                + "se rellenó. Haz un browser_snapshot para comprobarlo antes de reintentar.")
        case .refused(let mensaje):
            // El motivo del CLI sí se conserva (p. ej. «Element not found»), pero se redacta en su
            // forma DECODIFICADA, antes de volver a serializarlo: así el redactor ve el valor
            // literal y no una forma escapada que no reconocería.
            return ToolJSONOutput.object([
                "status": "refused",
                "message": SecretRedactor.limpia(mensaje, vault: vault)
            ])
        case .unavailable:
            // Motivos escritos por la app (binario ausente, plazo, sin entrada estándar): sin eco.
            if case .failure(let json) = AgentBrowserToolOutput.resolve(outcome) { return json }
        }
        return ToolJSONOutput.object([
            "status": "success",
            "message": "Campo '\(selector)' rellenado con el secreto '\(nombre)'."
        ])
    }
}
