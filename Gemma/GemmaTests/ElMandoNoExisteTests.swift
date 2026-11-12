import XCTest

/// **EL MANDO NO EXISTE.** El panel del navegador del i3 solo MIRA: el usuario ve el stream pero no
/// puede conducirlo (ni con clics, ni con teclas, ni con toques). Esta prueba es la red que impide
/// que el control manual vuelva a colarse, ni como código ni como documentación.
///
/// POR QUÉ LEE EL FUENTE CRUDO, COMENTARIOS INCLUIDOS (y no el troceado de `TroceadoDeFuente`):
/// es una prueba de AUSENCIA, y en una ausencia lo peligroso es que el troceado se trague una
/// línea y el término pase en verde. Además queremos que tampoco vuelva la *doc* del mando: un
/// comentario que habla de un volante que no existe es una mentira que el siguiente lector se
/// cree. Un comentario con un término prohibido pone la prueba roja: ruido visible, el lado seguro.
///
/// POR QUÉ NO SE PROHÍBE LA PALABRA SUELTA «mando»: en español significa también «te mando un
/// abrazo» (`SmartMessageDrafter`). Se prohíben los símbolos y términos concretos del control
/// manual; la lista de abajo se midió contra el árbol y no tiene falsos positivos.
///
/// CONTROL CONTRA UNA RED QUE LEE OTRA CARPETA: antes de afirmar ninguna ausencia se afirma que
/// se leyeron al menos 100 ficheros (había 163 al escribirla) y que están dos que tienen que
/// estar. Sin eso, una ruta equivocada daría «ningún fichero lo nombra» en verde por vacuidad.
final class ElMandoNoExisteTests: XCTestCase {

    /// `Gemma/Gemma/`, localizada desde este fichero (`Gemma/GemmaTests/`).
    private var raiz: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma")
    }

    /// Todos los `.swift` bajo `raiz`, como (ruta relativa, texto crudo).
    private func ficheros(base: URL? = nil) throws -> [(ruta: String, texto: String)] {
        let base = (base ?? raiz).standardizedFileURL
        let fm = FileManager.default
        let it = try XCTUnwrap(fm.enumerator(at: base, includingPropertiesForKeys: nil),
                               "no se pudo enumerar \(base.path)")
        var salida: [(String, String)] = []
        for caso in it {
            guard let url = caso as? URL, url.pathExtension == "swift" else { continue }
            let ruta = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
            salida.append((ruta, try String(contentsOf: url, encoding: .utf8)))
        }
        return salida
    }

    private func fuente(_ ruta: String) throws -> String {
        try XCTUnwrap(try ficheros().first { $0.ruta == ruta }?.texto, "no existe \(ruta)")
    }

    /// Los términos propios del control manual. Ninguno es una palabra común del español.
    private static let terminosProhibidos = [
        "MandoDelNavegador", "BrowserMando", "BrowserInputEvents", "BrowserInputMapper",
        "QuienConduce", "quienConduce", "tomaElMando", "devuelveElMando", "manda(entrada",
        "mando_tomar", "mando_devolver", "input_mouse", "input_keyboard", "input_touch",
        "pulsacionesEnviadas", "DimensionesDelCable", "viewport_width", "volante",
    ]

    func test_ningun_fuente_de_la_app_nombra_el_mando() throws {
        let todos = try ficheros()
        // Control de la red: sin esto, una ruta equivocada pasaría en verde.
        XCTAssertGreaterThanOrEqual(todos.count, 100, "se leyeron muy pocos ficheros: ¿ruta equivocada (\(raiz.path))?")
        let rutas = Set(todos.map(\.ruta))
        XCTAssertTrue(rutas.contains("Harness/BrowserPanelView.swift"), "falta BrowserPanelView.swift en lo leído")
        XCTAssertTrue(rutas.contains("NativeServices/BrowserRelayClient.swift"), "falta BrowserRelayClient.swift en lo leído")

        for muerto in ["Harness/BrowserMando.swift", "Harness/BrowserInputEvents.swift", "Harness/BrowserInputMapper.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: raiz.appendingPathComponent(muerto).path),
                           "\(muerto) existe: el mando ha vuelto")
        }

        for (ruta, texto) in todos {
            for termino in Self.terminosProhibidos where texto.contains(termino) {
                XCTFail("\(ruta) contiene «\(termino)»: el control manual no existe, ni siquiera como comentario")
            }
        }
    }

    func test_el_panel_no_tiene_gestos_ni_campos() throws {
        let panel = try fuente("Harness/BrowserPanelView.swift")
        for termino in ["Gesture", "onKeyPress", "TextField", "SecureField", ".focused(", "onTapGesture"] {
            XCTAssertFalse(panel.contains(termino), "BrowserPanelView.swift contiene «\(termino)»: el panel solo mira")
        }
    }

    func test_el_visor_solo_manda_acuses() throws {
        let cliente = try fuente("NativeServices/BrowserRelayClient.swift")
        let envios = cliente.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains(".envia(") && !$0.contains("func envia") }
        XCTAssertEqual(envios.count, 1, "el visor debe enviar por UN solo sitio (el acuse); hay: \(envios)")
        XCTAssertTrue(envios.first?.contains("ackPayload") == true,
                      "lo único que el visor envía es el acuse (`ackPayload`): \(envios)")
    }
}
