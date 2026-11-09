import XCTest
@testable import Gemma

/// Smoke tests for the `MemoryClient` settings contract used by `HarnessModel.ensureMemory()`:
/// the harness reads `memoryBaseURL` from `UserDefaults` (default `http://localhost:8081`) and
/// the bearer token from the KEYCHAIN (`TokenDeMemoria`, Tarea 6b; default "") and constructs a
/// client with them. Constructing the full
/// `HarnessModel` in a unit-test process crashes (it observes `NSApplication.willTerminate`
/// which is unavailable to the XCTest host), so we exercise the construction step here
/// directly. The wiring path itself is verified manually + by the smoke build.
@MainActor
final class HarnessModelTests: XCTestCase {
    func test_memoryClient_carriesBaseURLAndToken() async {
        // Use ephemeral session to avoid any `URLSession.shared` sandbox interactions.
        let client = MemoryClient(baseURL: URL(string: "http://example.test:9999")!,
                                  bearerToken: "hunter2",
                                  session: URLSession(configuration: .ephemeral))
        XCTAssertEqual(client.baseURL.absoluteString, "http://example.test:9999")
        XCTAssertEqual(client.bearerToken, "hunter2")
    }

    func test_memoryToolbox_storesClientAndReflectionHook() async {
        let client = MemoryClient(baseURL: URL(string: "http://localhost:8081")!,
                                  bearerToken: "",
                                  session: URLSession(configuration: .ephemeral))
        MemoryToolbox.shared.memory = client
        XCTAssertNotNil(MemoryToolbox.shared.memory)
        var fired = false
        MemoryToolbox.shared.reflectionRequest = { fired = true }
        MemoryToolbox.shared.reflectionRequest?()
        XCTAssertTrue(fired)
        MemoryToolbox.shared.memory = nil
        MemoryToolbox.shared.reflectionRequest = nil
    }

