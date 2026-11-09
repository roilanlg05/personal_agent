import Foundation
import XCTest
@testable import Gemma

/// Doble en memoria del almacén de secretos.
///
/// No es privado a propósito: `HTTPAgentBrowserInvokerTests` y `BrowserCrossPlatformTests` lo
/// necesitan para que sus llamadas a los dos lectores de `HarnessModel` **no toquen el llavero de
/// verdad**. El usuario tiene su token real guardado en esta máquina y una prueba no tiene nada
/// que hacer ahí.
final class AlmacenEnMemoria: AlmacenDeSecretos, @unchecked Sendable {
    private var secretos: [String: String] = [:]
    /// Cuando está a `true`, toda escritura se rechaza, como un llavero mal firmado.
    var rechazaEscrituras = false

    init(_ inicial: [String: String] = [:]) { secretos = inicial }

    func leer(cuenta: String) -> String? { secretos[cuenta] }

    @discardableResult
    func escribir(_ valor: String, cuenta: String) -> Bool {
        if rechazaEscrituras { return false }
        secretos[cuenta] = valor
        return true
    }

    func borrar(cuenta: String) { secretos[cuenta] = nil }
}

@MainActor
final class TokenDeConducirTests: XCTestCase {

    // MARK: ayudantes

    /// Una suite de `UserDefaults` propia de la prueba, que se borra al terminar. Nunca
    /// `UserDefaults.standard`: ahí vive la configuración de verdad del usuario.
    private func sitioViejo(con token: String? = nil) -> UserDefaults {
        let nombre = "TokenDeConducirTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: nombre)!
        d.removePersistentDomain(forName: nombre)
        addTeardownBlock { d.removePersistentDomain(forName: nombre) }
        if let token { d.set(token, forKey: SettingsKeys.browserBearerToken) }
        return d
    }

    private func enClaro(_ d: UserDefaults) -> String? {
        d.string(forKey: SettingsKeys.browserBearerToken)
    }

    // MARK: el almacén guarda y devuelve

