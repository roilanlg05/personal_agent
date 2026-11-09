import Foundation
import Security
import XCTest
@testable import Gemma

/// Un almacén que **acepta la escritura y después no devuelve lo escrito**.
///
/// No es un caso de laboratorio: es exactamente lo que hacía el llavero de ficheros en macOS
/// según la medición de la Tarea 6 —`SecItemAdd` devolvía `errSecSuccess` y el elemento se
/// guardaba sin la clase pedida— y es la forma en que un cambio de llavero puede «funcionar» al
/// escribir y no al leer. Si la migración se fiara del `Bool` de la escritura, aquí borraría el
/// camino viejo y la key del usuario dejaría de existir.
final class AlmacenQueNoDevuelveLoQueEscribe: AlmacenDeSecretos, @unchecked Sendable {
    private(set) var escrituras = 0
    private(set) var borrados = 0
    func leer(cuenta: String) -> String? { nil }
    @discardableResult
    func escribir(_ valor: String, cuenta: String) -> Bool { escrituras += 1; return true }
    func borrar(cuenta: String) { borrados += 1 }
}

/// Un transporte que falla de verdad, para medir qué texto acaba viendo el usuario.
final class FalloDeTransporteDeProveedor: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}

@MainActor
final class ClaveDeProveedorTests: XCTestCase {

    /// La key de pega de todas las pruebas. Larga y reconocible a propósito: las pruebas de fuga
    /// buscan esta cadena dentro de textos que podrían llevarla sin que nadie se diera cuenta.
    private static let claveDePega = "sk-PRUEBA-NO-ES-UNA-CLAVE-DE-VERDAD-9f3a1c"

    // MARK: ayudantes

    /// Una suite de `UserDefaults` propia de la prueba, que se borra al terminar. **Nunca
    /// `UserDefaults.standard`:** ahí vive la configuración de verdad del usuario, y el proveedor
    /// de chat por omisión de esta app depende de una de sus API keys de pago.
    private func sitioViejo(copiaEnClaro: String? = nil, proveedor: String = "cerebras") -> UserDefaults {
        let nombre = "ClaveDeProveedorTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: nombre)!
        d.removePersistentDomain(forName: nombre)
        addTeardownBlock { d.removePersistentDomain(forName: nombre) }
        if let copiaEnClaro {
            d.set(copiaEnClaro, forKey: ClaveDeProveedor.claveEnClaro(ClaveDeProveedor.cuenta(proveedor)))
        }
        return d
    }

    private func enClaro(_ d: UserDefaults, proveedor: String = "cerebras") -> String? {
        d.string(forKey: ClaveDeProveedor.claveEnClaro(ClaveDeProveedor.cuenta(proveedor)))
    }

    // MARK: los nombres, que es lo único que no se puede equivocar

    /// Los dos nombres con los que están escritas las keys que el usuario tiene guardadas hoy.
    ///
    /// Por qué una prueba tan tonta merece existir: un nombre mal construido **no rompe nada
    /// visible**. La migración no encuentra nada, devuelve `noHabiaNada`, y la key del usuario se
    /// queda en el sitio viejo con el informe diciendo «migrado». Son cadenas copiadas del código
    /// que las escribió (`KeychainStore`, borrado en esta tarea), no inventadas aquí.
    func test_la_cuenta_y_la_copia_en_claro_se_construyen_con_los_nombres_del_codigo_viejo() {
        XCTAssertEqual(ClaveDeProveedor.cuenta("cerebras"), "apiKey.cerebras")
        XCTAssertEqual(ClaveDeProveedor.cuenta("claude"), "apiKey.claude")
        XCTAssertEqual(ClaveDeProveedor.claveEnClaro("apiKey.cerebras"),
                       "keychain_fallback.apiKey.cerebras")
        XCTAssertEqual(LlaveroViejoDeApiKeys.servicioDeLasApiKeys,
                       "lambert-dev-group.Gemma.apiKeys")
    }

    /// Los cuatro proveedores de pago entran en la migración, y los dos locales también (es un
    /// no-op, pero si alguien les pone key algún día no se queda fuera).
    func test_la_migracion_cubre_los_cuatro_proveedores_de_pago() {
        let todos = ClaveDeProveedor.todosLosProveedores
        for pago in ["gemini", "cerebras", "groq", "claude"] {
            XCTAssertTrue(todos.contains(pago), "el proveedor de pago \(pago) se queda sin migrar")
        }
        XCTAssertEqual(Set(todos), Set(ModelProvider.Kind.allCases.map(\.rawValue)),
                       "la lista tiene que salir de `allCases`, no de una lista a mano")
    }

    // MARK: el ciclo completo de la migración, las dos fuentes

    /// EL CICLO COMPLETO desde el llavero viejo, con la trampa de vacuidad cerrada.
    ///
    /// «No queda nada en el sitio viejo» se cumple en una máquina donde nunca hubo nada, porque
    /// `nil` es el valor por omisión. Medido en este Mac el 2026-11-09: el usuario tiene **dos**
    /// API keys en el llavero viejo (`apiKey.cerebras` y `apiKey.claude`, el servicio
    /// `lambert-dev-group.Gemma.apiKeys`), así que el punto de partida de esta prueba es el suyo.
    /// Se afirman las cuatro cosas, y en este orden: había algo, el almacén nuevo estaba vacío, se
    /// lee por el camino nuevo, y el sitio viejo quedó vacío.
    func test_el_ciclo_completo_de_la_migracion_desde_el_llavero_viejo() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": Self.claveDePega])
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo()

