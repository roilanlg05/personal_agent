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
        "pulsacionesEnviadas", "DimensionesDelCable", "viewport_width", "viewport_height",
        "volante", "Volante", "BrowserInputEvent", "ReanudaUnaSolaVez", "enviaPorElCanal",
        "peticionSigueViva", "caducidadDeLaPeticion",
    ]

    /// Términos que `BrowserRelayClientTests` puede nombrar a propósito: esa prueba comprueba que
    /// un servidor VIEJO que sigue mandando `viewport_*` o mensajes del volante no rompe el visor.
    /// Es la única excepción, y es por fichero y por término, no por carpeta.
    private static let excepcionesEnPruebas: [String: Set<String>] = [
        "BrowserRelayClientTests.swift": ["viewport_width", "viewport_height", "volante"],
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

    /// Lo mismo sobre `Gemma/GemmaTests`: una prueba que nombra un símbolo del mando resucita su
    /// vocabulario (y suele indicar que el mando se está volviendo a probar). Se excluye este
    /// fichero, que tiene que escribir la lista, y las excepciones por término de arriba.
    func test_ninguna_prueba_nombra_el_mando() throws {
        let pruebas = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let todos = try ficheros(base: pruebas)
        XCTAssertGreaterThanOrEqual(todos.count, 100, "se leyeron muy pocas pruebas: ¿ruta equivocada (\(pruebas.path))?")
        XCTAssertTrue(todos.contains { $0.ruta == "BrowserRelayClientTests.swift" }, "falta BrowserRelayClientTests.swift en lo leído")
        for (ruta, texto) in todos where ruta != "ElMandoNoExisteTests.swift" {
            let permitidos = Self.excepcionesEnPruebas[ruta] ?? []
            for termino in Self.terminosProhibidos where !permitidos.contains(termino) && texto.contains(termino) {
                XCTFail("GemmaTests/\(ruta) contiene «\(termino)»: el control manual no existe, ni en las pruebas")
            }
        }
    }

    /// Todo lo que daría al usuario una forma de CONDUCIR desde el panel: gestos, teclado, foco,
    /// campos, botones, atajos y hover (el ratón que "apunta"). Medido el 2026-11-12: ninguno de
    /// estos términos aparece hoy en `BrowserPanelView.swift` ni en `BrowserPanelCoordinator.swift`,
    /// así que no hay excepciones (en particular, ningún `Button(` legítimo en esos dos ficheros).
    /// La sección del panel en `AgentChatView.swift` es una sola línea de montaje
    /// (`BrowserPanelView(state:)`) dentro de un fichero que SÍ tiene campos y botones del chat,
    /// así que no es separable y no se mide ahí; lo cubre el hecho de que la vista del panel es
    /// quien no puede recibir entrada.
    func test_el_panel_no_tiene_gestos_ni_campos() throws {
        let terminos = ["Gesture", "onKeyPress", "TextField", "SecureField", ".focused(", "onTapGesture",
                        "onHover", "onContinuousHover", "focusable", "FocusState", "onSubmit",
                        "keyboardShortcut", "Button("]
        for ruta in ["Harness/BrowserPanelView.swift", "Harness/BrowserPanelCoordinator.swift"] {
            let texto = try fuente(ruta)
            for termino in terminos {
                XCTAssertFalse(texto.contains(termino), "\(ruta) contiene «\(termino)»: el panel solo mira")
            }
        }
    }

    /// El visor solo envía el acuse, medido sobre el código SIN comentarios (`sinComentarios`, así
    /// que un `// ackPayload` no cuenta) y por SENTENCIA, no por línea: el texto se aplana a un
    /// espacio entre palabras, de modo que `envia(a); envia(b)` en una línea son dos envíos.
    ///
    /// Se excluye la implementación del protocolo (`extension URLSessionWebSocketTask`), que es el
    /// único sitio con `send(` y existe para llevar lo que el visor decida enviar. Fuera de ella:
    ///  - un único `envia(`, y es exactamente `envia(Self.ackPayload(seq: seq))`;
    ///  - ningún `send(`, `sendPing`, `dataTask`, `uploadTask`, `.upload(`, `.data(for`, `.bytes(`;
    ///  - `URLSession`, `URLRequest` y `webSocketTask(` aparecen una vez cada uno (la sesión que
    ///    se recibe, la petición del `GET` del socket y su apertura): un POST por URLSession
    ///    añadiría una aparición más.
    /// El comportamiento (que todo lo que sale por el socket es un acuse) lo mide
    /// `BrowserRelayClientTests.test_todo_lo_que_el_visor_envia_es_un_acuse`.
    func test_el_visor_solo_manda_acuses() throws {
        var codigo = TroceadoDeFuente.sinComentarios(try fuente("NativeServices/BrowserRelayClient.swift"))
        // Quitar la implementación del protocolo, con emparejado de llaves.
        let cabecera = try XCTUnwrap(codigo.range(of: "extension URLSessionWebSocketTask: SocketDelVisor {"),
                                     "falta la implementación del protocolo sobre URLSessionWebSocketTask")
        var profundidad = 0
        var fin = cabecera.upperBound
        profundidad = 1
        while profundidad > 0, fin < codigo.endIndex {
            if codigo[fin] == "{" { profundidad += 1 } else if codigo[fin] == "}" { profundidad -= 1 }
            fin = codigo.index(after: fin)
        }
        XCTAssertEqual(profundidad, 0, "llaves sin emparejar en la extensión del socket")
        codigo.removeSubrange(cabecera.lowerBound..<fin)
        let plano = codigo.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        func cuenta(_ aguja: String) -> Int { plano.components(separatedBy: aguja).count - 1 }
        /// Palabra completa: `URLSession` no debe casar con `URLSessionWebSocketTask`.
        func cuentaPalabra(_ palabra: String) -> Int {
            let patron = "\\b" + NSRegularExpression.escapedPattern(for: palabra) + "\\b"
            guard let re = try? NSRegularExpression(pattern: patron) else { return -1 }
            return re.numberOfMatches(in: plano, range: NSRange(plano.startIndex..., in: plano))
        }

        // La declaración del protocolo es `func envia(`; lo que se cuenta son las LLAMADAS.
        let llamadas = cuenta("envia(") - cuenta("func envia(")
        XCTAssertEqual(llamadas, 1, "el visor debe enviar por UN solo sitio (el acuse); llamadas a envia: \(llamadas)")
        XCTAssertEqual(cuenta("envia(Self.ackPayload(seq: seq))"), 1,
                       "lo único que el visor envía es exactamente `envia(Self.ackPayload(seq: seq))`")
        for prohibido in ["send(", "sendPing", "dataTask", "uploadTask", ".upload(", ".data(for", ".bytes("] {
            XCTAssertEqual(cuenta(prohibido), 0, "BrowserRelayClient contiene «\(prohibido)» fuera de la implementación del protocolo")
        }
        for unico in ["URLSession", "URLRequest"] {
            XCTAssertEqual(cuentaPalabra(unico), 1, "«\(unico)» debería aparecer una sola vez (abrir el socket); un envío por red lo añadiría")
        }
        XCTAssertEqual(cuenta("webSocketTask("), 1, "«webSocketTask(» debería aparecer una sola vez (abrir el socket)")
    }
}
