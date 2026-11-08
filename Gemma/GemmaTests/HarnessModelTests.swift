import XCTest
@testable import Gemma

/// Smoke tests for the `MemoryClient` settings contract used by `HarnessModel.ensureMemory()`:
/// the harness reads `memoryBaseURL` + `memoryBearerToken` from `UserDefaults` (defaults
/// `http://localhost:8081` + "") and constructs a client with them. Constructing the full
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
        defaults.set("", forKey: "memoryBearerToken")

        XCTAssertNil(HarnessModel.memorySettings(defaults: defaults),
                     "URL vacía debe dejar la app sin memoria, no inventar un servidor")
        XCTAssertEqual(defaults.string(forKey: "memoryBaseURL"), "",
                       "leer los ajustes NO puede reescribirlos: eso es lo que impedía borrar el campo")
        XCTAssertEqual(defaults.string(forKey: "memoryBearerToken"), "",
                       "el token vacío tiene que quedarse vacío; meterle el placeholder lo resucitaba solo")
    }

    func test_memorySettings_tokenVacioDevuelveClienteParaQueElServidorDe401() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set("http://100.91.174.81:8081", forKey: "memoryBaseURL")
        defaults.set("", forKey: "memoryBearerToken")

        let ajustes = HarnessModel.memorySettings(defaults: defaults)
        XCTAssertEqual(ajustes?.url.absoluteString, "http://100.91.174.81:8081")
        XCTAssertEqual(ajustes?.token, "", "un 401 visible es mejor que un token inventado")
    }

    func test_memorySettings_recortaEspacios() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set("  http://100.91.174.81:8081  ", forKey: "memoryBaseURL")
        defaults.set("  secreto  ", forKey: "memoryBearerToken")

        let ajustes = HarnessModel.memorySettings(defaults: defaults)
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
            XCTAssertNil(HarnessModel.memorySettings(defaults: defaults), "debería rechazar: \(basura)")
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
