import Foundation
import Security
import XCTest
@testable import Gemma

/// El token del servicio de memoria sale de `UserDefaults` y entra en el llavero (Tarea 6b).
///
/// Lo que esta suite conserva, y el orden es el de lo que más cuesta perder:
///
/// 1. **El ciclo completo de la migración**, que es la mitad del valor: el usuario YA tiene su
///    token guardado en claro, así que no basta con que el sitio nuevo funcione.
/// 2. **Los tres lectores de producción**, uno por uno. Un lector olvidado deja el token viejo
///    vivo y el arreglo a medias; el tercero (`AtoZSessionManager`) no estaba en ningún plan.
/// 3. **La clase de accesibilidad del elemento GUARDADO** bajo esta cuenta, no la del código que
///    lo guarda. Es lo que cazó el defecto de la Tarea 6.
/// 4. **Que el token no salga en ningún texto**, medido en el extremo que importa: la descripción
///    del error de transporte que acaba viendo el usuario, con un fallo de transporte de verdad.
/// 5. **Que el placeholder débil cableado ya no esté en el fuente.**
///
/// El doble en memoria (`AlmacenEnMemoria`) y los ayudantes de red (`ProtocoloQueFalla`, `Captura`)
/// son los de `TokenDeConducirTests`: el almacén es el MISMO y reusar su doble es parte de que no
/// haya dos copias de nada.
@MainActor
final class TokenDeMemoriaTests: XCTestCase {

    // MARK: ayudantes

    /// Una suite de `UserDefaults` propia de la prueba, que se borra al terminar. Nunca
    /// `UserDefaults.standard`: ahí vive la configuración de verdad del usuario.
    private func sitioViejo(con token: String? = nil) -> UserDefaults {
        let nombre = "TokenDeMemoriaTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: nombre)!
        d.removePersistentDomain(forName: nombre)
        addTeardownBlock { d.removePersistentDomain(forName: nombre) }
        if let token { d.set(token, forKey: SettingsKeys.memoryBearerToken) }
        return d
    }

    private func enClaro(_ d: UserDefaults) -> String? {
        d.string(forKey: SettingsKeys.memoryBearerToken)
    }

    private func fuenteDeLaApp(_ relativa: String) throws -> String {
        let aqui = URL(fileURLWithPath: #filePath)
        let fichero = aqui.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma").appendingPathComponent(relativa)
        return try String(contentsOf: fichero, encoding: .utf8)
    }

    // MARK: la cuenta es OTRA, que es lo que hace que el `enum` hermano sea la forma correcta

    /// Los dos tokens son dos secretos distintos y no se pisan, aunque compartan el almacén, el
    /// servicio del llavero y toda la lógica.
    ///
    /// Es la propiedad que la otra forma posible (una sola `enum` con la `cuenta` como parámetro)
    /// no podía garantizar: ahí el llamante tiene que acordarse de pasar la cuenta correcta y
    /// pasar la equivocada compila.
    func test_el_token_de_memoria_y_el_del_navegador_no_se_pisan() {
        XCTAssertNotEqual(TokenDeMemoria.cuenta, TokenDeConducir.cuenta,
                          "dos secretos distintos no pueden compartir cuenta")
        XCTAssertNotEqual(TokenDeMemoria.claveVieja, TokenDeConducir.claveVieja)

        let almacen = AlmacenEnMemoria()
        let d = sitioViejo()
        TokenDeMemoria.guardar("TOK-MEMORIA", almacen: almacen, defaults: d)
        TokenDeConducir.guardar("TOK-NAVEGADOR", almacen: almacen, defaults: d)

        XCTAssertEqual(TokenDeMemoria.leer(almacen: almacen), "TOK-MEMORIA")
        XCTAssertEqual(TokenDeConducir.leer(almacen: almacen), "TOK-NAVEGADOR")
    }

    func test_el_sitio_viejo_es_la_clave_que_la_app_usaba() {
        XCTAssertEqual(TokenDeMemoria.claveVieja, "memoryBearerToken",
                       "si esto cambia, la migración no encuentra el token que el usuario ya tiene")
    }

    // MARK: el almacén guarda y devuelve

    func test_el_token_se_guarda_y_se_recupera_por_el_almacen_nuevo() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo()
        XCTAssertTrue(TokenDeMemoria.guardar("tok-mem-abc", almacen: almacen, defaults: d))
        XCTAssertEqual(TokenDeMemoria.leer(almacen: almacen), "tok-mem-abc")
    }

    func test_guardar_no_deja_el_token_en_userdefaults_y_si_lo_pone_en_el_almacen() {
        let almacen = AlmacenEnMemoria()
        // HABÍA algo en el sitio viejo. Sin esto la aserción de abajo se cumple con `guardar`
        // entero vacío, porque `nil` es el valor por omisión de una suite recién creada.
        let d = sitioViejo(con: "tok-en-claro-de-antes")
        XCTAssertEqual(enClaro(d), "tok-en-claro-de-antes", "el punto de partida, afirmado")
        TokenDeMemoria.guardar("tok-mem-abc", almacen: almacen, defaults: d)

        XCTAssertNil(enClaro(d), "el token no puede quedar en claro en UserDefaults")
        XCTAssertEqual(almacen.leer(cuenta: TokenDeMemoria.cuenta), "tok-mem-abc",
                       "y tiene que estar en el almacén: si no, no se guardó, solo se perdió")
    }