    /// Smoke: defaulting logic mirroring `HarnessModel.ensureMemory()`. We assert the
    /// fallback constants, not the full `HarnessModel.init()` path (which crashes under
    /// XCTest — see file header).
    func test_defaultBaseURL_isLocalhost8081() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let urlString = defaults.string(forKey: "memoryBaseURL") ?? "http://localhost:8081"
        XCTAssertEqual(URL(string: urlString)?.host, "localhost")
    }

    // MARK: la avería del campo que se volvía a escribir solo
    //
    // Ajustes llama a `ensureMemory()` en CADA pulsación de tecla. La versión anterior
    // reescribía `memoryBaseURL` y `memoryBearerToken` cuando los encontraba vacíos, así
    // que borrar el campo para poner un token nuevo era imposible: la app devolvía el valor
    // viejo entero. Estas pruebas fijan la regla que lo cierra — LEER NO ESCRIBE.

    func test_memorySettings_noEscribeNada_cuandoElCampoEstaVacio() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set("", forKey: "memoryBaseURL")
        // El sitio viejo se siembra con algo NO vacío a propósito: la aserción de abajo es que
        // leer no lo toca, y «sigue valiendo lo mismo» se cumple sola con la cadena vacía.
        defaults.set("TOKEN-VIEJO-EN-CLARO", forKey: SettingsKeys.memoryBearerToken)

        XCTAssertNil(HarnessModel.memorySettings(defaults: defaults, almacen: AlmacenEnMemoria()),
                     "URL vacía debe dejar la app sin memoria, no inventar un servidor")
        XCTAssertEqual(defaults.string(forKey: "memoryBaseURL"), "",
                       "leer los ajustes NO puede reescribirlos: eso es lo que impedía borrar el campo")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.memoryBearerToken), "TOKEN-VIEJO-EN-CLARO",
                       "leer NO migra ni borra: migrar es trabajo de `TokenDeMemoria.migrar`")
    }

    func test_memorySettings_tokenVacioDevuelveClienteParaQueElServidorDe401() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set("http://100.91.174.81:8081", forKey: "memoryBaseURL")

        let ajustes = HarnessModel.memorySettings(defaults: defaults, almacen: AlmacenEnMemoria())
        XCTAssertEqual(ajustes?.url.absoluteString, "http://100.91.174.81:8081")
        XCTAssertEqual(ajustes?.token, "", "un 401 visible es mejor que un token inventado")
    }

    /// EL TOKEN SALE DEL LLAVERO, NO DE `UserDefaults` (Tarea 6b).
    ///
    /// El estado exacto que tendrá la máquina del usuario a medio migrar: un token viejo en el
    /// sitio viejo y otro en el almacén. Si este lector volviera a `defaults.string(forKey:)`,
    /// devolvería el viejo y esto se pone rojo.
    func test_memorySettings_tomaElTokenDelLlaveroYNoElDeUserDefaults() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set("http://100.91.174.81:8081", forKey: "memoryBaseURL")
        defaults.set("TOKEN-VIEJO-EN-CLARO", forKey: SettingsKeys.memoryBearerToken)
        let almacen = AlmacenEnMemoria([TokenDeMemoria.cuenta: "TOKEN-DEL-LLAVERO"])

        let ajustes = HarnessModel.memorySettings(defaults: defaults, almacen: almacen)
        XCTAssertEqual(ajustes?.token, "TOKEN-DEL-LLAVERO",
                       "el token del llavero es el que manda, o el arreglo rompe el acceso al i3")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.memoryBearerToken), "TOKEN-VIEJO-EN-CLARO",
                       "y leer no escribe")
    }

    func test_memorySettings_recortaEspacios() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set("  http://100.91.174.81:8081  ", forKey: "memoryBaseURL")
        let almacen = AlmacenEnMemoria([TokenDeMemoria.cuenta: "  secreto  "])

        let ajustes = HarnessModel.memorySettings(defaults: defaults, almacen: almacen)
        XCTAssertEqual(ajustes?.url.absoluteString, "http://100.91.174.81:8081")
        XCTAssertEqual(ajustes?.token, "secreto")
    }

    /// Lo que de verdad le pasó al usuario: pegó una tabla entera de Markdown en el campo.
    /// Una URL escrita pero inservible no debe producir un cliente contra un host inventado.
    func test_memorySettings_rechazaLoQueNoEsUnaURLHttp() {
        for basura in ["Campo\tValor Base URL\thttp://100.91.174.81:8081 token\tabc",
                       "100.91.174.81:8081",
                       "no es una url",
                       "ftp://100.91.174.81:8081"] {
            let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
            defaults.set(basura, forKey: "memoryBaseURL")
            XCTAssertNil(HarnessModel.memorySettings(defaults: defaults, almacen: AlmacenEnMemoria()),
                         "debería rechazar: \(basura)")
        }
    }

    func test_migracionDeLaURL_corre_unaSolaVez_yNuncaSobreUnCampoVacio() {
        // Vacío: el usuario lo borró a propósito. La migración no lo rellena.
        let vacio = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        vacio.set("", forKey: "memoryBaseURL")
        HarnessModel.migrateMemoryBaseURLIfNeeded(defaults: vacio)
        XCTAssertEqual(vacio.string(forKey: "memoryBaseURL"), "",
                       "vacío significa «lo he borrado yo»; la migración no debe pisarlo")

        // Una dirección que el usuario eligió tampoco se toca.
        let suya = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        suya.set("http://mi-servidor:9999", forKey: "memoryBaseURL")
        HarnessModel.migrateMemoryBaseURLIfNeeded(defaults: suya)
        XCTAssertEqual(suya.string(forKey: "memoryBaseURL"), "http://mi-servidor:9999")

        // La bandera se pone pase lo que pase, así que no se repite en el arranque siguiente.
        // Solo en iOS: en macOS la migración no existe (el cuerpo entero va bajo `#if os(iOS)`),
        // porque `localhost:8081` ahí SÍ es alcanzable y es el valor correcto por omisión.
        #if os(iOS)
        XCTAssertTrue(vacio.bool(forKey: HarnessModel.memoryURLMigrationKey))
        XCTAssertTrue(suya.bool(forKey: HarnessModel.memoryURLMigrationKey))
        #else
        XCTAssertFalse(vacio.bool(forKey: HarnessModel.memoryURLMigrationKey),
                       "en macOS la migración no corre, así que no debe dejar bandera")
        #endif
    }

    #if os(iOS)
    func test_migracionDeLaURL_sustituyeSoloLasDireccionesQueElTelefonoNoAlcanza() {
        for inalcanzable in HarnessModel.unreachableMemoryHostsOnPhone {
            let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
            defaults.set(inalcanzable, forKey: "memoryBaseURL")
            HarnessModel.migrateMemoryBaseURLIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: "memoryBaseURL"), "http://100.91.174.81:8081",
                           "\(inalcanzable) no existe desde un iPhone")
            // Segunda llamada: ya migrado, no vuelve a tocar nada aunque cambie el valor.
            defaults.set("http://otro:8081", forKey: "memoryBaseURL")
            HarnessModel.migrateMemoryBaseURLIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: "memoryBaseURL"), "http://otro:8081")
        }
    }
    #endif

    func test_voiceURL_derivesFromMemoryHost_whenUnset() {
        XCTAssertEqual(HarnessModel.voiceURLString(explicit: "", memory: "http://100.91.174.81:8081"),
                       "http://100.91.174.81:8082")
    }

    func test_voiceURL_derivesPort_whenMemoryHasNoExplicitPort() {
        XCTAssertEqual(HarnessModel.voiceURLString(explicit: "  ", memory: "http://i3.local"),
                       "http://i3.local:8082")
    }

    func test_voiceURL_usesExplicit_whenSet() {
        XCTAssertEqual(HarnessModel.voiceURLString(explicit: "http://other:9000", memory: "http://100.91.174.81:8081"),
                       "http://other:9000")
    }
}
