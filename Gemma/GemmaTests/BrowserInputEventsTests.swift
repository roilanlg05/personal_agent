import XCTest
@testable import Gemma

// SIN `#if os(macOS)`: estas pruebas corren en macOS **y en iOS**, y el motivo es el que
// `BrowserCrossPlatformTests` escribe en su cabecera — **el cliente real del usuario es su
// iPhone**. La producción de todo el stack del mando no tiene una sola puerta de plataforma
// (`BrowserMando.swift`, `BrowserPanelView.swift`, `BrowserPanelState.swift` y
// `BrowserPanelCoordinator.swift` no contienen ningún `#if`, y `AgentChatView` monta el panel
// sin condición), así que el `SecureField`, el `DragGesture` y el mapa del toque **sí existen en
// el teléfono**; lo que no existía allí eran sus pruebas. Medido antes de quitar la puerta: iOS
// ejecutaba **0** casos de este fichero. Nada de lo que mide depende de la plataforma —es
// aritmética pura, cadenas y lectura del fuente— así que la puerta no tenía ningún motivo
// escrito y era una costumbre heredada, no una decisión.

/// Los codificadores de la entrada del usuario cuando toma el volante del navegador.
///
/// QUÉ SE ESTÁ CLAVANDO, Y POR QUÉ NADIE MÁS LO CLAVA. El relé
/// (`gemma-memory/browser/relay.py:678-684`) reenvía al demonio el mensaje del visor
/// **verbatim** y valida **solo el `type`**, a propósito, para no acoplarse al protocolo de
/// entrada del demonio. Nadie más valida los campos: un campo mal nombrado lo descarta el
/// demonio sin error visible, y el síntoma que ve el usuario es «toco y no pasa nada»,
/// indistinguible de media docena de fallos distintos. Estas pruebas son la única cosa en todo
/// el camino que comprueba la forma del mensaje.
///
/// Los valores esperados NO se inventaron: salen de la referencia de streaming que trae el CLI
/// instalado, version-matched (0.41.2), y la medición completa con la fuente de cada campo está
/// en `docs/superpowers/notes/2026-11-09-protocolo-de-entrada-del-demonio.md`:
///
///     streaming.md:75  {"type": "input_mouse", "eventType": "mousePressed", "x": 40, "y": 40, "button": "left", "clickCount": 1}
///     streaming.md:76  {"type": "input_keyboard", "eventType": "keyDown", "key": "a", "text": "a"}
///     streaming.md:77  {"type": "input_touch", "eventType": "touchStart", "touchPoints": []}
///
/// Se comparan los JSON **byte a byte** y eso es seguro aquí: `ToolJSONOutput` ordena las claves
/// desde `dd9059c`, así que la salida es determinista. Y es irrelevante para el demonio, porque
/// el relé reserializa el objeto antes de reenviarlo (`relay.py:915`, `json.dumps(message)`): al
/// demonio le llega el JSON de Python, no el nuestro. Lo único que viaja es el conjunto de
/// claves y sus valores, que es justo lo que estas pruebas fijan.
final class BrowserInputEventsTests: XCTestCase {

    // MARK: el fuente, para las pruebas que afirman una ausencia