    func test_el_token_se_guarda_y_se_recupera_por_el_almacen_nuevo() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo()
        XCTAssertTrue(TokenDeConducir.guardar("tok-abc", almacen: almacen, defaults: d))
        XCTAssertEqual(TokenDeConducir.leer(almacen: almacen), "tok-abc")
    }

    func test_guardar_no_deja_el_token_en_userdefaults_y_si_lo_pone_en_el_almacen() {
        let almacen = AlmacenEnMemoria()
        // HABÍA algo en el sitio viejo. Sin esto la aserción de abajo se cumple con `guardar`
        // entero vacío, porque `nil` es el valor por omisión de una suite recién creada.
        let d = sitioViejo(con: "tok-en-claro-de-antes")
        XCTAssertEqual(enClaro(d), "tok-en-claro-de-antes", "el punto de partida, afirmado")
        TokenDeConducir.guardar("tok-abc", almacen: almacen, defaults: d)

        // LAS DOS MITADES. «No queda nada en `UserDefaults`» se cumple solo porque el almacén SÍ
        // lo tiene; sin la segunda aserción esta prueba pasaría con `guardar` entero vacío.
        XCTAssertNil(enClaro(d), "el token no puede quedar en claro en UserDefaults")
        XCTAssertEqual(almacen.leer(cuenta: TokenDeConducir.cuenta), "tok-abc",
                       "y tiene que estar en el almacén: si no, no se guardó, solo se perdió")
    }

    func test_un_almacen_que_rechaza_la_escritura_lo_dice_y_aun_asi_limpia_el_sitio_viejo() {
        let almacen = AlmacenEnMemoria()
        almacen.rechazaEscrituras = true
        let d = sitioViejo(con: "tok-en-claro")

        XCTAssertFalse(TokenDeConducir.guardar("tok-abc", almacen: almacen, defaults: d),
                       "un rechazo del llavero no se puede tragar en silencio")
        XCTAssertNil(enClaro(d),
                     "aunque el llavero rechace, el token NO se queda en claro: ése es el defecto")
    }

    func test_guardar_el_token_vacio_borra_el_secreto_en_vez_de_guardar_una_cadena_vacia() {
        let almacen = AlmacenEnMemoria([TokenDeConducir.cuenta: "tok-viejo"])
        let d = sitioViejo()
        XCTAssertTrue(TokenDeConducir.guardar("   ", almacen: almacen, defaults: d))
        XCTAssertNil(almacen.leer(cuenta: TokenDeConducir.cuenta),
                     "un token vacío es «no hay token», no un secreto fantasma")
        XCTAssertEqual(TokenDeConducir.leer(almacen: almacen), "")
    }

    func test_el_token_se_recorta_al_guardar() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo()
        TokenDeConducir.guardar("  tok-abc\n", almacen: almacen, defaults: d)
        XCTAssertEqual(almacen.leer(cuenta: TokenDeConducir.cuenta), "tok-abc",
                       "lo que se guarda va ya recortado: un espacio pegado da un 401 del i3")
    }

    func test_sin_nada_en_ningun_sitio_se_lee_la_cadena_vacia() {
        XCTAssertEqual(TokenDeConducir.leer(almacen: AlmacenEnMemoria()), "")
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
        XCTAssertNil(almacen.leer(cuenta: TokenDeConducir.cuenta))

        XCTAssertTrue(TokenDeConducir.migrar(almacen: almacen, defaults: d), "tiene que mover algo")
        XCTAssertEqual(TokenDeConducir.leer(almacen: almacen), "tok-del-usuario",
                       "leer tiene que devolver el token que el usuario ya tenía escrito")
        XCTAssertEqual(almacen.leer(cuenta: TokenDeConducir.cuenta), "tok-del-usuario",
                       "y tiene que haber quedado en el almacén nuevo")
        XCTAssertNil(enClaro(d),
                     "y el sitio viejo tiene que quedar VACÍO: si no, hay dos copias y una en claro")
    }

    func test_la_migracion_es_idempotente_y_la_segunda_vez_no_mueve_nada() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "tok-del-usuario")
        XCTAssertTrue(TokenDeConducir.migrar(almacen: almacen, defaults: d), "la primera mueve")
        XCTAssertFalse(TokenDeConducir.migrar(almacen: almacen, defaults: d), "la segunda ya no")
        XCTAssertEqual(almacen.leer(cuenta: TokenDeConducir.cuenta), "tok-del-usuario",
                       "y no se pierde por el camino")
    }

    func test_el_almacen_manda_sobre_el_sitio_viejo_pero_el_sitio_viejo_se_limpia_igual() {
        let almacen = AlmacenEnMemoria([TokenDeConducir.cuenta: "tok-nuevo"])
        let d = sitioViejo(con: "tok-rancio")
        XCTAssertFalse(TokenDeConducir.migrar(almacen: almacen, defaults: d), "no pisa el nuevo")
        XCTAssertEqual(TokenDeConducir.leer(almacen: almacen), "tok-nuevo",
                       "lo del llavero es más nuevo: al guardar se escribe primero el llavero")
        XCTAssertNil(enClaro(d), "y el rancio se va igual, que es lo que importa")
    }

    func test_un_token_en_blanco_en_el_sitio_viejo_no_se_guarda_pero_si_se_borra() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "   \n")
        XCTAssertFalse(TokenDeConducir.migrar(almacen: almacen, defaults: d))
        XCTAssertNil(almacen.leer(cuenta: TokenDeConducir.cuenta),
                     "no se guarda un secreto en blanco")
        XCTAssertNil(enClaro(d), "pero la clave vieja se va de todas formas")
    }

    func test_la_migracion_recorta_lo_que_mueve() {
        let almacen = AlmacenEnMemoria()
        let d = sitioViejo(con: "  tok-del-usuario  ")
        TokenDeConducir.migrar(almacen: almacen, defaults: d)
        XCTAssertEqual(almacen.leer(cuenta: TokenDeConducir.cuenta), "tok-del-usuario")
    }

    // MARK: los DOS lectores de producción, que son los que de verdad importan

    /// El token que llega al cable es el del LLAVERO, no el que quedara en claro.
    ///
    /// Parte del estado exacto que tendrá la máquina del usuario a medio migrar: hay un token
    /// viejo en `UserDefaults` y otro en el llavero. Y comprueba tres cosas de golpe: el token del
    /// llavero **llega a la cabecera `Authorization`** de la petición de verdad (si el lector
    /// volviera a `defaults.string(forKey:)`, llegaría el viejo y esto se pone rojo), **no
    /// aparece en la URL**, y el lector **no escribe**: la clave vieja sigue intacta, porque
    /// migrar es trabajo de `migrar`, no de `leer`.
    func test_el_invocador_firma_con_el_token_del_llavero_y_no_con_el_de_userdefaults() async throws {
        let almacen = AlmacenEnMemoria([TokenDeConducir.cuenta: "TOKEN-DEL-LLAVERO"])
        let d = sitioViejo(con: "TOKEN-VIEJO-EN-CLARO")
        d.set("http://i3.test:8083", forKey: SettingsKeys.browserBaseURL)

        let captura = Captura()
        VoiceClientTests.StubProtocol.stub = { peticion in
            captura.peticion = peticion
            return (HTTPURLResponse(url: peticion.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: nil)!,
                    Data(#"{"exitCode":0,"stdout":"{}","stderr":""}"#.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [VoiceClientTests.StubProtocol.self]

        let invocador = HarnessModel.browserInvoker(defaults: d,
                                                    session: URLSession(configuration: cfg),
                                                    almacen: almacen)
        _ = await invocador.invoke(arguments: ["get", "title"], timeout: 1)

        let peticion = try XCTUnwrap(captura.peticion, "el stub no vio ninguna petición")
        XCTAssertEqual(peticion.value(forHTTPHeaderField: "Authorization"),
                       "Bearer TOKEN-DEL-LLAVERO",
                       "el token del llavero tiene que llegar al cable, o el arreglo rompe el acceso")
        let url = try XCTUnwrap(peticion.url?.absoluteString)
        XCTAssertFalse(url.contains("TOKEN-DEL-LLAVERO"), "el token no va en la URL: \(url)")
        XCTAssertEqual(enClaro(d), "TOKEN-VIEJO-EN-CLARO",
                       "leer NO escribe: una lectura no puede tocar la configuración del usuario")
    }

    /// El otro lector, el del visor del panel, y hasta el handshake.
    ///
    /// Mismo estado a medio migrar, misma propiedad, medida donde se puede medir: en el token con
    /// el que se firma el handshake del socket. `makeRelayStream` reenvía el costurón
    /// `abreElSocket` que `BrowserRelayClient` ya tenía, así que esto no necesita red.
    func test_el_visor_firma_el_handshake_con_el_token_del_llavero_y_no_lo_mete_en_la_url() async throws {
        let almacen = AlmacenEnMemoria([TokenDeConducir.cuenta: "TOKEN-DEL-LLAVERO"])
        let d = sitioViejo(con: "TOKEN-VIEJO-EN-CLARO")
        d.set("http://i3.test:8083", forKey: SettingsKeys.browserBaseURL)

        let visto = Captura()
        let abrio = expectation(description: "el visor abrió el socket")
        // El cliente reintenta tras una caída, así que la fábrica puede llamarse más de una vez.
        abrio.assertForOverFulfill = false
        let visor = HarnessModel.makeRelayStream(defaults: d, almacen: almacen) { url, token in
            visto.anota(url: url, token: token)
            abrio.fulfill()
            return SocketQueSeCae()
        }
        let flujo = try XCTUnwrap(visor, "con URL válida tiene que haber visor")
        await fulfillment(of: [abrio], timeout: 10)
        // No se para el cliente a mano: `mando` es `any MandoDelNavegador` y no expone `stop`.
        // Al salir de la prueba se suelta el visor, su `AsyncStream` muere y su `onTermination`
        // cancela el bucle y cierra el socket. El socket de mentira se cae sin esperar nada, así
        // que los reintentos que queden son instantáneos y acotados (`shouldGiveUp`).
        _ = flujo

        XCTAssertEqual(visto.token, "TOKEN-DEL-LLAVERO",
                       "el handshake se firma con el token del llavero, no con el de UserDefaults")
        let url = try XCTUnwrap(visto.url?.absoluteString)
        XCTAssertTrue(url.contains("/v1/browser/stream"), "y la URL es la del visor: \(url)")
        XCTAssertFalse(url.contains("TOKEN"), "el token no va en la URL del socket: \(url)")
        XCTAssertEqual(enClaro(d), "TOKEN-VIEJO-EN-CLARO", "leer NO escribe")
    }

    // MARK: que no se filtre

    /// El camino que la excepción firmada del `?token=` deja abierto, y el que esta tarea cierra:
    /// **cualquier descripción de error que imprima la URL imprime el token con ella**.
    ///
    /// Medido en este cliente: no es alcanzable, porque los dos consumidores mandan el token en la
    /// cabecera `Authorization` y la URL no lo lleva. Esta prueba fija ese hecho para que no deje
    /// de ser verdad sin que nadie se entere: se provoca un fallo de transporte de verdad y se
    /// mira el texto que el usuario acabaría viendo.
    func test_la_descripcion_de_un_fallo_de_red_no_lleva_el_token() async {
        let almacen = AlmacenEnMemoria([TokenDeConducir.cuenta: "TOKEN-SECRETO-NO-DEBE-SALIR"])
        let d = sitioViejo()
        d.set("http://i3.test:8083", forKey: SettingsKeys.browserBaseURL)

        ProtocoloQueFalla.error = URLError(.cannotConnectToHost)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ProtocoloQueFalla.self]
        let invocador = HarnessModel.browserInvoker(defaults: d,
                                                    session: URLSession(configuration: cfg),
                                                    almacen: almacen)

        guard case .failure(.launchFailed(let motivo)) = await invocador
            .invoke(arguments: ["get", "title"], timeout: 1)
        else { return XCTFail("esperaba un fallo de transporte") }

        // Guarda de vacuidad: «no contiene el token» se cumple en una cadena vacía. El texto
        // tiene que existir y tiene que ser el de verdad, con el destino dentro.
        XCTAssertTrue(motivo.contains("i3.test"),
                      "el mensaje tiene que ser el real, con el destino: got \(motivo)")
        XCTAssertFalse(motivo.contains("TOKEN-SECRETO"),
                       "la descripción del error no puede llevar el token: got \(motivo)")
    }

    /// La URL del visor no puede llevar el token porque la función que la construye **no lo
    /// recibe**. Lo que se fija es que su query siga llevando solo `maxFps`: si alguien añadiera
    /// el token ahí, acabaría en los registros del relé y en el historial de un cliente web.
    func test_la_url_del_visor_solo_lleva_maxFps_en_la_query() throws {
        let url = try XCTUnwrap(BrowserRelayClient.socketURL(
            baseURL: XCTUnwrap(URL(string: "http://i3.test:8083")), maxFps: 25))
        // Guarda de vacuidad: que haya construido la URL del stream de verdad.
        XCTAssertTrue(url.absoluteString.contains("/v1/browser/stream"), url.absoluteString)
        let nombres = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map(\.name)
        XCTAssertEqual(nombres, ["maxFps"], "la query del visor solo lleva maxFps")
    }

    /// LISTA BLANCA de los identificadores del fichero del almacén, no lista negra.
    ///
    /// Por qué blanca. Medido en este proyecto el 2026-11-09: una lista negra de ocho palabras
    /// dejaba pasar **verdes** seis fugas reales, entre ellas `UserDefaults.standard.set` y el
    /// `userInfo` de `NotificationCenter`. Una lista blanca no tiene ese agujero: lo que no está
    /// en ella pone la prueba roja, y entonces alguien tiene que mirarlo.
    ///
    /// Qué conserva. Que el fichero por el que pasa el token **no nombre nada que registre,
    /// notifique, imprima ni persista en claro**. No hay en esta lista ni `PanelLog`, ni `print`,
    /// ni `Logger`, ni `os_log`, ni `NSLog`, ni `NotificationCenter`, ni `append`, ni
    /// `localizedDescription`, ni `description`, ni `URL`, ni `set` (el escritor de
    /// `UserDefaults`; sí está `removeObject`, que es el que la tarea necesita).
    ///
    /// Honestidad sobre lo que esta lista es y lo que no: se sembró con los identificadores
    /// medidos del fichero tal como quedó, así que hoy pasa por construcción. Su valor es de
    /// trinquete: el día que alguien meta una llamada que registre, esta prueba se pone roja y la
    /// decisión deja de ser silenciosa.
    func test_el_almacen_solo_usa_identificadores_permitidos() throws {
        let fuente = try fuenteDelAlmacen()

        // Guarda de vacuidad 1: que la ruta apunte al fichero de verdad. Todas las aserciones de
        // esta prueba son AUSENCIAS y pasarían solas con el fichero vacío o la ruta mal.
        for ancla in ["protocol AlmacenDeSecretos", "struct LlaveroDelSistema: AlmacenDeSecretos {",
                      "enum TokenDeConducir {", "kSecAttrAccessibleWhenUnlockedThisDeviceOnly"] {
            XCTAssertTrue(fuente.contains(ancla),
                          "la ruta del fuente ya no apunta al fichero de producción: falta \(ancla)")
        }

        let usados = Self.identificadoresDe(fuente: fuente)

        // Guarda de vacuidad 2: que el troceado haya extraído algo reconocible. Sin esto, un
        // fallo del troceado daría el conjunto vacío, que cabe en cualquier lista blanca.
        XCTAssertTrue(usados.contains("TokenDeConducir"),
                      "el troceado no funciona: no encuentra ni `TokenDeConducir`")
        XCTAssertTrue(usados.contains("migrar"), "el troceado no encuentra ni `migrar`")
        XCTAssertGreaterThan(usados.count, 60,
                             "el troceado devolvió \(usados.count): no ha leído el fichero")

        let deMas = usados.subtracting(Self.identificadoresPermitidos).sorted()
        XCTAssertEqual(deMas, [],
                       """
                       el almacén usa identificadores que no están en la lista blanca: \(deMas).
                       Si son legítimos, añádelos A MANO y mira dos veces que ninguno registra, \
                       notifica, imprime ni persiste en claro: por este fichero pasa un token que \
                       conduce un Chrome con la sesión de Google del usuario dentro.
                       """)
    }

    private func fuenteDelAlmacen() throws -> String {
        let aqui = URL(fileURLWithPath: #filePath)
        let fichero = aqui.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/Settings/TokenDeConducir.swift")
        return try String(contentsOf: fichero, encoding: .utf8)
    }

    /// Los identificadores que el fichero del almacén puede contener, y ni uno más.
    private static let identificadoresPermitidos: Set<String> = [
        // los tipos y las importaciones
        "AlmacenDeSecretos", "Any", "Bool", "CFDictionary", "CFTypeRef", "Data", "Foundation",
        "LlaveroDelSistema", "Security", "Sendable", "SettingsKeys", "String", "TokenDeConducir",
        "UserDefaults",
        // palabras clave de Swift, atributos y miembros del lenguaje
        "any", "as", "discardableResult", "else", "enum", "false", "func", "guard", "if",
        "import", "in", "init", "let", "nil", "private", "protocol", "public", "return", "self",
        "static", "struct", "true", "var", "_",
        // la API del llavero: las tres operaciones y las claves de la consulta
        "SecItemAdd", "SecItemCopyMatching", "SecItemDelete", "errSecSuccess",
        "kSecAttrAccessible", "kSecAttrAccessibleWhenUnlockedThisDeviceOnly", "kSecAttrAccount",
        "kSecAttrService", "kSecAttrSynchronizable", "kSecClass", "kSecClassGenericPassword",
        "kSecMatchLimit", "kSecMatchLimitOne", "kSecReturnData", "kSecValueData",
        "kSecUseDataProtectionKeychain",
        // la API pública del almacén y del token
        "borrar", "compartido", "cuenta", "escribir", "guardar", "leer", "migrar", "servicio",
        "valor",
        // Foundation, solo lectura y recorte: `removeObject` BORRA la clave vieja, que es el
        // trabajo de esta tarea; `set` (el escritor de UserDefaults) NO está en la lista.
        "defaults", "encoding", "forKey", "isEmpty", "removeObject", "standard", "string",
        "trimmingCharacters", "utf8", "whitespacesAndNewlines", "browserBearerToken",
        // los nombres locales
        "aceptado", "clave", "consulta", "data", "datos", "limpio", "movido", "nuevo", "salida",
        "texto", "viejo", "almacen",
        // los trozos del nombre del servicio del llavero, que es una cadena literal
        "lambert", "dev", "group", "Gemma", "secretos",
    ]

    /// Los identificadores de un fuente Swift, **sin los comentarios** (son prosa y meterían
    /// cientos de palabras, que es lo que haría inútil la lista blanca). El troceado reconoce
    /// letras Unicode a propósito: los identificadores de este proyecto llevan `ñ`.
    private static func identificadoresDe(fuente: String) -> Set<String> {
        let sinComentarios = fuente.split(separator: "\n", omittingEmptySubsequences: false)
            .map { linea -> String in
                guard let corte = linea.range(of: "//") else { return String(linea) }
                return String(linea[linea.startIndex..<corte.lowerBound])
            }
            .joined(separator: "\n")

        var encontrados: Set<String> = []
        var actual = ""
        for caracter in sinComentarios.unicodeScalars {
            let esLetra = CharacterSet.letters.contains(caracter)
            let esDigito = CharacterSet.decimalDigits.contains(caracter)
            if esLetra || caracter == "_" || (!actual.isEmpty && esDigito) {
                actual.unicodeScalars.append(caracter)
            } else {
                if !actual.isEmpty { encontrados.insert(actual) }
                actual = ""
            }
        }
        if !actual.isEmpty { encontrados.insert(actual) }
        return encontrados
    }

    // MARK: el llavero de verdad — medido, no heredado

    /// El camino del llavero de verdad, sobre un servicio PROPIO de las pruebas y borrado al
    /// terminar. Nunca la cuenta de producción: el usuario tiene su token real en esta máquina.
    ///
    /// Medición (2026-11-09, ver el informe de la Tarea 6): esta prueba corre en el simulador de
    /// iOS y en el binario de pruebas de macOS de este proyecto sin diálogo y sin error de firma.
    /// Si algún día falla con `-34018` (`errSecMissingEntitlement`), es firma del binario de
    /// pruebas, no el almacén: el resto de esta suite mide la lógica contra el doble en memoria.
    func test_el_llavero_de_verdad_guarda_lee_sobrescribe_y_borra() throws {
        let servicio = "pruebas.Gemma.tokenDeConducir.\(UUID().uuidString)"
        let llavero = LlaveroDelSistema(servicio: servicio)
        let cuenta = "tokenDePrueba"
        addTeardownBlock { llavero.borrar(cuenta: cuenta) }

        XCTAssertNil(llavero.leer(cuenta: cuenta), "el servicio es nuevo: no puede haber nada")
        try XCTSkipUnless(llavero.escribir("secreto-1", cuenta: cuenta),
                          "el llavero rechazó la escritura (firma del binario de pruebas); "
                          + "la lógica del almacén se mide con el doble en memoria")
        XCTAssertEqual(llavero.leer(cuenta: cuenta), "secreto-1")
        XCTAssertTrue(llavero.escribir("secreto-2", cuenta: cuenta))
        XCTAssertEqual(llavero.leer(cuenta: cuenta), "secreto-2", "sobrescribe, no duplica")
        llavero.borrar(cuenta: cuenta)
        XCTAssertNil(llavero.leer(cuenta: cuenta))
    }

    /// LA CLASE DE ACCESIBILIDAD, leída del elemento guardado, no del código que lo guarda.
    ///
    /// Es la mitad de esta tarea y la que es fácil dar por hecha. El plan dice que `UserDefaults`
    /// «se respalda, se sincroniza y se lee sin desbloquear nada»: son TRES defectos.
    /// `WhenUnlockedThisDeviceOnly` quita los tres —no entra en copias de seguridad, no se
    /// restaura en otro dispositivo, y no se lee con el dispositivo bloqueado—. Guardarlo con
    /// `AfterFirstUnlock` o con la familia sincronizable arreglaría uno y el informe diría
    /// «hecho», que es exactamente el fallo que esta prueba existe para impedir.
    func test_la_clase_de_accesibilidad_es_la_del_dispositivo_solo_y_sin_respaldo() throws {
        let servicio = "pruebas.Gemma.accesibilidad.\(UUID().uuidString)"
        let llavero = LlaveroDelSistema(servicio: servicio)
        let cuenta = "tokenDePrueba"
        addTeardownBlock { llavero.borrar(cuenta: cuenta) }
        try XCTSkipUnless(llavero.escribir("secreto", cuenta: cuenta),
                          "el llavero rechazó la escritura (firma del binario de pruebas)")

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
        XCTAssertEqual(atributos[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                       "el token tiene que ser WhenUnlockedThisDeviceOnly: sin respaldo, sin "
                       + "sincronización, y no legible con el dispositivo bloqueado")
        XCTAssertEqual(atributos[kSecAttrSynchronizable as String] as? Bool, false,
                       "y no sincronizable")
    }

    // MARK: la vista y el arranque, que son los dos sitios donde se escribe y se migra

    /// El campo de Ajustes y el arranque de la app, fijados en el fuente.
    ///
    /// No es un adorno: el `@AppStorage` que había era **el defecto**, y volver a ponerlo
    /// deshace la tarea entera sin que ninguna prueba de comportamiento se entere, porque el
    /// cuerpo de un `View` de SwiftUI no se ejecuta en esta suite. Lo mismo con la migración del
    /// arranque: si se cae de `GemmaApp`, el usuario que no vuelva a abrir Ajustes se queda el
    /// token en claro para siempre.
    func test_la_vista_y_el_arranque_no_guardan_el_token_en_userdefaults() throws {
        let ajustes = try fuenteDeLaApp("Settings/SettingsView.swift")

        // Guarda de vacuidad: que el fichero sea el que creemos y siga teniendo el campo.
        XCTAssertTrue(ajustes.contains("Section(\"Navegador (i3)\")"),
                      "la ruta ya no apunta a SettingsView")
        XCTAssertTrue(ajustes.contains("esSecreto: true, texto: $browserBearerToken"),
                      "el campo del token sigue pintándose como secreto")

        XCTAssertFalse(ajustes.contains("@AppStorage(SettingsKeys.browserBearerToken)"),
                       "el token de conducir NO puede volver a `@AppStorage`: ése era el defecto")
        XCTAssertTrue(ajustes.contains("TokenDeConducir.leer()"), "lo lee del llavero")
        XCTAssertTrue(ajustes.contains("TokenDeConducir.guardar(nuevo)"),
                      "y lo guarda en el llavero en cada cambio")
        XCTAssertTrue(ajustes.contains("TokenDeConducir.migrar()"),
                      "y migra al abrir Ajustes")

        let app = try fuenteDeLaApp("GemmaApp.swift")
        XCTAssertTrue(app.contains("struct GemmaApp: App"), "la ruta ya no apunta a GemmaApp")
        XCTAssertTrue(app.contains("TokenDeConducir.migrar()"),
                      "el arranque tiene que migrar: si no, quien no abra Ajustes se queda el "
                      + "token en claro para siempre")
    }

    private func fuenteDeLaApp(_ relativa: String) throws -> String {
        let aqui = URL(fileURLWithPath: #filePath)
        let fichero = aqui.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma").appendingPathComponent(relativa)
        return try String(contentsOf: fichero, encoding: .utf8)
    }

    /// Dos servicios distintos no se ven el uno al otro. Es lo que hace seguro que el llavero de
    /// las pruebas no pueda tocar el de producción.
    func test_dos_servicios_del_llavero_no_se_pisan() throws {
        let a = LlaveroDelSistema(servicio: "pruebas.Gemma.a.\(UUID().uuidString)")
        let b = LlaveroDelSistema(servicio: "pruebas.Gemma.b.\(UUID().uuidString)")
        addTeardownBlock { a.borrar(cuenta: "x"); b.borrar(cuenta: "x") }
        try XCTSkipUnless(a.escribir("de-a", cuenta: "x"),
                          "el llavero rechazó la escritura (firma del binario de pruebas)")
        XCTAssertNil(b.leer(cuenta: "x"), "el servicio b no puede ver el secreto del servicio a")
        XCTAssertEqual(a.leer(cuenta: "x"), "de-a")
    }
}

// MARK: - ayudantes de red

/// Lo que el stub vio: la última petición HTTP, o el par (URL, token) del handshake del socket.
final class Captura: @unchecked Sendable {
    private let candado = NSLock()
    private var _peticion: URLRequest?
    private var _url: URL?
    private var _token: String?

    var peticion: URLRequest? {
        get { candado.withLock { _peticion } }
        set { candado.withLock { _peticion = newValue } }
    }
    var url: URL? { candado.withLock { _url } }
    var token: String? { candado.withLock { _token } }

    func anota(url: URL, token: String) { candado.withLock { _url = url; _token = token } }
}

/// Un socket del visor que se cae en cuanto se lee. Suficiente para observar el handshake sin
/// red, y sin riesgo de colgar la suite: no espera nada, lanza.
final class SocketQueSeCae: SocketDelVisor, @unchecked Sendable {
    enum Fallo: Error { case seCayo }
    func recibeTexto() async throws -> String? { throw Fallo.seCayo }
    func envia(_ texto: String) async throws { throw Fallo.seCayo }
    func cierra() {}
}

/// Un `URLProtocol` que falla el transporte, para mirar el texto del error que ve el usuario.
/// `HTTPAgentBrowserInvokerTests` tiene uno igual, pero ese fichero está detrás de
/// `#if os(macOS)` y esta prueba corre también en iOS.
final class ProtocoloQueFalla: URLProtocol {
    nonisolated(unsafe) static var error: Error = URLError(.cannotConnectToHost)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: Self.error) }
    override func stopLoading() {}
}