        XCTAssertEqual(viejo.leer(cuenta: "apiKey.cerebras"), Self.claveDePega,
                       "el punto de partida, afirmado: HABÍA una key en el sitio viejo")
        XCTAssertNil(nuevo.leer(cuenta: "apiKey.cerebras"), "y el almacén nuevo estaba vacío")

        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "cerebras", almacen: nuevo,
                                               viejo: viejo, defaults: d), .migrada)

        XCTAssertEqual(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo),
                       Self.claveDePega, "se lee por el camino nuevo")
        XCTAssertNil(viejo.leer(cuenta: "apiKey.cerebras"), "y el elemento viejo quedó borrado")
        XCTAssertNil(enClaro(d), "y la copia en claro, también")
    }

    /// El mismo ciclo desde la **copia en claro**, que es la otra mitad del camino viejo.
    func test_el_ciclo_completo_de_la_migracion_desde_la_copia_en_claro() {
        let viejo = AlmacenEnMemoria()
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo(copiaEnClaro: Self.claveDePega)

        XCTAssertEqual(enClaro(d), Self.claveDePega,
                       "el punto de partida, afirmado: HABÍA una copia en claro")
        XCTAssertNil(nuevo.leer(cuenta: "apiKey.cerebras"))

        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "cerebras", almacen: nuevo,
                                               viejo: viejo, defaults: d), .migrada)

        XCTAssertEqual(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo),
                       Self.claveDePega)
        XCTAssertNil(enClaro(d), "y la copia en claro quedó borrada")
    }

    /// 🔴 LA PRUEBA QUE EXISTE PORQUE LO CONTRARIO SERÍA VERDE Y NO ESTARÍA ARREGLADO.
    ///
    /// Mientras la lectura cayera a `keychain_fallback.<cuenta>`, cambiar de llavero «funcionaría»
    /// sin que nadie se enterara y las keys del usuario seguirían en claro para siempre. Aquí,
    /// después de migrar, se **vacía el almacén nuevo** y se vuelve a poner la copia en claro: si
    /// la lectura tuviera el camino de atrás, devolvería la key. Tiene que devolver `nil`.
    func test_tras_migrar_la_lectura_funciona_y_no_cae_a_la_copia_en_claro() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": Self.claveDePega])
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo(copiaEnClaro: Self.claveDePega)

        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "cerebras", almacen: nuevo,
                                               viejo: viejo, defaults: d), .migrada)
        XCTAssertNil(enClaro(d), "la copia en claro se borró")
        XCTAssertEqual(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo),
                       Self.claveDePega,
                       "y la lectura sigue funcionando CON la copia en claro borrada")

        // Y ahora al revés: la copia en claro vuelve, el almacén nuevo se vacía.
        nuevo.borrar(cuenta: "apiKey.cerebras")
        d.set(Self.claveDePega,
              forKey: ClaveDeProveedor.claveEnClaro(ClaveDeProveedor.cuenta("cerebras")))
        XCTAssertEqual(enClaro(d), Self.claveDePega, "el punto de partida, afirmado")
        XCTAssertNil(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo),
                     """
                     la lectura cayó a la copia EN CLARO de `UserDefaults`. Es el defecto que esta \
                     tarea existe para quitar: con esa caída, cambiar de llavero no rompe nada, el \
                     usuario no nota nada, y la migración de verdad no se hace nunca.
                     """)
    }

    // MARK: el orden que protege las keys — nada se borra sin verificar

    /// 🔴 SI LA ESCRITURA NUEVA FALLA, NO SE BORRA NADA.
    ///
    /// Perder una key cuesta que el usuario la vuelva a pegar; perder las cuatro en silencio es el
    /// fallo que esta tarea existe para no cometer. Un llavero puede decir no por firma del
    /// binario: la Tarea 6 lo midió (`-25308` con la clase que el plan pedía).
    func test_si_la_escritura_nueva_falla_no_se_borra_nada_del_camino_viejo() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": Self.claveDePega])
        let nuevo = AlmacenEnMemoria()
        nuevo.rechazaEscrituras = true
        let d = sitioViejo(copiaEnClaro: Self.claveDePega)

        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "cerebras", almacen: nuevo,
                                               viejo: viejo, defaults: d), .falloLaEscritura)

        XCTAssertEqual(viejo.leer(cuenta: "apiKey.cerebras"), Self.claveDePega,
                       "el elemento viejo TIENE que seguir ahí")
        XCTAssertEqual(enClaro(d), Self.claveDePega,
                       "y la copia en claro también: es la única copia que queda")
        XCTAssertNil(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo))
    }

    /// 🔴 Y SI LA ESCRITURA DICE QUE SÍ PERO NO SE LEE DE VUELTA, TAMPOCO SE BORRA NADA.
    ///
    /// Es el caso de verdad, no el teórico: añadir `kSecUseDataProtectionKeychain` **cambia de
    /// llavero**, y un llavero que acepta la escritura y no devuelve el valor es exactamente lo
    /// que la Tarea 6 midió en macOS. Fiarse del `Bool` de la escritura habría borrado las keys.
    func test_si_no_se_lee_de_vuelta_lo_escrito_no_se_borra_nada_del_camino_viejo() {
        let viejo = AlmacenEnMemoria(["apiKey.claude": Self.claveDePega])
        let nuevo = AlmacenQueNoDevuelveLoQueEscribe()
        let d = sitioViejo(copiaEnClaro: Self.claveDePega, proveedor: "claude")

        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "claude", almacen: nuevo,
                                               viejo: viejo, defaults: d), .noSeLeyoDeVuelta)

        XCTAssertEqual(nuevo.escrituras, 1, "el punto de partida: la escritura SÍ se intentó")
        XCTAssertEqual(viejo.leer(cuenta: "apiKey.claude"), Self.claveDePega,
                       "el elemento viejo TIENE que seguir ahí")
        XCTAssertEqual(enClaro(d, proveedor: "claude"), Self.claveDePega)
        XCTAssertEqual(nuevo.borrados, 0, "y no se tocó nada en el almacén nuevo")
    }

    // MARK: el resto de la migración

    func test_la_migracion_es_idempotente_y_la_segunda_vez_solo_limpia() {
        let viejo = AlmacenEnMemoria(["apiKey.groq": Self.claveDePega])
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo(copiaEnClaro: Self.claveDePega, proveedor: "groq")

        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "groq", almacen: nuevo,
                                               viejo: viejo, defaults: d), .migrada)
        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "groq", almacen: nuevo,
                                               viejo: viejo, defaults: d), .yaEstaba)
        XCTAssertEqual(ClaveDeProveedor.leer(proveedor: "groq", almacen: nuevo), Self.claveDePega,
                       "y la segunda pasada no pisó ni borró la key ya migrada")
    }

    /// Ya migrada pero con basura en el sitio viejo: la basura se va igual. Una copia en claro que
    /// sobrevive «porque ya estaba migrada» es el mismo agujero.
    func test_aunque_ya_estuviera_migrada_los_sitios_viejos_se_vacian() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": "clave-vieja-de-antes"])
        let nuevo = AlmacenEnMemoria(["apiKey.cerebras": Self.claveDePega])
        let d = sitioViejo(copiaEnClaro: "clave-vieja-de-antes")

        XCTAssertEqual(enClaro(d), "clave-vieja-de-antes", "el punto de partida, afirmado")

        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "cerebras", almacen: nuevo,
                                               viejo: viejo, defaults: d), .yaEstaba)

        XCTAssertEqual(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo),
                       Self.claveDePega, "la del almacén nuevo manda")
        XCTAssertNil(viejo.leer(cuenta: "apiKey.cerebras"))
        XCTAssertNil(enClaro(d))
    }

    /// Cuando los dos sitios viejos tienen algo distinto, se mueve **la que la app estaba usando
    /// de verdad**: `KeychainStore.get` prefería el llavero y solo caía a la copia en claro.
    func test_el_llavero_viejo_manda_sobre_la_copia_en_claro() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": "LA-DEL-LLAVERO"])
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo(copiaEnClaro: "LA-DE-LA-COPIA")

        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "cerebras", almacen: nuevo,
                                               viejo: viejo, defaults: d), .migrada)
        XCTAssertEqual(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo),
                       "LA-DEL-LLAVERO")
        XCTAssertNil(enClaro(d), "y la copia en claro se va igual")
    }

    func test_sin_nada_en_ningun_sitio_no_hay_nada_que_migrar() {
        let d = sitioViejo()
        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "gemini", almacen: AlmacenEnMemoria(),
                                               viejo: AlmacenEnMemoria(), defaults: d),
                       .noHabiaNada)
    }

    /// Una key en blanco en el sitio viejo no se guarda (un secreto fantasma haría creer al banner
    /// que hay key) **pero el sitio viejo se vacía igual**.
    func test_una_key_en_blanco_no_se_guarda_pero_el_sitio_viejo_se_vacia() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": "   "])
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo(copiaEnClaro: "  \n ")

        XCTAssertEqual(enClaro(d), "  \n ", "el punto de partida, afirmado")
        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "cerebras", almacen: nuevo,
                                               viejo: viejo, defaults: d), .noHabiaNada)
        XCTAssertNil(nuevo.leer(cuenta: "apiKey.cerebras"), "no se guarda una cadena en blanco")
        XCTAssertNil(viejo.leer(cuenta: "apiKey.cerebras"), "pero el sitio viejo se vacía")
        XCTAssertNil(enClaro(d))
    }

    func test_la_migracion_recorta_lo_que_mueve() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": "  \(Self.claveDePega)\n "])
        let nuevo = AlmacenEnMemoria()
        XCTAssertEqual(ClaveDeProveedor.migrar(proveedor: "cerebras", almacen: nuevo,
                                               viejo: viejo, defaults: sitioViejo()), .migrada)
        XCTAssertEqual(nuevo.leer(cuenta: "apiKey.cerebras"), Self.claveDePega)
    }

    func test_migrarTodas_devuelve_que_paso_con_cada_proveedor() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": Self.claveDePega,
                                      "apiKey.claude": "otra-de-pega"])
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo()

        let resultados = ClaveDeProveedor.migrarTodas(almacen: nuevo, viejo: viejo, defaults: d)

        XCTAssertEqual(resultados["cerebras"], .migrada)
        XCTAssertEqual(resultados["claude"], .migrada)
        XCTAssertEqual(resultados["gemini"], .noHabiaNada)
        XCTAssertEqual(resultados["local"], .noHabiaNada)
        XCTAssertEqual(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo),
                       Self.claveDePega)
        XCTAssertEqual(ClaveDeProveedor.leer(proveedor: "claude", almacen: nuevo), "otra-de-pega")
        XCTAssertNil(viejo.leer(cuenta: "apiKey.cerebras"))
        XCTAssertNil(viejo.leer(cuenta: "apiKey.claude"))
    }

    // MARK: guardar y leer

    func test_guardar_no_escribe_la_copia_en_claro_y_borra_la_que_hubiera() {
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo(copiaEnClaro: "clave-en-claro-de-antes")

        XCTAssertEqual(enClaro(d), "clave-en-claro-de-antes", "el punto de partida, afirmado")
        XCTAssertTrue(ClaveDeProveedor.guardar(Self.claveDePega, proveedor: "cerebras",
                                               almacen: nuevo, defaults: d))
        XCTAssertEqual(nuevo.leer(cuenta: "apiKey.cerebras"), Self.claveDePega)
        XCTAssertNil(enClaro(d), "y la copia en claro no se reescribe: se va")
    }

    func test_guardar_recorta_y_una_key_vacia_borra_el_secreto() {
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo()
        ClaveDeProveedor.guardar("  \(Self.claveDePega) ", proveedor: "groq", almacen: nuevo, defaults: d)
        XCTAssertEqual(nuevo.leer(cuenta: "apiKey.groq"), Self.claveDePega)
        ClaveDeProveedor.guardar("   ", proveedor: "groq", almacen: nuevo, defaults: d)
        XCTAssertNil(nuevo.leer(cuenta: "apiKey.groq"),
                     "una key vacía borra el elemento en vez de guardar una cadena vacía")
    }

    func test_un_almacen_que_rechaza_la_escritura_lo_dice() {
        let nuevo = AlmacenEnMemoria()
        nuevo.rechazaEscrituras = true
        XCTAssertFalse(ClaveDeProveedor.guardar(Self.claveDePega, proveedor: "cerebras",
                                                almacen: nuevo, defaults: sitioViejo()))
    }

    /// Leer no migra ni borra: la misma regla medida en las Tareas 6 y 6b. Una corrida de la suite
    /// no puede mover las keys de verdad del usuario a un almacén de pega.
    func test_leer_no_migra_ni_borra_nada() {
        let viejo = AlmacenEnMemoria(["apiKey.cerebras": Self.claveDePega])
        let nuevo = AlmacenEnMemoria()
        let d = sitioViejo(copiaEnClaro: Self.claveDePega)

        XCTAssertNil(ClaveDeProveedor.leer(proveedor: "cerebras", almacen: nuevo))

        XCTAssertEqual(viejo.leer(cuenta: "apiKey.cerebras"), Self.claveDePega,
                       "leer no movió el elemento viejo")
        XCTAssertEqual(enClaro(d), Self.claveDePega, "ni borró la copia en claro")
        XCTAssertNil(nuevo.leer(cuenta: "apiKey.cerebras"), "ni escribió en el almacén nuevo")
    }

    // MARK: los SEIS lectores y el escritor

    /// La búsqueda por la que pasan tres de los cinco lectores de `HarnessModel`.
    func test_los_lectores_del_modelo_toman_la_clave_del_almacen_que_reciben() {
        let buscar = HarnessModel.clavesDelAlmacen(AlmacenEnMemoria(["apiKey.cerebras": Self.claveDePega]))
        XCTAssertEqual(buscar(.cerebras), Self.claveDePega)
        XCTAssertNil(buscar(.groq), "cada proveedor tiene su cuenta, y no se pisan")
        XCTAssertNil(HarnessModel.clavesDelAlmacen(AlmacenEnMemoria())(.cerebras),
                     "sin nada en el almacén no hay key")
    }

    /// El banner «Falta la API Key» mira el almacén nuevo. Con el almacén sembrado tiene que
    /// decir que no falta, y vacío que sí: si siguiera mirando el llavero viejo, el primer
    /// arranque tras la actualización le pintaría al usuario que le falta la key que sí tiene.
    func test_el_banner_de_falta_api_key_mira_el_almacen_que_recibe_el_modelo() {
        let conClave = HarnessModel(almacen: AlmacenEnMemoria())
        let kind = conClave.currentProviderKind
        guard !kind.isLocalMLX, !conClave.chatUsesLocalServer else {
            // El proveedor de chat guardado es local (en iOS lo es por omisión): el banner no
            // aplica y la aserción de abajo no mediría nada. Se afirma lo que SÍ es cierto.
            XCTAssertFalse(conClave.isMissingApiKey,
                           "con proveedor local no se puede echar en falta una API key")
            return
        }
        XCTAssertTrue(conClave.isMissingApiKey, "almacén vacío ⇒ falta la key")
        let sembrado = HarnessModel(almacen: AlmacenEnMemoria(["apiKey.\(kind.rawValue)": Self.claveDePega]))
        XCTAssertFalse(sembrado.isMissingApiKey, "almacén sembrado ⇒ no falta la key")
    }

    /// El escritor de Ajustes, el sexto lector (el marcador de posición del campo) y la migración
    /// del arranque, **fijados en el fuente**.
    ///
    /// No es un adorno: el cuerpo de un `View` de SwiftUI no se ejecuta en esta suite, y el
    /// `KeychainStore.shared.set` que había era **el defecto** (escribía la copia en claro).
    /// Volver a ponerlo deshace la tarea entera sin que ninguna prueba de comportamiento se
    /// entere. Y si la migración se cae de `GemmaApp`, el usuario se queda con las keys en el
    /// llavero viejo para siempre.
    func test_ajustes_y_el_arranque_pasan_por_el_almacen_nuevo() throws {
        let ajustes = try fuente("Gemma/Settings/SettingsView.swift")
        // Guarda de vacuidad: que la ruta apunte al fichero de verdad. Las aserciones de ausencia
        // pasarían solas con el fichero vacío o la ruta mal.
        XCTAssertTrue(ajustes.contains("private struct ProviderPicker: View {"),
                      "la ruta de Ajustes ya no apunta al fichero de producción")
        XCTAssertTrue(ajustes.contains("ClaveDeProveedor.guardar(k, proveedor: kind.rawValue)"),
                      "Ajustes ya no guarda la API key en el llavero del dispositivo")
        XCTAssertTrue(ajustes.contains("ClaveDeProveedor.leer(proveedor: kind.rawValue)"),
                      "el campo de Ajustes ya no mira el almacén nuevo para saber si hay key")
        XCTAssertFalse(ajustes.contains("KeychainStore"),
                       "Ajustes volvió al almacén viejo, que escribe una copia EN CLARO")

        let modelo = try fuente("Gemma/Harness/HarnessModel.swift")
        XCTAssertTrue(modelo.contains("nonisolated static func clavesDelAlmacen("),
                      "la ruta del modelo ya no apunta al fichero de producción")
        XCTAssertFalse(modelo.contains("KeychainStore"),
                       "un lector del modelo volvió al almacén viejo")
        XCTAssertFalse(modelo.contains("\"apiKey."),
                       "el modelo vuelve a construir la cuenta a mano en vez de usar `ClaveDeProveedor`")

        // 🔴 EL LLAVERO GLOBAL, SOLO COMO VALOR POR OMISIÓN DE UN PARÁMETRO. Tres de los cinco
        // lectores (`init`, `rebuildRuntime`, `runAgentTurn`) y el de la consolidación
        // (`pushConsolidationConfig`) no tienen prueba de comportamiento: `runtime` es privado y
        // el push necesita un servicio de memoria. Si uno de ellos se saltara el almacén
        // inyectado y fuera al llavero global, una corrida de la suite leería la entrada de
        // PRODUCCIÓN —donde están las API keys de pago del usuario— y nadie se enteraría. Esta
        // regla lo cierra sin enumerar los sitios: el global solo puede aparecer detrás de un
        // `=`.
        var lineasConElGlobal = 0
        // Sin comentarios: la prosa nombra el llavero para explicarlo, y la regla es sobre código.
        let codigoDelModelo = modelo.split(separator: "\n", omittingEmptySubsequences: false)
            .map { linea -> String in
                guard let corte = linea.range(of: "//") else { return String(linea) }
                return String(linea[linea.startIndex..<corte.lowerBound])
            }
        for linea in codigoDelModelo where linea.contains("LlaveroDelSistema") {
            lineasConElGlobal += 1
            XCTAssertTrue(linea.contains("= LlaveroDelSistema.compartido"),
                          """
                          el llavero global se usa como ARGUMENTO y no como valor por omisión, \
                          así que ese camino ignora el almacén inyectado: \
                          \(linea.trimmingCharacters(in: .whitespaces))
                          """)
        }
        XCTAssertGreaterThanOrEqual(lineasConElGlobal, 3,
                                    "guarda de vacuidad: la regla no ha mirado ninguna línea")

        let arranque = try fuente("Gemma/GemmaApp.swift")
        let migracion = try XCTUnwrap(arranque.range(of: "ClaveDeProveedor.migrarTodas()"),
                                      "el arranque ya no migra las API keys")
        let construccion = try XCTUnwrap(arranque.range(of: "return HarnessModel()"))
        XCTAssertLessThan(migracion.lowerBound, construccion.lowerBound,
                          """
                          la migración de las API keys corre DESPUÉS de construir el \
                          `HarnessModel`, y su `init` ya lee la key: el primer arranque tras la \
                          actualización arrancaría sin key y con el banner puesto.
                          """)
    }

    // MARK: que no se filtre, medido en los textos que de verdad se renderizan

    /// Un fallo de transporte **de verdad** con una API key puesta, y los tres textos que este
    /// proyecto compone con el error: el de pantalla, el que ve el modelo, y el volcado crudo.
    ///
    /// Guardas de vacuidad: los tres tienen que tener longitud. «No contiene la key» se cumple en
    /// una cadena vacía.
    func test_ningun_texto_de_error_lleva_la_api_key() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FalloDeTransporteDeProveedor.self]
        let proveedor = ModelProvider(kind: .cerebras, apiKey: Self.claveDePega)
        let rt = ServerRuntime(provider: proveedor, session: URLSession(configuration: cfg))

        var capturado: Error?
        do {
            for try await _ in await rt.generate(prompt: "hola", tools: [],
                                                 options: GenerationOptions()) {}
        } catch { capturado = error }
        let error = try XCTUnwrap(capturado, "el transporte tenía que fallar")

        let textos = [error.localizedDescription,
                      "No se pudo hablar con el proveedor: \(error.localizedDescription)",
                      "\(error)"]
        for texto in textos {
            XCTAssertGreaterThan(texto.count, 15, "guarda de vacuidad: el texto está vacío")
            XCTAssertFalse(texto.contains(Self.claveDePega),
                           "la API key de pago del usuario sale en un texto de error: \(texto)")
        }
    }

    /// El 401, que es lo que el usuario va a ver cuando una key caduque, y el aviso de key
    /// ausente, que es el otro texto que esta app compone sobre la key.
    func test_el_mensaje_de_un_401_y_el_de_key_ausente_no_llevan_la_api_key() async {
        let proveedor = ModelProvider(kind: .cerebras, apiKey: Self.claveDePega)
        let mensaje = ServerRuntime.errorMessage(status: 401, provider: proveedor)
        XCTAssertTrue(mensaje.contains("API key"), "guarda de vacuidad: \(mensaje)")
        XCTAssertFalse(mensaje.contains(Self.claveDePega), mensaje)

        let rt = ServerRuntime(provider: ModelProvider(kind: .cerebras, apiKey: ""),
                              session: .shared)
        var capturado: Error?
        do {
            for try await _ in await rt.generate(prompt: "hola", tools: [],
                                                 options: GenerationOptions()) {}
        } catch { capturado = error }
        let texto = "\(capturado.map { "\($0)" } ?? "")"
        XCTAssertTrue(texto.contains("API key"), "guarda de vacuidad: \(texto)")
        XCTAssertFalse(texto.contains(Self.claveDePega))
    }

    // MARK: lista BLANCA de identificadores

    /// LISTA BLANCA de los identificadores de los dos ficheros por los que pasa la API key, no
    /// lista negra.
    ///
    /// Por qué blanca: medido en este proyecto el 2026-11-09, una lista negra de ocho palabras
    /// dejaba pasar **verdes** seis fugas reales, entre ellas `UserDefaults.standard.set` y el
    /// `userInfo` de `NotificationCenter`. Una negra solo prueba que no está lo que se te ocurrió
    /// nombrar.
    ///
    /// POR QUÉ ESTA LISTA ES PROPIA Y NO LA MISMA DE `TokenDeConducirTests`. La Tarea 6b unió los
    /// dos ficheros de los tokens en una sola lista con un argumento bueno: pasan por la misma
    /// lógica y dos listas serían dos sitios donde relajar la regla. Aquí el argumento se invierte
    /// y gana lo contrario: `LlaveroViejoDeApiKeys` **tiene que** nombrar
    /// `kSecAttrAccessibleAfterFirstUnlock` y **no** nombrar `kSecUseDataProtectionKeychain` —es
    /// el camino viejo, con los atributos flojos, por definición—. Meterlo en la lista de los
    /// tokens le añadiría esos permisos, y entonces alguien podría degradar la clase del token del
    /// navegador sin que la lista se quejara. Dos caminos con garantías distintas, dos listas.
    func test_los_ficheros_de_la_api_key_solo_usan_identificadores_permitidos() throws {
        let nuevo = try fuente("Gemma/Settings/ClaveDeProveedor.swift")
        let viejo = try fuente("Gemma/Settings/LlaveroViejoDeApiKeys.swift")

        // Guarda de vacuidad 1: que las rutas apunten a los ficheros de verdad.
        for ancla in ["enum ClaveDeProveedor {", "static func migrar(proveedor: String,",
                      "enum Resultado: String, Equatable, Sendable {"] {
            XCTAssertTrue(nuevo.contains(ancla), "la ruta del fuente nuevo ya no vale: \(ancla)")
        }
        for ancla in ["public struct LlaveroViejoDeApiKeys: AlmacenSoloDeLectura {",
                      "public static let servicioDeLasApiKeys"] {
            XCTAssertTrue(viejo.contains(ancla), "la ruta del fuente viejo ya no vale: \(ancla)")
        }

        let usados = TokenDeConducirTests.identificadoresDe(fuente: nuevo)
            .union(TokenDeConducirTests.identificadoresDe(fuente: viejo))

        // Guarda de vacuidad 2: que el troceado haya extraído algo reconocible. Sin esto, un
        // fallo del troceado daría el conjunto vacío, que cabe en cualquier lista blanca.
        XCTAssertTrue(usados.contains("ClaveDeProveedor"),
                      "el troceado no funciona: no encuentra ni `ClaveDeProveedor`")
        XCTAssertTrue(usados.contains("migrar"), "el troceado no encuentra ni `migrar`")
        XCTAssertGreaterThan(usados.count, 90,
                             "el troceado devolvió \(usados.count): no ha leído los ficheros")

        let deMas = usados.subtracting(Self.identificadoresPermitidos).sorted()
        XCTAssertEqual(deMas, [],
                       """
                       el camino de la API key usa identificadores que no están en la lista \
                       blanca: \(deMas). Si son legítimos, añádelos A MANO y mira dos veces que \
                       ninguno registra, notifica, imprime ni persiste en claro: por aquí pasan \
                       las API keys de pago del usuario, y una de ellas es la del proveedor de \
                       chat por omisión.
                       """)
    }

    /// Los identificadores que los dos ficheros pueden contener, y ni uno más. No hay en esta
    /// lista ni `print`, ni `Logger`, ni `os_log`, ni `NSLog`, ni `PanelLog`, ni
    /// `NotificationCenter`, ni `append`, ni `localizedDescription`, ni `description`, ni `URL`,
    /// ni `set` (el escritor de `UserDefaults`; sí está `removeObject`, que es el que la tarea
    /// necesita), ni `kSecValueData`/`SecItemAdd` en el camino viejo (no sabe escribir).
    private static let identificadoresPermitidos: Set<String> = [
        // los tipos y las importaciones
        "AlmacenDeSecretos", "AlmacenSoloDeLectura", "Any", "Bool", "CFDictionary", "CFTypeRef",
        "ClaveDeProveedor", "Data", "Equatable", "Foundation", "Kind", "LlaveroDelSistema",
        "LlaveroViejoDeApiKeys", "ModelProvider", "Resultado", "Security", "Sendable", "String",
        "UserDefaults",
        // palabras clave de Swift, atributos y miembros del lenguaje
        "_", "any", "as", "case", "discardableResult", "else", "enum", "for", "func", "guard",
        "if", "import", "in", "init", "let", "nil", "private", "public", "return", "self",
        "static", "struct", "true", "var",
        // la API del llavero que el camino viejo necesita para LEER y BORRAR, y nada más
        "SecItemCopyMatching", "SecItemDelete", "errSecSuccess", "kSecAttrAccessible",
        "kSecAttrAccessibleAfterFirstUnlock", "kSecAttrAccount", "kSecAttrService", "kSecClass",
        "kSecClassGenericPassword", "kSecMatchLimit", "kSecMatchLimitOne", "kSecReturnData",
        // la API pública del almacén y de la clave
        "allCases", "almacen", "borrar", "clave", "claveEnClaro", "compartido", "cuenta",
        "escribir", "guardar", "leer", "migrar", "migrarTodas", "proveedor", "proveedores",
        "rawValue", "servicio", "servicioDeLasApiKeys", "todosLosProveedores", "valor", "viejo",
        // los casos del resultado
        "falloLaEscritura", "migrada", "noHabiaNada", "noSeLeyoDeVuelta", "yaEstaba",
        // Foundation, solo lectura, recorte y BORRADO: `set` no está en la lista
        "defaults", "encoding", "forKey", "isEmpty", "map", "removeObject", "standard", "string",
        "trimmingCharacters", "utf8", "whitespacesAndNewlines",
        // los nombres locales
        "aceptado", "bruto", "consulta", "data", "datos", "deLaCopiaEnClaro", "delLlaveroViejo",
        "enClaro", "limpio", "nombre", "resultados", "salida", "texto",
        // los trozos de las dos cadenas literales que son nombres: la cuenta de cada proveedor,
        // la clave de la copia en claro y el servicio del llavero viejo
        "apiKey", "apiKeys", "keychain_fallback", "lambert", "dev", "group", "Gemma",
    ]

    // MARK: el llavero de verdad — medido, no heredado

    /// 🔴 QUE EL CAMINO VIEJO ENCUENTRE LO QUE EL CÓDIGO VIEJO ESCRIBIÓ.
    ///
    /// Si la consulta de `LlaveroViejoDeApiKeys` se desvía de la que usaba `KeychainStore`, la
    /// migración no encuentra nada, devuelve `noHabiaNada` y **no dice nada**: la key del usuario
    /// se queda en el sitio viejo con el informe en verde. Por eso aquí el elemento se planta con
    /// la consulta del código viejo escrita a mano —copiada de `KeychainStore.set` tal como estaba
    /// en `a557131`, el commit anterior a esta tarea— y se lee con el tipo de producción.
    ///
    /// Sobre un servicio PROPIO de las pruebas y borrado al terminar. **Nunca el de producción:**
    /// el usuario tiene dos API keys de pago ahí dentro.
    func test_el_camino_viejo_encuentra_lo_que_el_codigo_viejo_escribio() throws {
        let servicio = "pruebas.Gemma.apiKeysViejas.\(UUID().uuidString)"
        let cuenta = "apiKey.deMentira"
        let viejo = LlaveroViejoDeApiKeys(servicio: servicio)
        addTeardownBlock { viejo.borrar(cuenta: cuenta) }

        // VERBATIM `KeychainStore.query` + la mitad de llavero de `KeychainStore.set`.
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: cuenta,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(consulta as CFDictionary)
        var aAnadir = consulta
        aAnadir[kSecValueData as String] = Data(Self.claveDePega.utf8)
        try XCTSkipUnless(SecItemAdd(aAnadir as CFDictionary, nil) == errSecSuccess,
                          "el llavero de ficheros rechazó la escritura (firma del binario de "
                          + "pruebas); la lógica de la migración se mide con el doble en memoria")

        XCTAssertEqual(viejo.leer(cuenta: cuenta), Self.claveDePega,
                       """
                       el camino viejo NO encuentra lo que el código viejo escribió. Con esto \
                       roto, la migración diría «no había nada» y las API keys del usuario se \
                       quedarían en el llavero de ficheros, sin clase de accesibilidad.
                       """)
        viejo.borrar(cuenta: cuenta)
        XCTAssertNil(viejo.leer(cuenta: cuenta), "y lo sabe vaciar, que es la otra mitad")
    }

    /// 🔴 LA CLASE SE AFIRMA LEYENDO EL `pdmn` DEL ELEMENTO **GUARDADO**, no el código que lo
    /// guarda, y en las dos plataformas.
    ///
    /// Es exactamente lo que cazó el defecto de la Tarea 6: `SecItemAdd` devolvía `errSecSuccess`
    /// **ignorando** la clase pedida. Aquí se mide el camino nuevo de la API key —escribiendo por
    /// `ClaveDeProveedor.guardar`, no por el llavero a pelo— y, en la misma prueba, **el camino
    /// viejo**, que es la medición que justifica la tarea entera: el elemento del llavero de
    /// ficheros se guarda **sin clase ninguna**.
    func test_la_clase_del_elemento_guardado_por_el_camino_nuevo_es_la_del_dispositivo_solo() throws {
        let servicio = "pruebas.Gemma.claveDeProveedor.\(UUID().uuidString)"
        let nuevo = LlaveroDelSistema(servicio: servicio)
        let cuenta = ClaveDeProveedor.cuenta("deMentira")
        addTeardownBlock { nuevo.borrar(cuenta: cuenta) }

        try XCTSkipUnless(ClaveDeProveedor.guardar(Self.claveDePega, proveedor: "deMentira",
                                                   almacen: nuevo, defaults: sitioViejo()),
                          "el llavero rechazó la escritura (firma del binario de pruebas)")

        var consulta: [String: Any] = [
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
            la API key se guardó SIN clase de accesibilidad. Es el defecto que esta prueba existe \
            para cazar: en macOS, sin `kSecUseDataProtectionKeychain`, el llavero de ficheros \
            ignora `kSecAttrAccessible` y `SecItemAdd` devuelve éxito igual.
            """)
        let soloEsteDispositivo = [
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String,
        ]
        XCTAssertTrue(soloEsteDispositivo.contains(aplicada),
                      """
                      la clase \(aplicada) no es de la familia `ThisDeviceOnly`: la API key de \
                      pago entraría en las copias de seguridad y se restauraría en otro aparato.
                      """)
        XCTAssertEqual(aplicada, LlaveroDelSistema.claseDeAccesibilidad as String)
        XCTAssertNotEqual(atributos[kSecAttrSynchronizable as String] as? Bool, true,
                          "y no puede ser sincronizable")

        // Y el camino VIEJO, en la misma corrida: el elemento del llavero de ficheros no tiene
        // clase. Es la medición que justifica la migración, y aquí queda fijada, no citada.
        let servicioViejo = "pruebas.Gemma.apiKeysViejas.\(UUID().uuidString)"
        let plantado: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicioViejo,
            kSecAttrAccount as String: cuenta,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data("da-igual".utf8),
        ]
        addTeardownBlock { SecItemDelete(plantado as CFDictionary) }
        try XCTSkipUnless(SecItemAdd(plantado as CFDictionary, nil) == errSecSuccess,
                          "el llavero de ficheros rechazó la escritura")
        consulta[kSecAttrService as String] = servicioViejo
        consulta[kSecUseDataProtectionKeychain as String] = false
        consulta.removeValue(forKey: kSecAttrSynchronizable as String)
        var salidaVieja: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(consulta as CFDictionary, &salidaVieja), errSecSuccess)
        let atributosViejos = try XCTUnwrap(salidaVieja as? [String: Any])
        XCTAssertNil(atributosViejos[kSecAttrAccessible as String],
                     """
                     el llavero de ficheros SÍ aplicó una clase de accesibilidad. Si eso cambiara, \
                     el motivo por el que esta migración existe habría cambiado con él y habría \
                     que volver a medirlo todo.
                     """)
    }

    // MARK: ayudante de fuentes

    private func fuente(_ relativo: String) throws -> String {
        let aqui = URL(fileURLWithPath: #filePath)
        let fichero = aqui.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativo)
        return try String(contentsOf: fichero, encoding: .utf8)
    }
}