    /// El fuente de producción, leído del disco. Dos pruebas afirman una AUSENCIA (que no hay
    /// registro, y que no hay más tipos que los tres permitidos), y una ausencia no se puede
    /// observar ejecutando código: se lee el fuente, igual que
    /// `AgentBrowserRegistrationTests.test_run_agent_turn_calls_registerBrowserTools` clava su
    /// llamada. Frágil ante renombrados a propósito.
    private func fuenteDeProduccion() throws -> String {
        let aqui = URL(fileURLWithPath: #filePath)
        let fichero = aqui.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/Harness/BrowserInputEvents.swift")
        return try String(contentsOf: fichero, encoding: .utf8)
    }

    // MARK: los tres mensajes

    func test_el_raton_produce_el_json_que_documenta_la_medicion() {
        XCTAssertEqual(
            BrowserInputEvents.mouse(tipo: .pulsado, x: 40, y: 40, boton: .izquierdo),
            #"{"button":"left","clickCount":1,"eventType":"mousePressed","type":"input_mouse","x":40,"y":40}"#)

        // Los otros dos eventos de ratón y los otros dos botones, con sus nombres del protocolo.
        XCTAssertEqual(
            BrowserInputEvents.mouse(tipo: .soltado, x: 7, y: 9, boton: .derecho),
            #"{"button":"right","clickCount":1,"eventType":"mouseReleased","type":"input_mouse","x":7,"y":9}"#)
        XCTAssertEqual(
            BrowserInputEvents.mouse(tipo: .movido, x: 0, y: 1080, boton: .central, pulsaciones: 0),
            #"{"button":"middle","clickCount":0,"eventType":"mouseMoved","type":"input_mouse","x":0,"y":1080}"#)
    }

    func test_el_teclado_produce_el_json_que_documenta_la_medicion() {
        // Una tecla cualquiera: la contraseña del usuario viaja por aquí, así que esta prueba
        // usa una letra que no es ningún secreto de nadie.
        XCTAssertEqual(
            BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a", texto: "a"),
            #"{"eventType":"keyDown","key":"a","text":"a","type":"input_keyboard"}"#)
        // Una tecla sin texto (Enter, Tab, las flechas) manda `text` VACÍO y no lo omite: el
        // ejemplo publicado lleva siempre los cuatro campos y el código no depende de ningún
        // valor por omisión del demonio, que no se pudo medir.
        XCTAssertEqual(
            BrowserInputEvents.keyboard(tipo: .arriba, tecla: "Enter", texto: ""),
            #"{"eventType":"keyUp","key":"Enter","text":"","type":"input_keyboard"}"#)
    }

    func test_el_tactil_produce_el_json_que_documenta_la_medicion() {
        XCTAssertEqual(
            BrowserInputEvents.touch(tipo: .inicio, x: 40, y: 40),
            #"{"eventType":"touchStart","touchPoints":[{"x":40,"y":40}],"type":"input_touch"}"#)
        XCTAssertEqual(
            BrowserInputEvents.touch(tipo: .movimiento, x: 120, y: 300),
            #"{"eventType":"touchMove","touchPoints":[{"x":120,"y":300}],"type":"input_touch"}"#)
    }

    /// La única rama del fichero donde el `eventType` cambia la FORMA del mensaje: en `touchEnd`
    /// no queda ningún punto activo, así que la lista va vacía (`Input.dispatchTouchEvent`).
    /// Afirmar solo que `touchStart` lleva su punto no probaría esto: la rama podría no existir
    /// y `touchEnd` mandaría un punto que ya no existe.
    func test_el_fin_del_toque_no_lleva_ningun_punto() {
        XCTAssertEqual(
            BrowserInputEvents.touch(tipo: .fin, x: 120, y: 300),
            #"{"eventType":"touchEnd","touchPoints":[],"type":"input_touch"}"#)
    }

    // MARK: el `type` es uno de los tres, y no hay más

    /// Los tres `type` son exactamente los de `_ENTRADAS_REENVIABLES` (`relay.py:633`).
    /// Se decodifica en vez de buscar la subcadena: así se comprueba que el valor está en la
    /// clave `type` y no en cualquier otro sitio del mensaje.
    func test_los_tres_tipos_son_los_tres_permitidos_por_el_rele() throws {
        let permitidos: Set<String> = ["input_mouse", "input_keyboard", "input_touch"]
        let mensajes = [
            BrowserInputEvents.mouse(tipo: .pulsado, x: 1, y: 2, boton: .izquierdo),
            BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a", texto: "a"),
            BrowserInputEvents.touch(tipo: .inicio, x: 1, y: 2),
        ]
        var vistos: Set<String> = []
        for mensaje in mensajes {
            let datos = try XCTUnwrap(mensaje.data(using: .utf8))
            let objeto = try XCTUnwrap(try JSONSerialization.jsonObject(with: datos) as? [String: Any])
            let tipo = try XCTUnwrap(objeto["type"] as? String)
            XCTAssertTrue(permitidos.contains(tipo), "tipo no reenviable: \(tipo)")
            vistos.insert(tipo)
        }
        // Que los tres sean distintos: con una sola función copiada tres veces, los tres
        // mensajes podrían llevar el mismo `type` y las tres aserciones de arriba pasarían.
        XCTAssertEqual(vistos, permitidos)
    }

    /// Y no se puede construir ningún otro: el fichero no menciona ningún `input_*` más.
    /// Abrir la lista de permitidos del relé por necesidad es lo que el spec prohíbe con nombre
    /// y apellidos, y la forma de que no pase por descuido es que el cliente no sepa escribir
    /// otro tipo. No hay parámetro de tipo en ninguna de las tres firmas; esto cubre el resto.
    func test_el_fichero_no_menciona_ningun_otro_tipo_de_entrada() throws {
        let fuente = try fuenteDeProduccion()
        let codigo = TroceadoDeFuente.sinComentarios(fuente)
        // Guarda de vacuidad: si el fichero estuviera vacío, o esta ruta no apuntara a nada
        // útil, la aserción de abajo pasaría sola. Primero se comprueba que es el fichero real.
        // **Sobre el fuente troceado**: es una PRESENCIA, y sobre el crudo se cumple con la
        // declaración envuelta en `/* */` —característica borrada, texto conservado—, que es la
        // clase medida en verde exacto en esta rama (N2).
        XCTAssertTrue(codigo.contains("enum BrowserInputEvents"), "la ruta del fuente ya no apunta al fichero de producción")

        func tiposEn(_ texto: String) throws -> Set<String> {
            let regex = try NSRegularExpression(pattern: "input_[a-z_]+")
            let rango = NSRange(texto.startIndex..., in: texto)
            return Set(regex.matches(in: texto, range: rango).compactMap { coincidencia -> String? in
                Range(coincidencia.range, in: texto).map { String(texto[$0]) }
            })
        }
        // LAS DOS DIRECCIONES, Y NO SOBRAN. Sobre el **código** (troceado): que los tres tipos
        // existan de verdad y no haya un cuarto escrito en código —si esto fuera solo sobre el
        // crudo, los tres se podrían haber borrado y quedarse nombrados en un comentario, y la
        // igualdad seguiría pasando—. Y sobre el **crudo**: que no haya un cuarto en ninguna
        // parte, ni en la prosa, que es el lado seguro de una ausencia (si el troceado se
        // tragara la línea de un `input_scroll`, la ausencia sobre el troceado pasaría en verde).
        XCTAssertEqual(try tiposEn(codigo), ["input_mouse", "input_keyboard", "input_touch"])
        XCTAssertEqual(try tiposEn(fuente), ["input_mouse", "input_keyboard", "input_touch"])
    }

    // MARK: el tope del relé

    /// `MAX_MENSAJE_VISOR = 4096` (`relay.py:641`), comparado con `>` (`relay.py:655`): la
    /// frontera es INCLUSIVA, y la prueba del servidor la clava en 4095/4096 pasan, 4097 no
    /// (`browser/test_app.py:1981-1990`). Lo que pasa el tope se descarta EN SILENCIO, así que
    /// un mensaje demasiado grande desaparece sin error: la comprobación es del cliente.
    func test_una_tecla_normal_cabe_y_un_texto_largo_no() {
        let tecla = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a", texto: "a")
        XCTAssertTrue(BrowserInputEvents.cabeEnElTope(tecla))
        // Y cabe de sobra, no por los pelos: un evento legítimo son decenas de bytes.
        XCTAssertLessThan(tecla.utf8.count, 100)

        // Un pegado largo: el relé lo descartaría, así que `cabeEnElTope` tiene que decir que no
        // ANTES de mandarlo. Quien quiera pegar algo largo lo parte en varios `input_keyboard`.
        let largo = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a", texto: String(repeating: "k", count: 5000))
        XCTAssertFalse(BrowserInputEvents.cabeEnElTope(largo))
    }

    /// La frontera exacta, en los dos lados. Sin esto, `cabeEnElTope` podría estar comparando
    /// con 4095, con 4097 o con cualquier número de ese orden y las dos pruebas de arriba
    /// seguirían pasando.
    func test_la_frontera_del_tope_esta_en_4096_bytes_inclusive() {
        func deLongitud(_ n: Int) -> String {
            let vacio = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a", texto: "")
            return BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a",
                                               texto: String(repeating: "k", count: n - vacio.utf8.count))
        }
        XCTAssertEqual(deLongitud(4096).utf8.count, 4096)
        XCTAssertTrue(BrowserInputEvents.cabeEnElTope(deLongitud(4095)))
        XCTAssertTrue(BrowserInputEvents.cabeEnElTope(deLongitud(4096)))
        XCTAssertFalse(BrowserInputEvents.cabeEnElTope(deLongitud(4097)))
    }

    /// El tope se mide en BYTES UTF-8, no en caracteres de Swift. `String.count` cuenta
    /// grafemas: `"é"` compuesta es 1 grafema, 2 escalares y 3 bytes. Con un contador de
    /// grafemas, este mensaje «cabría» y el relé lo tiraría.
    ///
    /// (El relé cuenta puntos de código, no bytes — `len()` de un `str` de Python,
    /// `relay.py:655`. Bytes es más estricto: en UTF-8 `bytes ≥ puntos de código`, así que
    /// `cabeEnElTope` nunca dice que sí sobre algo que el relé descarte. El razonamiento
    /// completo está en la nota de la medición.)
    func test_el_tope_cuenta_bytes_y_no_grafemas() {
        // "é" descompuesta: 3 bytes, 2 escalares, 1 grafema.
        let acento = "e\u{0301}"
        XCTAssertEqual(acento.count, 1)
        XCTAssertEqual(acento.utf8.count, 3)

        let mensaje = BrowserInputEvents.keyboard(tipo: .abajo, tecla: "a",
                                                  texto: String(repeating: acento, count: 1500))
        XCTAssertLessThan(mensaje.count, 4096, "el caso no distingue nada si también sobra en grafemas")
        XCTAssertGreaterThan(mensaje.utf8.count, 4096)
        XCTAssertFalse(BrowserInputEvents.cabeEnElTope(mensaje))
    }

    // MARK: la restricción que no se negocia

    /// LA TECLA NO SE REGISTRA, NUNCA. Ni en `PanelLog`, ni en un `print`, ni en un `Logger`, ni
    /// en una descripción de excepción. Vale también para los valores intermedios: una cadena
    /// que contiene la tecla no viaja a ninguna función que registre.
    ///
    /// Se afirma leyendo el fuente porque es la única forma de observar una ausencia, y porque
    /// todo el camino del panel de esta app ya está instrumentado con `PanelLog`: es la
    /// restricción más fácil de romper por accidente. Frágil a propósito: si alguien añade un
    /// registro «solo para depurar», esta prueba se pone roja y dice por qué.
    func test_ninguna_funcion_del_fichero_registra_nada() throws {
        let fuente = try fuenteDeProduccion()
        // Guarda de vacuidad, igual que arriba: la aserción de abajo es una AUSENCIA y pasaría
        // sola si el fichero estuviera vacío o la ruta estuviera mal. Primero, que sea el
        // fichero de verdad y que tenga dentro las tres funciones que manejan la tecla.
        // Los anclas, **sobre el fuente troceado**: son PRESENCIAS y sobre el crudo se cumplen
        // con las cuatro funciones comentadas. La lista de registradores de abajo se queda sobre
        // el **crudo** a propósito: es una AUSENCIA, y ahí el crudo es estrictamente más fuerte
        // —un `print(` escrito en un comentario pone esto rojo (ruido visible), mientras que
        // sobre el troceado una línea que el troceado se tragara pasaría en verde (silencio, que
        // es G1/N1, el bypass que costó cuatro rondas en esta rama).
        let codigo = TroceadoDeFuente.sinComentarios(fuente)
        for ancla in ["enum BrowserInputEvents", "func mouse", "func keyboard", "func touch", "func cabeEnElTope"] {
            XCTAssertTrue(codigo.contains(ancla), "la ruta del fuente ya no apunta al fichero de producción: falta \(ancla)")
        }
        for registro in ["PanelLog", "print(", "NSLog", "os_log", "Logger", "OSLog", "FileHandle", "debugPrint"] {
            XCTAssertFalse(fuente.contains(registro),
                           "el codificador de entrada no puede registrar nada: la tecla puede ser una contraseña (\(registro))")
        }
    }
}