    func test_un_almacen_que_rechaza_la_escritura_lo_dice_y_aun_asi_limpia_el_sitio_viejo() {
        let almacen = AlmacenEnMemoria()
        almacen.rechazaEscrituras = true
        let d = sitioViejo(con: "tok-en-claro")

        XCTAssertFalse(TokenDeMemoria.guardar("tok-mem-abc", almacen: almacen, defaults: d),
                       "un rechazo del llavero no se puede tragar en silencio")
        XCTAssertNil(enClaro(d),
                     "aunque el llavero rechace, el token NO se queda en claro: ése es el defecto")
    }

    func test_el_token_se_recorta_al_guardar() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo()
        TokenDeMemoria.guardar("  tok-mem-abc\n", almacen: almacen, defaults: d)
        XCTAssertEqual(almacen.leer(cuenta: TokenDeMemoria.cuenta), "tok-mem-abc",
                       "lo que se guarda va ya recortado: un espacio pegado da un 401 del i3")
    }

    func test_guardar_el_token_vacio_borra_el_secreto_en_vez_de_guardar_una_cadena_vacia() {
        let almacen = AlmacenEnMemoria([TokenDeMemoria.cuenta: "tok-viejo"])
        let d = sitioViejo()
        XCTAssertTrue(TokenDeMemoria.guardar("   ", almacen: almacen, defaults: d))
        XCTAssertNil(almacen.leer(cuenta: TokenDeMemoria.cuenta),
                     "un token vacío es «no hay token», no un secreto fantasma")
        XCTAssertEqual(TokenDeMemoria.leer(almacen: almacen), "")
    }

    // MARK: la migración — el ciclo completo, que es la mitad del valor de esta tarea

    /// EL CICLO COMPLETO, y es la prueba que esta tarea existe para tener.
    ///
    /// La trampa que esquiva: «no queda nada en `UserDefaults`» se cumple en una máquina donde
    /// nunca hubo nada, porque `nil` es el valor por omisión, así que una prueba que solo afirme
    /// la ausencia pasa con la migración ENTERA borrada. El usuario ya tiene su token guardado en
    /// claro, así que lo que hay que probar es el ciclo: **había** algo en el sitio viejo →
    /// aparece en el almacén nuevo → se lee por el camino de producción → **y el sitio viejo
    /// devuelve `nil`**. Las cuatro, o la tarea no arregla nada y además deja dos copias.
    func test_el_ciclo_completo_de_la_migracion() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "tok-del-usuario")

        // El punto de partida, afirmado: hay un token en claro y el almacén nuevo está vacío.
        XCTAssertEqual(enClaro(d), "tok-del-usuario")
        XCTAssertNil(almacen.leer(cuenta: TokenDeMemoria.cuenta))

        XCTAssertTrue(TokenDeMemoria.migrar(almacen: almacen, defaults: d), "tiene que mover algo")
        XCTAssertEqual(TokenDeMemoria.leer(almacen: almacen), "tok-del-usuario",
                       "leer tiene que devolver el token que el usuario ya tenía escrito")
        XCTAssertEqual(almacen.leer(cuenta: TokenDeMemoria.cuenta), "tok-del-usuario",
                       "y tiene que haber quedado en el almacén nuevo")
        XCTAssertNil(enClaro(d),
                     "y el sitio viejo tiene que quedar VACÍO: si no, hay dos copias y una en claro")
    }

    /// El mismo ciclo, pero el lector es el de PRODUCCIÓN y el token es el placeholder que el
    /// usuario tiene hoy escrito. Es el estado real de su máquina antes de rotar.
    func test_el_ciclo_completo_hasta_el_lector_de_produccion() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "replace-me-with-a-long-random-string")
        d.set("http://i3.test:8081", forKey: "memoryBaseURL")
        XCTAssertEqual(enClaro(d), "replace-me-with-a-long-random-string", "el punto de partida")

        XCTAssertTrue(TokenDeMemoria.migrar(almacen: almacen, defaults: d))

        let ajustes = HarnessModel.memorySettings(defaults: d, almacen: almacen)
        XCTAssertEqual(ajustes?.token, "replace-me-with-a-long-random-string",
                       "el lector de producción tiene que ver el token que el usuario ya tenía")
        XCTAssertNil(enClaro(d), "y el sitio viejo quedó vacío")
    }

    func test_la_migracion_es_idempotente_y_la_segunda_vez_no_mueve_nada() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "tok-del-usuario")
        XCTAssertTrue(TokenDeMemoria.migrar(almacen: almacen, defaults: d), "la primera mueve")
        XCTAssertFalse(TokenDeMemoria.migrar(almacen: almacen, defaults: d), "la segunda ya no")
        XCTAssertEqual(almacen.leer(cuenta: TokenDeMemoria.cuenta), "tok-del-usuario",
                       "y no se pierde por el camino")
    }

    func test_el_almacen_manda_sobre_el_sitio_viejo_pero_el_sitio_viejo_se_limpia_igual() {
        let almacen = AlmacenEnMemoria([TokenDeMemoria.cuenta: "tok-nuevo"])
        let d = sitioViejo(con: "tok-rancio")
        XCTAssertFalse(TokenDeMemoria.migrar(almacen: almacen, defaults: d), "no pisa el nuevo")
        XCTAssertEqual(TokenDeMemoria.leer(almacen: almacen), "tok-nuevo",
                       "lo del llavero es más nuevo: al guardar se escribe primero el llavero")
        XCTAssertNil(enClaro(d), "y el rancio se va igual, que es lo que importa")
    }

    func test_un_token_en_blanco_en_el_sitio_viejo_no_se_guarda_pero_si_se_borra() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "   \n")
        XCTAssertFalse(TokenDeMemoria.migrar(almacen: almacen, defaults: d))
        XCTAssertNil(almacen.leer(cuenta: TokenDeMemoria.cuenta),
                     "no se guarda un secreto en blanco")
        XCTAssertNil(enClaro(d), "pero la clave vieja se va de todas formas")
    }

    func test_la_migracion_recorta_lo_que_mueve() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "  tok-del-usuario  ")
        TokenDeMemoria.migrar(almacen: almacen, defaults: d)
        XCTAssertEqual(almacen.leer(cuenta: TokenDeMemoria.cuenta), "tok-del-usuario")
    }

    /// Migrar el token de memoria **no toca el del navegador**, y al revés. Dos migraciones sobre
    /// el mismo almacén y la misma suite de preferencias no se estorban.
    func test_las_dos_migraciones_no_se_estorban() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "TOK-MEMORIA-VIEJO")
        d.set("TOK-NAVEGADOR-VIEJO", forKey: SettingsKeys.browserBearerToken)

        XCTAssertTrue(TokenDeMemoria.migrar(almacen: almacen, defaults: d))
        XCTAssertEqual(d.string(forKey: SettingsKeys.browserBearerToken), "TOK-NAVEGADOR-VIEJO",
                       "migrar el de memoria no puede borrar el sitio viejo del otro")
        XCTAssertTrue(TokenDeConducir.migrar(almacen: almacen, defaults: d))

        XCTAssertEqual(TokenDeMemoria.leer(almacen: almacen), "TOK-MEMORIA-VIEJO")
        XCTAssertEqual(TokenDeConducir.leer(almacen: almacen), "TOK-NAVEGADOR-VIEJO")
        XCTAssertNil(enClaro(d))
        XCTAssertNil(d.string(forKey: SettingsKeys.browserBearerToken))
    }

    // MARK: los TRES lectores de producción

    /// Lector 1 y 2: el cliente de memoria y el de voz, que comparten el mismo secreto.
    ///
    /// Parte del estado exacto que tendrá la máquina del usuario a medio migrar: hay un token
    /// viejo en `UserDefaults` y otro en el llavero. Si cualquiera de los dos lectores volviera a
    /// `defaults.string(forKey:)`, devolvería el viejo y esto se pone rojo. Y comprueba también
    /// que **leer no escribe**: la clave vieja sigue intacta.
    func test_los_lectores_de_memoria_y_de_voz_toman_el_token_del_llavero() {
        let almacen = AlmacenEnMemoria([TokenDeMemoria.cuenta: "TOKEN-DEL-LLAVERO"])
        let d = sitioViejo(con: "TOKEN-VIEJO-EN-CLARO")
        d.set("http://i3.test:8081", forKey: "memoryBaseURL")

        let memoria = HarnessModel.memorySettings(defaults: d, almacen: almacen)
        XCTAssertEqual(memoria?.token, "TOKEN-DEL-LLAVERO", "el cliente de memoria")
        XCTAssertEqual(memoria?.url.host, "i3.test", "y la URL sigue saliendo de los ajustes")

        let voz = HarnessModel.voiceSettings(defaults: d, almacen: almacen)
        XCTAssertEqual(voz?.token, "TOKEN-DEL-LLAVERO", "el cliente de voz, el MISMO secreto")
        XCTAssertEqual(voz?.url.port, 8082, "y su puerto se deriva del de memoria")

        XCTAssertEqual(enClaro(d), "TOKEN-VIEJO-EN-CLARO",
                       "leer NO escribe: una lectura no puede tocar la configuración del usuario")
    }

    /// Lector 3, EL QUE NO ESTABA EN NINGÚN PLAN: el camino de A to Z.
    ///
    /// `AtoZSessionManager` habla con el mismo servicio de memoria del i3 con el mismo token, en
    /// tres peticiones (subir, bajar y borrar la sesión), y `GemmaApp` llama a
    /// `syncSessionFromServer()` en cada arranque. Se mide donde se puede medir de verdad: en la
    /// cabecera `Authorization` de la petición que sale al cable.
    func test_el_camino_de_a_to_z_firma_con_el_token_del_llavero() async throws {
        let almacen = AlmacenEnMemoria([TokenDeMemoria.cuenta: "TOKEN-DEL-LLAVERO"])
        let d = sitioViejo(con: "TOKEN-VIEJO-EN-CLARO")
        d.set("http://atoz.test:8081", forKey: "memoryBaseURL")

        let captura = Captura()
        ProtocoloQueCaptura.stub = { peticion in
            captura.peticion = peticion
            return (HTTPURLResponse(url: peticion.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: nil)!, Data("{}".utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ProtocoloQueCaptura.self]

        let gestor = AtoZSessionManager.shared
        let almacenDeAntes = gestor.almacenDeSecretos
        let redDeAntes = gestor.red
        let ajustesDeAntes = gestor.ajustes
        // `defer`, no `addTeardownBlock`: el gestor es un SINGLETON, así que dejarlo apuntando a
        // una sesión efímera de esta prueba rompería a quien lo use después. Un `addTeardownBlock`
        // que salte a `@MainActor` dentro de un `Task` se ejecuta cuando le toca, que puede ser ya
        // empezada la prueba siguiente; `defer` corre al salir de ESTA función, también si lanza.
        defer {
            gestor.almacenDeSecretos = almacenDeAntes
            gestor.red = redDeAntes
            gestor.ajustes = ajustesDeAntes
        }
        gestor.almacenDeSecretos = almacen
        gestor.red = URLSession(configuration: cfg)
        gestor.ajustes = d

        await gestor.pushSessionToServer(cookie: "galleta", employeeId: "E1")

        let peticion = try XCTUnwrap(captura.peticion, "el stub no vio ninguna petición")
        XCTAssertEqual(peticion.value(forHTTPHeaderField: "Authorization"),
                       "Bearer TOKEN-DEL-LLAVERO",
                       "el tercer lector también tiene que firmar con el token del llavero")
        XCTAssertEqual(enClaro(d), "TOKEN-VIEJO-EN-CLARO", "y leer no escribe")
    }

    /// Y el placeholder cableado que ese mismo camino tenía: con el llavero vacío, ya **no**
    /// inventa un token. Firmar con una credencial conocida es peor que un 401.
    func test_sin_token_el_camino_de_a_to_z_no_inventa_el_placeholder() async throws {
        let d = sitioViejo()
        d.set("http://atoz.test:8081", forKey: "memoryBaseURL")

        let captura = Captura()
        ProtocoloQueCaptura.stub = { peticion in
            captura.peticion = peticion
            return (HTTPURLResponse(url: peticion.url!, statusCode: 401, httpVersion: nil,
                                    headerFields: nil)!, Data())
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ProtocoloQueCaptura.self]

        let gestor = AtoZSessionManager.shared
        let almacenDeAntes = gestor.almacenDeSecretos
        let redDeAntes = gestor.red
        let ajustesDeAntes = gestor.ajustes
        // `defer`, no `addTeardownBlock`: el gestor es un SINGLETON, así que dejarlo apuntando a
        // una sesión efímera de esta prueba rompería a quien lo use después. Un `addTeardownBlock`
        // que salte a `@MainActor` dentro de un `Task` se ejecuta cuando le toca, que puede ser ya
        // empezada la prueba siguiente; `defer` corre al salir de ESTA función, también si lanza.
        defer {
            gestor.almacenDeSecretos = almacenDeAntes
            gestor.red = redDeAntes
            gestor.ajustes = ajustesDeAntes
        }
        gestor.almacenDeSecretos = AlmacenEnMemoria()
        gestor.red = URLSession(configuration: cfg)
        gestor.ajustes = d

        await gestor.pushSessionToServer(cookie: "galleta", employeeId: "E1")

        let peticion = try XCTUnwrap(captura.peticion, "el stub no vio ninguna petición")
        // Guarda de vacuidad: la petición es la de verdad, con su destino.
        XCTAssertEqual(peticion.url?.host, "atoz.test")
        XCTAssertNil(peticion.value(forHTTPHeaderField: "Authorization"),
                     "sin token no se firma: un placeholder conocido no es un valor por omisión")
    }

    /// Y el mismo placeholder que `MemoryClient` cableaba: con el ajuste vacío firmaba con el
    /// token de fábrica del `.env` del i3, así que «token vacío → 401 visible» era mentira.
    func test_sin_token_el_cliente_de_memoria_no_inventa_el_placeholder() async {
        let captura = Captura()
        ProtocoloQueCaptura.stub = { peticion in
            captura.peticion = peticion
            return (HTTPURLResponse(url: peticion.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: nil)!, Data("{}".utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ProtocoloQueCaptura.self]
        let cliente = MemoryClient(baseURL: URL(string: "http://i3.test:8081")!, bearerToken: "",
                                   session: URLSession(configuration: cfg))

        try? await cliente.appendTranscript(threadId: "t", role: "you", text: "hola", turnIndex: 0)

        let cabecera = captura.peticion?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNotNil(captura.peticion, "el stub no vio ninguna petición")
        XCTAssertEqual(cabecera, "Bearer ",
                       "con el ajuste vacío se firma vacío y el i3 da 401; el placeholder cableado "
                       + "hacía que eso nunca se viera, porque el servidor llevaba ese mismo token")
    }

    /// Y el token que SÍ hay llega al cable.
    func test_el_cliente_de_memoria_firma_con_el_token_que_recibe() async {
        let captura = Captura()
        ProtocoloQueCaptura.stub = { peticion in
            captura.peticion = peticion
            return (HTTPURLResponse(url: peticion.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: nil)!, Data("{}".utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ProtocoloQueCaptura.self]
        let cliente = MemoryClient(baseURL: URL(string: "http://i3.test:8081")!,
                                   bearerToken: " TOKEN-ROTADO \n",
                                   session: URLSession(configuration: cfg))

        try? await cliente.appendTranscript(threadId: "t", role: "you", text: "hola", turnIndex: 0)

        XCTAssertEqual(captura.peticion?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer TOKEN-ROTADO", "recortado y en la cabecera")
        let url = captura.peticion?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/v1/transcript/append"), "la URL de verdad: \(url)")
        XCTAssertFalse(url.contains("TOKEN-ROTADO"), "y el token NO va en la URL: \(url)")
    }

    // MARK: que no se filtre

    /// EL EXTREMO QUE IMPORTA: el texto que el usuario acaba viendo cuando el i3 no contesta.
    ///
    /// Se provoca un fallo de transporte **de verdad** (`URLProtocol` que devuelve
    /// `URLError(.cannotConnectToHost)`) y se mira el mensaje tal como lo compone
    /// `MemoryInspectorView` —`"No se pudo conectar a \(baseURL): \(error.localizedDescription)"`—
    /// y el que las herramientas de memoria le pasan **al modelo** (`error.localizedDescription`,
    /// en `SearchMemoryTool`, `ScheduleTools`, …). Ninguno de los dos puede llevar el token: el
    /// primero lo vería el usuario en pantalla y el segundo acabaría en el contexto del modelo y,
    /// de ahí, en el servicio de consolidación.
    func test_la_descripcion_de_un_fallo_de_red_no_lleva_el_token() async {
        ProtocoloQueFalla.error = URLError(.cannotConnectToHost)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ProtocoloQueFalla.self]
        let cliente = MemoryClient(baseURL: URL(string: "http://i3.test:8081")!,
                                   bearerToken: "TOKEN-SECRETO-NO-DEBE-SALIR",
                                   session: URLSession(configuration: cfg))

        var capturado: Error?
        do {
            try await cliente.appendTranscript(threadId: "t", role: "you", text: "hola", turnIndex: 0)
        } catch {
            capturado = error
        }
        guard let error = capturado else { return XCTFail("esperaba un fallo de transporte") }

        // Los dos textos que de verdad se renderizan, compuestos igual que en producción.
        let enPantalla = "No se pudo conectar a \(cliente.baseURL.absoluteString): "
            + "\(error.localizedDescription)"
        let alModelo = "No se pudo buscar en la memoria: \(error.localizedDescription)"
        // Y el volcado crudo, que es lo que `HarnessModel` mete en `agentLog` con `"\(error)"`.
        let crudo = "\(error)"

        for texto in [enPantalla, alModelo, crudo] {
            // Guarda de vacuidad: «no contiene el token» se cumple en una cadena vacía. El texto
            // tiene que existir y tener algo del fallo real dentro.
            XCTAssertGreaterThan(texto.count, 20, "el mensaje tiene que ser el real: \(texto)")
            XCTAssertFalse(texto.contains("TOKEN-SECRETO"),
                           "ningún texto de error puede llevar el token: \(texto)")
        }
        // Y la guarda fuerte de vacuidad del primero: lleva el destino dentro.
        XCTAssertTrue(enPantalla.contains("i3.test"),
                      "el mensaje de pantalla tiene que llevar el destino: \(enPantalla)")
    }

    /// Y el 401 del servidor tampoco: el `message` de `ClientError.http` es el CUERPO de la
    /// respuesta, no nuestra petición. Es el camino que un token mal rotado recorre entero.
    func test_el_mensaje_de_un_401_no_lleva_el_token() async {
        ProtocoloQueCaptura.stub = { peticion in
            (HTTPURLResponse(url: peticion.url!, statusCode: 401, httpVersion: nil,
                             headerFields: nil)!, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ProtocoloQueCaptura.self]
        let cliente = MemoryClient(baseURL: URL(string: "http://i3.test:8081")!,
                                   bearerToken: "TOKEN-SECRETO-NO-DEBE-SALIR",
                                   session: URLSession(configuration: cfg))

        var capturado: Error?
        do {
            try await cliente.appendTranscript(threadId: "t", role: "you", text: "hola", turnIndex: 0)
        } catch {
            capturado = error
        }
        guard case .some(MemoryClient.ClientError.http(let status, let mensaje)) = capturado else {
            return XCTFail("esperaba un ClientError.http, got \(String(describing: capturado))")
        }
        // Guardas de vacuidad: es el 401 de verdad y trae el cuerpo del servidor.
        XCTAssertEqual(status, 401)
        XCTAssertTrue(mensaje.contains("unauthorized"), "got \(mensaje)")
        XCTAssertFalse("\(capturado!)".contains("TOKEN-SECRETO"),
                       "el error del 401 no puede llevar el token: \(capturado!)")
    }

    /// EL PLACEHOLDER DÉBIL YA NO ESTÁ EN EL FUENTE, en ninguno de los tres sitios que lo tenían.
    ///
    /// Estaba cableado tres veces: el valor por omisión del `@AppStorage` de Ajustes,
    /// `MemoryClient.effectiveToken` y `AtoZSessionManager.memoryBearerToken`. Los dos últimos
    /// hacían que «token vacío → 401 visible» fuera mentira, porque el servidor del i3 lleva ese
    /// mismo token de fábrica. Esta prueba es un trinquete: el día que alguien lo vuelva a
    /// escribir, se pone roja.
    func test_el_placeholder_debil_no_esta_cableado_en_ningun_fuente() throws {
        // Un ancla de CÓDIGO por fichero (no de comentario), para que las aserciones de ausencia
        // de abajo no pasen por tener la ruta mal o por un troceado roto.
        let ficheros = ["Settings/SettingsView.swift": "struct SettingsView: View {",
                        "Memory/MemoryClient.swift": "private var effectiveToken: String {",
                        "AtoZ/AtoZConfig.swift": "final class AtoZSessionManager: ObservableObject {",
                        "Harness/HarnessModel.swift": "static func memorySettings("]
        for (relativa, ancla) in ficheros {
            let completo = try fuenteDeLaApp(relativa)
            // Guarda de vacuidad: la ruta apunta a un fichero de verdad y con contenido.
            XCTAssertGreaterThan(completo.count, 500, "la ruta ya no apunta a \(relativa)")
            // SIN COMENTARIOS —con el troceado COMPARTIDO, `TroceadoDeFuente`— y esta prueba me
            // lo enseñó a mí: se puso roja por los dos comentarios que escribí documentando el
            // placeholder que acababa de quitar. La prohibición es sobre el CÓDIGO; dejar escrito
            // en prosa cuál era el defecto y por qué se fue es justo lo que hace que no vuelva.
            //
            // 🔴 Y LO QUE AQUÍ ESTABA ESCRITO Y ERA FALSO. No lo borro: la refutación vive pegada
            // al código, porque un comentario que dice «esto es seguro porque X» y resulta falso
            // ya costó dos rondas en este proyecto. Decía, textual:
            //
            //     «(El troceado parte también los `//` de una URL dentro de una cadena, lo que
            //      acorta la línea SIN ESCONDER NADA: un uso real del placeholder no vive detrás
            //      de un `//`.)»
            //
            // Las dos mitades están mal. «Sin esconder nada» es falso: lo que la línea acortada
            // esconde es todo lo que vaya DETRÁS en esa misma línea. Y «un uso real no vive detrás
            // de un `//`» es una afirmación sobre el contenido de HOY, no una propiedad: una línea
            // nueva la tumba. Medido con la suite ENTERA, con el troceado que esta prueba tenía
            // copiado aquí mismo:
            //
            //     let ayuda = "//"; let debil = "replace-me-…"; _ = debil
            //
            // en `MemoryClient` dejaba la suite en su verde exacto, con el placeholder débil
            // cableado dentro; la misma línea con `"x"` en vez de `"//"` ponía ESTA prueba roja.
            // El troceado es ahora el compartido, que distingue código de cadena, y lo que
            // defiende y lo que no está escrito en su propio fichero.
            let fuente = TroceadoDeFuente.sinComentarios(completo)
            // El literal se parte para que esta prueba no sea ella misma una copia del secreto
            // que busca... y para que el `grep` del día de mañana encuentre el motivo aquí.
            let literal = "\"replace-me-with" + "-a-long-random-string\""
            XCTAssertTrue(fuente.contains(ancla),
                          "guarda de vacuidad: tras quitar los comentarios, \(relativa) ya no "
                          + "contiene \(ancla). O la ruta está mal o el troceado está roto, y "
                          + "entonces la aserción de abajo pasaría sola.")
            // 🔴 LA AUSENCIA, SOBRE EL CRUDO (H7 de la revisión de rama, Ruling 18). Hasta la
            // ronda 6 iba sobre `fuente` —el troceado—, y una ausencia sobre el troceado se cumple
            // si el troceado se traga la línea: el próximo hueco léxico sería la credencial
            // conocida del `.env` del i3 recableada en el binario, **en verde**. Sobre el crudo lo
            // peor es lo contrario, un rojo por prosa, que es ruido visible: por eso los dos
            // comentarios de producción que citaban el literal entero (`MemoryClient`,
            // `AtoZConfig`) lo citan ahora cortado. El ancla de arriba sigue sobre el troceado,
            // porque es una PRESENCIA.
            XCTAssertFalse(completo.contains(literal),
                           """
                           \(relativa) vuelve a cablear el placeholder débil del `.env` del i3. \
                           Una credencial conocida en el binario no es un valor por omisión: con \
                           el ajuste vacío hay que firmar vacío y dejar que el i3 conteste 401.
                           """)
        }
    }

    // MARK: el llavero de verdad — la clase de accesibilidad, leída del elemento guardado

    /// LA CLASE DE ACCESIBILIDAD DE ESTE TOKEN, leída **del elemento guardado**, no del código
    /// que lo guarda.
    ///
    /// Es la prueba que la Tarea 6 nombra como la que cazó su defecto, aplicada a la cuenta nueva:
    /// `SecItemAdd` devolvía `errSecSuccess` **ignorando** la clase pedida, el elemento entraba en
    /// las copias de seguridad y el informe decía «hecho». Y es la misma clase que la Tarea 6
    /// midió, **sin `#if os(…)`**: `AfterFirstUnlockThisDeviceOnly` (macOS no da
    /// `WhenUnlocked*` a este proceso: `-25308`) con `kSecAttrSynchronizable: false` y
    /// `kSecUseDataProtectionKeychain: true` (sin el cual, en macOS, la clase se ignora en
    /// silencio).
    ///
    /// Servicio PROPIO de las pruebas y borrado al terminar: la entrada de producción del llavero
    /// tiene el token real del usuario y una prueba no tiene nada que hacer ahí.
    func test_la_clase_de_accesibilidad_del_token_de_memoria_es_la_del_dispositivo_solo() throws {
        let servicio = "pruebas.Gemma.tokenDeMemoria.\(UUID().uuidString)"
        let llavero = LlaveroDelSistema(servicio: servicio)
        let cuenta = TokenDeMemoria.cuenta
        addTeardownBlock { llavero.borrar(cuenta: cuenta) }
        let d = sitioViejo(con: "tok-del-usuario")

        // Se guarda por el camino de PRODUCCIÓN, no llamando al llavero a pelo: así esta prueba
        // también cubre que `guardar` no pierda la clase por el camino.
        try XCTSkipUnless(TokenDeMemoria.guardar("tok-del-usuario", almacen: llavero, defaults: d),
                          "el llavero rechazó la escritura (firma del binario de pruebas); "
                          + "la lógica del almacén se mide con el doble en memoria")
        XCTAssertEqual(TokenDeMemoria.leer(almacen: llavero), "tok-del-usuario",
                       "y se lee de vuelta por el mismo camino")
        XCTAssertNil(enClaro(d), "y el sitio viejo quedó vacío")

        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: cuenta,
            kSecAttrSynchronizable as String: false,
            // La misma bandera que usa producción: sin ella esta consulta mira OTRO llavero.
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var salida: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(consulta as CFDictionary, &salida), errSecSuccess)
        let atributos = try XCTUnwrap(salida as? [String: Any])

        let aplicada = try XCTUnwrap(
            atributos[kSecAttrAccessible as String] as? String,
            """
            el elemento se guardó SIN clase de accesibilidad. Es el defecto que esta prueba \
            existe para cazar: en macOS, sin `kSecUseDataProtectionKeychain`, el llavero de \
            ficheros ignora `kSecAttrAccessible` y `SecItemAdd` devuelve éxito igual, así que el \
            token de la memoria personal del usuario acabaría en las copias de seguridad con \
            todo en verde.
            """)

        let soloEsteDispositivo = [
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String,
        ]
        XCTAssertTrue(soloEsteDispositivo.contains(aplicada),
                      """
                      la clase \(aplicada) no es de la familia `ThisDeviceOnly`: el token \
                      entraría en las copias de seguridad y se restauraría en otro dispositivo.
                      """)
        XCTAssertEqual(aplicada, LlaveroDelSistema.claseDeAccesibilidad as String,
                       "la clase del elemento guardado y la que producción declara han derivado")
        XCTAssertNotEqual(atributos[kSecAttrSynchronizable as String] as? Bool, true,
                          "y no puede ser sincronizable")
    }

    // MARK: la vista y el arranque

    /// El campo de Ajustes y el arranque de la app, fijados en el fuente.
    ///
    /// No es un adorno: el `@AppStorage` que había era **el defecto**, y volver a ponerlo deshace
    /// la tarea entera sin que ninguna prueba de comportamiento se entere, porque el cuerpo de un
    /// `View` de SwiftUI no se ejecuta en esta suite.
    ///
    /// Y la línea de `GemmaApp` tiene una condición de ORDEN que un `contains` suelto no
    /// conserva: la migración tiene que estar **antes** de construir el `HarnessModel`, porque su
    /// `init` llama a `ensureVoice()`, que ya lee el token. Si se cayera al `.task` de abajo, el
    /// primer arranque tras la actualización dejaría al usuario sin voz hasta reiniciar.
    func test_la_vista_y_el_arranque_no_guardan_el_token_en_userdefaults() throws {
        // Las PRESENCIAS van sobre el fuente troceado y las AUSENCIAS sobre el crudo; el motivo,
        // con su medición, está en `TokenDeConducirTests` y en el doc-comment de
        // `TroceadoDeFuente`: una presencia sobre el crudo se cumple con la línea envuelta en
        // `/* */` —característica borrada, texto conservado—, y una ausencia sobre el troceado se
        // cumple si el troceado se traga la línea de la fuga.
        let ajustes = try fuenteDeLaApp("Settings/SettingsView.swift")
        let codigoDeAjustes = TroceadoDeFuente.sinComentarios(ajustes)

        // Guardas de vacuidad: que el fichero sea el que creemos y siga teniendo el campo, y que
        // el campo siga pintándose como secreto.
        XCTAssertTrue(codigoDeAjustes.contains("Section(\"Memory Service\")"),
                      "la ruta ya no apunta a SettingsView")
        XCTAssertTrue(codigoDeAjustes.contains("esSecreto: true, texto: $memoryBearerToken"),
                      "el campo del token sigue pintándose como secreto")

        XCTAssertFalse(ajustes.contains("@AppStorage(\"memoryBearerToken\")"),
                       "el token de memoria NO puede volver a `@AppStorage`: ése era el defecto")
        XCTAssertFalse(ajustes.contains("@AppStorage(SettingsKeys.memoryBearerToken)"),
                       "tampoco por la constante")
        XCTAssertTrue(codigoDeAjustes.contains("TokenDeMemoria.leer()"), "lo lee del llavero")
        XCTAssertTrue(codigoDeAjustes.contains("TokenDeMemoria.guardar(nuevo)"),
                      "y lo guarda en el llavero en cada cambio")
        XCTAssertTrue(codigoDeAjustes.contains("TokenDeMemoria.migrar()"),
                      "y migra al abrir Ajustes")

        // Sobre el código INCONDICIONAL: una migración de arranque dentro de un `#if` falta en
        // alguna plataforma, y la presencia sobre `sinComentarios` se cumplía igual (H1, ronda 6).
        let app = TroceadoDeFuente.codigoIncondicional(try fuenteDeLaApp("GemmaApp.swift"))
        XCTAssertTrue(app.contains("struct GemmaApp: App"), "la ruta ya no apunta a GemmaApp")
        let migracion = try XCTUnwrap(app.range(of: "TokenDeMemoria.migrar()"),
                                      "el arranque tiene que migrar: si no, quien no abra Ajustes "
                                      + "se queda el token en claro para siempre")
        let construccion = try XCTUnwrap(app.range(of: "return HarnessModel()"),
                                         "GemmaApp ya no construye el HarnessModel donde creemos: "
                                         + "revisa que la migración siga siendo anterior")
        XCTAssertTrue(migracion.upperBound <= construccion.lowerBound,
                      "la migración tiene que correr ANTES de construir el HarnessModel: su "
                      + "`init` llama a `ensureVoice()`, que ya lee el token del llavero")
    }

    /// Y los dos lectores de producción salen del almacén que el modelo recibe, no de uno global.
    /// Es lo que permite que ninguna prueba toque la entrada de producción del llavero.
    func test_el_modelo_lee_los_secretos_del_almacen_que_recibe() throws {
        let arnes = try fuenteDeLaApp("Harness/HarnessModel.swift")
        let codigoDelArnes = TroceadoDeFuente.sinComentarios(arnes)
        XCTAssertTrue(codigoDelArnes.contains("let almacenDeSecretos: any AlmacenDeSecretos"),
                      "la ruta ya no apunta a HarnessModel o el almacén dejó de ser inyectable")
        XCTAssertTrue(codigoDelArnes.contains("Self.memorySettings(almacen: almacenDeSecretos)"),
                      "`ensureMemory` tiene que usar el almacén inyectado")
        XCTAssertTrue(codigoDelArnes.contains("Self.voiceSettings(almacen: almacenDeSecretos)"),
                      "`ensureVoice` tiene que usar el almacén inyectado")
        XCTAssertFalse(arnes.contains("forKey: \"memoryBearerToken\""),
                       "ningún lector puede volver a `UserDefaults` por el token")
    }
}

// MARK: - ayudantes de red

/// Un `URLProtocol` que devuelve lo que el `stub` diga, para mirar la petición que sale al cable.
///
/// `VoiceClientTests.StubProtocol` hace lo mismo, pero `TokenDeMemoriaTests` no puede depender de
/// él: este fichero necesita un stub propio para poder tener dos pruebas con respuestas distintas
/// corriendo en la misma suite sin pisarse el `stub` estático. (Y `HTTPAgentBrowserInvokerTests`
/// tiene otro, pero ese fichero está detrás de `#if os(macOS)` y estas pruebas corren también en
/// iOS.)
final class ProtocoloQueCaptura: URLProtocol {
    nonisolated(unsafe) static var stub: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let stub = Self.stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (resp, data) = stub(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
