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
    /// El turno del agente en el que se registró la herramienta (ver `FormBroker.turnoVigente`).
    private let turno: UUID?

    init(broker: FormBroker, vault: SecretVault, service: AgentBrowserService?, turno: UUID? = nil) {
        self.broker = broker
        self.vault = vault
        self.service = service
        self.turno = turno
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
            // Un secreto que luego no se puede teclear no se pide: con el navegador del i3 (HTTP) o
            // en iOS `browser_fill_secret` se niega siempre, porque el valor solo viaja por la
            // entrada estándar del `agent-browser` local. Se rechaza ANTES de presentar y antes de
            // consultar la página: no se guarda ni se pregunta nada.
            if let service, !service.aceptaEntradaEstandar {
                return AgentBrowserToolOutput.invalidArguments(
                    "Aquí no se pueden usar campos 'secret': un secreto solo se puede teclear con el navegador local "
                    + "de la Mac (no con el navegador remoto ni en el iPhone). No se ha presentado ni guardado nada. "
                    + "No pidas la contraseña por el chat: dile al usuario que la introduzca él en la página.")
            }
            // Fallar cerrado: con el índice ilegible `guarda` se negaría después de haberle
            // pedido la contraseña al usuario.
            guard vault.indiceLegible else { return AgentBrowserToolOutput.invalidArguments(bovedaIlegible) }
            switch await hostDeLaPaginaActual() {
            case .failure(let json): return json
            case .host(let h): origen = h
            }
            // Atadura al origen: reemplazar un secreto que ya existe para OTRO sitio movería su
            // atadura en silencio (una página inyectada pediría «gmail_password» estando en
            // evil.com y la contraseña quedaría atada a evil.com). Se rechaza ANTES de presentar;
            // la decisión de borrar el viejo es explícita (forget_secret).
            if let host = origen {
                for nombre in nombres {
                    if let previo = vault.origen(de: nombre), previo != host {
                        return AgentBrowserToolOutput.invalidArguments(
                            "Ya existe un secreto '\(nombre)' atado a otro sitio (\(previo)); esta página es \(host). "
                            + "No se ha presentado nada. Usa otro secret_name o, si el usuario lo quiere, borra el viejo con forget_secret.")
                    }
                }
            }
        }

        let respuesta: FormResponse
        do {
            respuesta = try await broker.presenta(spec, origen: origen, turno: turno)
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
    /// Todo o nada: si uno falla se deshacen los que ya se guardaron en ESTA llamada (los nuevos
    /// se borran; los que ya existían recuperan su valor, etiqueta y origen anteriores).
    ///
    /// Interna (no privada) para poder probar las ramas que `run` no alcanza por construcción
    /// (sin origen, campo `secret` sin nombre): esas ramas fallan CERRADO, sin devolver valores.
    func guarda(secretos: [FormField], origen: String?, en respuesta: FormResponse) -> String {
        // Sin campos secret no hay nada que guardar ni que atar: la respuesta va tal cual.
        if secretos.isEmpty { return FormResponse(status: .submitted, values: respuesta.values).json }
        // Sin origen no hay a qué atar nada. Antes se hacía `continue` y el valor crudo se quedaba
        // en `values` camino del modelo: ahora es un error que no lleva ningún valor.
        guard let origen else {
            return AgentBrowserToolOutput.invalidArguments(
                "No se sabe a qué sitio atar los secretos; no se ha guardado ninguno. Abre la página y vuelve a pedir el formulario.")
        }
        var valores = respuesta.values
        // Estado previo de cada nombre, capturado ANTES de escribir nada: el deshacer restaura lo
        // que había y solo borra lo que era nuevo. Valor y origen salen del MISMO registro (si hay
        // uno, hay el otro); la etiqueta sale del índice y puede faltar (un registro fuera del
        // índice): se restaura con lo que haya, usando la etiqueta del campo, en vez de borrarlo.
        let previos: [String: (valor: String, etiqueta: String, origen: String)] = Dictionary(
            uniqueKeysWithValues: secretos.compactMap { campo -> (String, (String, String, String))? in
                guard let n = campo.secretName, let v = vault.valor(de: n), let o = vault.origen(de: n) else { return nil }
                let e = vault.lista().first(where: { $0.name == n })?.etiqueta ?? campo.label
                return (n, (v, e, o))
            })
        var guardados: [String] = []
        /// Deshace lo guardado en esta llamada y devuelve los nombres que NO se pudieron restaurar.
        func deshaz() -> [String] {
            var sinRestaurar: [String] = []
            for n in guardados {
                if let p = previos[n] {
                    if !vault.guarda(name: n, value: p.valor, etiqueta: p.etiqueta, origen: p.origen) {
                        sinRestaurar.append(n)
                    }
                } else {
                    vault.borra(name: n)
                }
            }
            return sinRestaurar
        }
        /// El error de un guardado fallido. Nunca lleva valores, solo nombres; y no promete «no se
        /// ha guardado ninguno» si algún secreto previo se quedó con el valor nuevo.
        func fallo(_ motivo: String) -> String {
            let sinRestaurar = deshaz()
            guard sinRestaurar.isEmpty else {
                let lista = sinRestaurar.map { "'\($0)'" }.joined(separator: ", ")
                return AgentBrowserToolOutput.invalidArguments(
                    motivo + " Además NO se pudo restaurar el valor anterior de \(lista): puede haber quedado "
                    + "con el valor recién tecleado. Revísalo con list_secrets y avisa al usuario.")
            }
            return AgentBrowserToolOutput.invalidArguments(
                motivo + " No se ha guardado ninguno de los secretos de este formulario.")
        }
        for campo in secretos {
            guard let nombre = campo.secretName else {
                return fallo("El campo secret '\(campo.id)' no tiene secret_name.")
            }
            let valor = respuesta.values[campo.id] ?? ""
            if valor.isEmpty && !campo.required {
                // Opcional y vacío: no hay nada que guardar (la bóveda rechaza vacíos). Se dice
                // la verdad: el valor queda vacío, no «guardado».
                valores[campo.id] = ""
                continue
            }
            if !vault.guarda(name: nombre, value: valor, etiqueta: campo.label, origen: origen) {
                return fallo("No se pudo guardar el secreto '\(nombre)' (valor vacío o bóveda no disponible).")
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

    /// El host de la página abierta, o el error que se le devuelve al modelo.
    private func hostDeLaPaginaActual() async -> Pagina {
        let sinPagina = "abre primero la página donde se usará el secreto (con browser_open) y vuelve a pedir el formulario."
        guard let service else { return .failure(AgentBrowserToolOutput.invalidArguments(sinPagina)) }
        switch await PaginaActual.host(service: service, timeout: Self.timeout) {
        case .host(let h): return .host(h)
        case .sinPagina: return .failure(AgentBrowserToolOutput.invalidArguments(sinPagina))
        case .urlNoValida:
            return .failure(AgentBrowserToolOutput.invalidArguments(
                "No se pudo determinar el sitio de la página abierta (\"about:blank\" o URL no válida). \(sinPagina)"))
        }
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

/// El host de la página abierta en el navegador del agente. Lo comparten `present_form` (para
/// atar un secreto nuevo a su sitio) y `browser_fill_secret` (para comprobar esa atadura antes
/// de teclear): si cada uno lo calculara a su manera, un secreto guardado con una normalización
/// podría no coincidir nunca —o coincidir de más— con la otra.
enum PaginaActual {
    enum Resultado: Equatable {
        /// Host limpio: minúsculas, sin esquema, puerto, ruta ni query.
        case host(String)
        /// `get url` falló (no hay página, navegador caído, plazo vencido).
        case sinPagina
        /// Hay respuesta pero no es una URL con un host válido (`about:blank`, `data:`…).
        case urlNoValida
    }

    /// `SecretVault.guarda` no valida el origen que recibe, así que la limpieza es de aquí.
    static func host(service: AgentBrowserService, timeout: TimeInterval) async -> Resultado {
        let outcome = await service.run(command: ["get", "url"], sessioned: true, timeout: timeout)
        guard case .data(let datos) = AgentBrowserToolOutput.resolve(outcome) else { return .sinPagina }
        guard let url = AgentBrowserService.fields(datos)["url"] as? String,
              let host = URL(string: url)?.host?.lowercased(), !host.isEmpty,
              // Misma normalización estricta que la comparación de origen: un host que ella
              // no acepta nunca podría coincidir después, así que se rechaza ya.
              SecretVault.origenPermite(guardado: host, paginaActual: host)
        else { return .urlNoValida }
        return .host(host)
    }
}
