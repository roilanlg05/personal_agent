import Foundation

/// Mensaje común cuando la bóveda no puede enumerar sus secretos. Una sola frase para las tres
/// herramientas: el modelo debe poder reconocerla y no reintentar a ciegas.
private let bovedaIlegible = "la bóveda de secretos no se puede leer (índice corrupto o Keychain bloqueado). "
    + "No se ha presentado, guardado ni borrado nada; avisa al usuario."

/// Pide al usuario un formulario y devuelve lo que contestó.
///
/// Los campos `secret` son el motivo de que esto exista: el valor que teclea el usuario va a la
/// bóveda y al modelo solo le vuelve `[secreto guardado: <nombre>]`. Por eso, ANTES de mostrar
/// nada, se comprueba todo lo que podría impedir guardarlo (página abierta, bóveda legible,
/// nombres no repetidos): preguntarle una contraseña al usuario y descubrir después que no hay
/// dónde guardarla es la peor experiencia posible.
final class PresentFormTool: AgentTool, Sendable {
    static let name = "present_form"
    static let timeout: TimeInterval = 10

    static let description = """
    Muestra al usuario un formulario en pantalla y espera su respuesta (máximo 10 minutos). \
    Úsalo para pedir datos que no debes inventar, y SIEMPRE para contraseñas, tokens y claves: \
    nunca las pidas en el chat. Un campo de tipo 'secret' (con 'secret_name', minúsculas, \
    dígitos y '_', hasta 40) se guarda en la bóveda atado a la página abierta; tú solo recibes \
    '[secreto guardado: <secret_name>]' y lo tecleas luego con browser_fill_secret. Para usar \
    campos 'secret' abre antes la página donde se usará el secreto. 'fields' es una cadena JSON \
    con una lista de 1 a 12 campos {id, label, kind, required?, options?, secret_name?, \
    placeholder?, help?}; kind: text, secret, number, choice, multichoice, confirm o date; \
    'options' ([{value,label}]) obligatorias en choice/multichoice y prohibidas en el resto. \
    Devuelve {"status":"submitted"|"cancelled"|"timeout","values":{id:valor}}.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Título del formulario", required: true),
        AgentToolParam(name: "description", type: .string, description: "Texto explicativo opcional bajo el título", required: false),
        AgentToolParam(name: "submit_label", type: .string, description: "Texto del botón de enviar (por defecto 'Enviar')", required: false),
        AgentToolParam(name: "fields", type: .string, description: "Lista JSON de campos: [{\"id\":\"pw\",\"label\":\"Contraseña\",\"kind\":\"secret\",\"secret_name\":\"gmail_password\"}]", required: true)
    ]

    private let broker: FormBroker
    private let vault: SecretVault
    private let service: AgentBrowserService?

    init(broker: FormBroker, vault: SecretVault, service: AgentBrowserService?) {
        self.broker = broker
        self.vault = vault
        self.service = service
    }

    func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)
        guard let title = AgentBrowserToolOutput.nonEmpty(args["title"]) else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'title'.")
        }
        guard let fieldsJSON = args["fields"] as? String else {
            return AgentBrowserToolOutput.invalidArguments(
                "Se requiere 'fields': una CADENA con la lista JSON de campos.")
        }

        let spec: FormSpec
        do {
            spec = try FormSpec.parse(title: title, description: args["description"] as? String,
                                      submitLabel: args["submit_label"] as? String, fieldsJSON: fieldsJSON)
        } catch let e as FormSpecError {
            return AgentBrowserToolOutput.invalidArguments(Self.explica(e))
        } catch {
            return AgentBrowserToolOutput.invalidArguments("El formulario no es válido.")
        }

        let secretos = spec.fields.filter { $0.kind == .secret }
        var origen: String?
        if !secretos.isEmpty {
            // Dos campos con el mismo nombre se pisarían en la bóveda: el segundo borraría el
            // primero y el modelo creería tener dos secretos distintos.
            let nombres = secretos.compactMap(\.secretName)
            if let repetido = nombres.first(where: { n in nombres.filter { $0 == n }.count > 1 }) {
                return AgentBrowserToolOutput.invalidArguments(
                    "Dos campos 'secret' usan el mismo secret_name '\(repetido)': se pisarían en la bóveda. Usa nombres distintos.")
            }
            // Fallar cerrado: con el índice ilegible `guarda` se negaría después de haberle
            // pedido la contraseña al usuario.
            guard vault.indiceLegible else { return AgentBrowserToolOutput.invalidArguments(bovedaIlegible) }
            switch await hostDeLaPaginaActual() {
            case .failure(let json): return json
            case .host(let h): origen = h
            }
        }

        let respuesta: FormResponse
        do {
            respuesta = try await broker.presenta(spec)
        } catch FormBrokerError.yaHayUnoAbierto {
            return AgentBrowserToolOutput.invalidArguments(
                "Ya hay un formulario abierto esperando al usuario. Espera a que lo conteste o lo cancele.")
        } catch {
            return AgentBrowserToolOutput.invalidArguments("No se pudo presentar el formulario.")
        }

        guard respuesta.status == .submitted else { return respuesta.json }
        return guarda(secretos: secretos, origen: origen, en: respuesta)
    }

    /// Guarda cada secreto y sustituye su valor por el literal. Ningún mensaje de error de aquí
    /// incluye valores: solo nombres de secreto.
    ///
    /// Todo o nada: si uno falla se borran los que ya se guardaron en ESTA llamada, para no
    /// dejar al modelo (y al usuario) con un formulario a medias cuyo estado no puede deducir.
    /// (Si un secreto con ese nombre ya existía, su valor viejo ya se perdió al sobrescribirlo:
    /// es el comportamiento de `guarda` y no se puede deshacer desde aquí.)
    private func guarda(secretos: [FormField], origen: String?, en respuesta: FormResponse) -> String {
        var valores = respuesta.values
        var guardados: [String] = []
        for campo in secretos {
            guard let nombre = campo.secretName, let origen else { continue }
            let valor = respuesta.values[campo.id] ?? ""
            if valor.isEmpty && !campo.required {
                // Opcional y vacío: no hay nada que guardar (la bóveda rechaza vacíos). Se dice
                // la verdad: el valor queda vacío, no «guardado».
                valores[campo.id] = ""
                continue
            }
            if !vault.guarda(name: nombre, value: valor, etiqueta: campo.label, origen: origen) {
                guardados.forEach { vault.borra(name: $0) }
                return AgentBrowserToolOutput.invalidArguments(
                    "No se pudo guardar el secreto '\(nombre)' (valor vacío o bóveda no disponible). "
                    + "No se ha guardado ninguno de los secretos de este formulario.")
            }
            guardados.append(nombre)
            valores[campo.id] = FormResponse.textoDeSecretoGuardado(nombre)
        }
        return FormResponse(status: .submitted, values: valores).json
    }

    private enum Pagina {
        case host(String)
        case failure(String)
    }

    /// El host limpio (minúsculas, sin esquema, puerto, ruta ni query) de la página abierta.
    /// `SecretVault.guarda` no valida el origen que recibe, así que la limpieza es de aquí.
    private func hostDeLaPaginaActual() async -> Pagina {
        let sinPagina = "abre primero la página donde se usará el secreto (con browser_open) y vuelve a pedir el formulario."
        guard let service else { return .failure(AgentBrowserToolOutput.invalidArguments(sinPagina)) }
        let outcome = await service.run(command: ["get", "url"], sessioned: true, timeout: Self.timeout)
        let datos: Data
        switch AgentBrowserToolOutput.resolve(outcome) {
        case .failure: return .failure(AgentBrowserToolOutput.invalidArguments(sinPagina))
        case .data(let ok): datos = ok
        }
        guard let url = AgentBrowserService.fields(datos)["url"] as? String,
              let host = URL(string: url)?.host?.lowercased(), !host.isEmpty,
              // Misma normalización estricta que la comparación de origen: un host que ella
              // no acepta nunca podría coincidir después, así que se rechaza ya.
              SecretVault.origenPermite(guardado: host, paginaActual: host)
        else {
            return .failure(AgentBrowserToolOutput.invalidArguments(
                "No se pudo determinar el sitio de la página abierta (\"about:blank\" o URL no válida). \(sinPagina)"))
        }
        return .host(host)
    }

    private static func explica(_ e: FormSpecError) -> String {
        switch e {
        case .jsonInvalido: return "'fields' no es una lista JSON válida de campos {id, label, kind, ...}."
        case .sinCampos: return "El formulario no tiene campos."
        case .demasiadosCampos: return "Máximo \(FormSpec.maxCampos) campos por formulario."
        case .idsRepetidos: return "Hay ids de campo repetidos."
        case .nombreDeSecretoInvalido(let n): return "secret_name '\(n)' no es válido: usa minúsculas, dígitos y '_' (1 a 40)."
        case .faltanOpciones(let id): return "El campo '\(id)' necesita 'options' no vacías."
        case .opcionesNoPermitidas(let id): return "El campo '\(id)' no admite 'options' (solo choice y multichoice)."
        case .faltaNombreDeSecreto(let id): return "El campo secret '\(id)' necesita 'secret_name'."
        case .nombreDeSecretoNoPermitido(let id): return "El campo '\(id)' no es secret y no admite 'secret_name'."
        }
    }
}

/// Lista los secretos guardados: nombre, etiqueta y sitio. Nunca el valor.
final class ListSecretsTool: AgentTool, Sendable {
    static let name = "list_secrets"
    static let description = """
    Lista los secretos que el usuario ha guardado en la bóveda (nombre, etiqueta y sitio al que \
    están atados). Nunca devuelve los valores. Úsala para saber qué nombre pasar a \
    browser_fill_secret antes de volver a pedir una contraseña.
    """
    static let parameters: [AgentToolParam] = []

    private let vault: SecretVault
    init(vault: SecretVault) { self.vault = vault }

    func run(argsJSON: String) async -> String {
        // Una lista vacía engañaría al modelo («no hay secretos») cuando en realidad no se puede leer.
        guard vault.indiceLegible else { return AgentBrowserToolOutput.invalidArguments(bovedaIlegible) }
        let lista = vault.lista().map { ["name": $0.name, "etiqueta": $0.etiqueta, "origen": $0.origen] }
        return ToolJSONOutput.object(["status": "success", "secrets": lista])
    }
}

/// Olvida un secreto de la bóveda.
final class ForgetSecretTool: AgentTool, Sendable {
    static let name = "forget_secret"
    static let description = "Borra de la bóveda el secreto con ese nombre (usa list_secrets para ver los nombres)."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "name", type: .string, description: "Nombre del secreto a olvidar", required: true)
    ]

    private let vault: SecretVault
    init(vault: SecretVault) { self.vault = vault }

    func run(argsJSON: String) async -> String {
        let args = AgentBrowserToolOutput.parseArguments(argsJSON)
        guard let name = AgentBrowserToolOutput.nonEmpty(args["name"]) else {
            return AgentBrowserToolOutput.invalidArguments("Se requiere 'name'.")
        }
        // Con el índice ilegible `borra` quitaría el valor pero no el nombre del índice.
        guard vault.indiceLegible else { return AgentBrowserToolOutput.invalidArguments(bovedaIlegible) }
        guard vault.lista().contains(where: { $0.name == name }) else {
            return AgentBrowserToolOutput.invalidArguments("No hay ningún secreto llamado '\(name)'.")
        }
        vault.borra(name: name)
        return ToolJSONOutput.object(["status": "success", "message": "Secreto '\(name)' olvidado."])
    }
}
