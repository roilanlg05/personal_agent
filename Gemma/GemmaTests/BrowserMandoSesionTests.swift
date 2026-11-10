import CoreGraphics
import XCTest
@testable import Gemma

/// El gesto en curso de un panel, y lo que pasa con él cuando el volante se pierde a mitad.
///
/// POR QUÉ ESTA PANTALLA EXISTE (ronda 6, hallazgos H3 y H4 de la revisión de rama). Hasta aquí
/// el gesto vivía dentro del cuerpo de `BrowserMandoGestos`, y eso tenía dos consecuencias que
/// le pasaban al usuario, no a las pruebas:
///
///   - **H3, EL BOTÓN HUNDIDO.** Retirar el panel a mitad de un gesto (otro mensaje al agente,
///     detener, el tope de inactividad) cerraba el socket sin mandar el `mouseReleased` del
///     `mousePressed` que ya había salido. El Chrome del i3 —con la sesión de Google del
///     usuario dentro, que es exactamente donde va a teclear su contraseña— se quedaba con el
///     botón izquierdo pulsado, y desde ahí todo lo que tocaran él o el agente arrastraba.
///   - **H4, LA CONTRASEÑA QUE NO SALE.** Un envío que fallaba se tiraba, y el `.closed` que baja
///     el rótulo llega después, por otra tarea: el usuario tecleaba su contraseña entera con el
///     panel diciendo «Conduces tú» y nada salía, sin un error.
///
/// Nada lo medía porque el cuerpo de un `View` no se ejecuta en esta suite. Con el gesto en
/// `BrowserMandoSesion`, que tiene el coordinador, las dos cosas se **ejecutan**: se abre el
/// gesto, se pierde el volante, y se mira lo que salió y en qué orden — la transición, no el
/// estado en reposo (una cola a `nil` no prueba que nadie la cerrara: `nil` es el valor por
/// omisión).
///
/// 🔴 PUERTA DE PLATAFORMA, CON EL MOTIVO DE `BrowserPanelViewTests`. `BrowserMandoSesion` es un
/// `@Observable @MainActor`, la misma forma que `BrowserPanelState` y `BrowserPanelCoordinator`,
/// y el host de pruebas de iOS **aborta** al instanciar esos dos (`Test crashed with signal
/// abrt`, medido y documentado allí; preexistente, con su diagnóstico encargado aparte). Correr
/// estas pruebas en iOS sin ese diagnóstico podría tumbar el host y marcar como fallidas pruebas
/// ajenas. Las pruebas puras de `encola` de abajo no instancian nada de eso y corren en las dos.
final class BrowserMandoSesionTests: XCTestCase {

    // MARK: las cifras, a mano (las mismas de `BrowserPanelViewTests`)

    private typealias Cable = BrowserInputMapper.DimensionesDelCable
    /// Viewport medido del demonio 1280×720 y JPEG de 1080×608; la vista mide lo que la imagen.
    private let cable = Cable(anchoDelViewport: 1280, altoDelViewport: 720)
    private let imagen = CGSize(width: 1080, height: 608)

    /// El centro de la vista (540, 304) es el centro de la página (640, 360):
    /// 540 × 1280/1080 = 640 y 304 × 720/608 = 360, exactos.
    private let centro = CGPoint(x: 540, y: 304)
    /// (270, 152) de la vista es (320, 180) de la página, exactos por la misma cuenta.
    private let cuarto = CGPoint(x: 270, y: 152)
    /// Fuera de la imagen: no se puede mapear.
    private let fuera = CGPoint(x: -500, y: -500)

    private let pulsadoEnElCentro =
        #"{"button":"left","clickCount":1,"eventType":"mousePressed","type":"input_mouse","x":640,"y":360}"#
    private let movidoAlCuarto =
        #"{"button":"left","clickCount":0,"eventType":"mouseMoved","type":"input_mouse","x":320,"y":180}"#
    private let soltadoEnElCuarto =
        #"{"button":"left","clickCount":1,"eventType":"mouseReleased","type":"input_mouse","x":320,"y":180}"#
    private let soltadoEnElCentro =
        #"{"button":"left","clickCount":1,"eventType":"mouseReleased","type":"input_mouse","x":640,"y":360}"#

    // MARK: H4 — un envío que falla se dice (puras: corren en las dos plataformas)

    /// **UN ENVÍO QUE NO SALE CORTA EL LOTE Y LO DICE.** El ciclo entero sobre un socket caído: el
    /// primer mensaje se intenta (si no se intentara, «no salió el resto» pasaría con una cola
    /// que no manda nada), falla, se avisa UNA vez, y el resto no se intenta.
    @MainActor func test_un_envio_que_falla_corta_el_lote_y_lo_dice() async {
        let caido = MandoDeMentira(salida: false)
        let fallos = Contador()
        let cola = BrowserMandoEnvio.encola(["1", "2", "3"], por: caido, tras: nil,
                                            espera: { _ in }, alFallar: { fallos.suma() })
        await cola?.value
        XCTAssertEqual(caido.entradas, ["1"], "el primero se intenta y el resto no: sin canal fallaría igual")
        XCTAssertEqual(fallos.valor, 1, "el fallo tiene que decirse, y una sola vez por lote")

        // Y el control: con el socket sano no se avisa de nada y sale todo.
        let sano = MandoDeMentira()
        let sinFallos = Contador()
        let otra = BrowserMandoEnvio.encola(["1", "2", "3"], por: sano, tras: nil,
                                            espera: { _ in }, alFallar: { sinFallos.suma() })
        await otra?.value
        XCTAssertEqual(sano.entradas, ["1", "2", "3"])
        XCTAssertEqual(sinFallos.valor, 0, "con todo saliendo, avisar sería mentir")
    }

    /// El aviso de lo que no salió va por el camino de `avisoDeApuntado`, **gana** al de
    /// apuntado, y sale **conduzca quien conduzca**: el `.closed` que pone el rótulo en
    /// «conduce el agente» llega justo después del fallo, y si el aviso exigiera `.yo` se iría
    /// en el mismo instante en que tiene algo que decir.
    func test_el_aviso_de_lo_que_no_salio_sale_conduzca_quien_conduzca() {
        for quien in [QuienConduce.yo, .agente, .otroVisor] {
            for apuntable in [true, false] {
                XCTAssertEqual(BrowserPanelView.avisoDeApuntado(quienConduce: quien, sePuedeApuntar: apuntable,
                                                                entradaPerdida: true),
                               BrowserPanelView.textoDeEntradaPerdida,
                               "con \(quien) y apuntable=\(apuntable) el aviso de lo que no salió no se ve")
            }
        }
        XCTAssertEqual(BrowserPanelView.textoDeEntradaPerdida,
                       "Lo último que escribiste o tocaste NO llegó al navegador. Vuelve a tomar el volante y repítelo.",
                       "la frase completa: dice qué pasó y qué hacer, y nada de lo escrito")
    }

    #if os(macOS)

    // MARK: H4 — el ciclo entero, sobre la sesión

    /// Lo que no salió se anota en la sesión —que es lo que la barra lee— y se apaga cuando el
    /// servidor vuelve a conceder el volante. Se mide la transición: falso antes, verdadero tras
    /// el fallo, falso tras el olvido.
    @MainActor func test_lo_que_no_sale_queda_anotado_en_la_sesion_hasta_el_volante_siguiente() async {
        let sesion = BrowserMandoSesion(mando: MandoDeMentira(salida: false))
        XCTAssertFalse(sesion.entradaPerdida, "antes de mandar nada no hay nada perdido")

        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        let anotado = await esperaHasta { sesion.entradaPerdida }
        XCTAssertTrue(anotado, "el envío falló y la sesión no lo anotó: el usuario no se enteraría")

        sesion.olvidaElFallo()
        XCTAssertFalse(sesion.entradaPerdida)
        XCTAssertNil(BrowserPanelView.avisoDeApuntado(quienConduce: .yo, sePuedeApuntar: true,
                                                      entradaPerdida: sesion.entradaPerdida),
                     "con el volante nuevo el aviso viejo se va")
    }

    // MARK: H3 — el botón hundido

    /// **RETIRAR EL PANEL A MITAD DE GESTO MANDA EL SOLTAR, Y LO MANDA ANTES DE CERRAR EL SOCKET.**
    ///
    /// Por el camino de producción entero: el coordinador abre el panel con su mando, el usuario
    /// pulsa en el centro, y el turno se retira (`endTurn(survive: false)`, que es detener o un
    /// fallo; el tope de inactividad y el turno siguiente pasan por el mismo `retire`). El
    /// instante en que el socket se cierra es el `onTermination` del flujo, y ahí se fotografía
    /// lo que había salido: el relé solo acepta entrada del portador, y el portador ES el
    /// socket, así que lo que salga después no llega a la página.
    @MainActor func test_retirar_el_panel_a_mitad_de_gesto_suelta_el_boton_antes_de_cerrar_el_socket() async throws {
        let mando = MandoDeMentira()
        let alCerrar = Foto()
        let c = BrowserPanelCoordinator(stream: {
            (AsyncStream { cont in cont.onTermination = { _ in alCerrar.toma(mando.entradas) } }, mando)
        })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        let sesion = try XCTUnwrap(c.sesion(de: id), "el coordinador no entrega la sesión del panel que abrió")

        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable),
                      "el toque en el centro tiene que mandar el `mousePressed`; sin esto el resto pasaría sin gesto")

        c.endTurn(survive: false, porque: "la prueba del botón hundido")
        let cerrado = await esperaHasta { alCerrar.tomada }
        XCTAssertTrue(cerrado, "el socket del panel retirado no se cerró nunca")
        XCTAssertEqual(alCerrar.foto, [pulsadoEnElCentro, soltadoEnElCentro],
                       "al cerrar el socket el botón seguía hundido en la página: falta el "
                       + "`mouseReleased`, o salió DESPUÉS del cierre y el relé no lo aceptaría")
        XCTAssertNil(c.sesion(de: id), "el panel retirado se queda con su sesión, y con ella el cliente del relé")
    }

    /// Y sin gesto abierto no se manda nada, y el socket se cierra **en el acto**, como antes de
    /// esta ronda: el soltar defensivo es para el gesto abierto, no un mensaje de cortesía.
    @MainActor func test_retirar_el_panel_sin_gesto_abierto_no_manda_nada() async throws {
        let mando = MandoDeMentira()
        let alCerrar = Foto()
        let c = BrowserPanelCoordinator(stream: {
            (AsyncStream { cont in cont.onTermination = { _ in alCerrar.toma(mando.entradas) } }, mando)
        })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        let sesion = try XCTUnwrap(c.sesion(de: id))
        // Un clic entero, que termina por su pie: el gesto queda CERRADO antes de retirar.
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        sesion.levanta(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable)

        c.endTurn(survive: false, porque: "la prueba sin gesto abierto")
        let cerrado = await esperaHasta { alCerrar.tomada }
        XCTAssertTrue(cerrado)
        XCTAssertEqual(mando.entradas, [pulsadoEnElCentro, soltadoEnElCentro],
                       "un gesto ya cerrado no lleva un segundo soltar: sería un `mouseReleased` huérfano")
    }

    /// **EL SOLTAR VA DETRÁS DE LO QUE YA ESTÁ EN LA COLA.** Con el `mousePressed` colgado en el
    /// envío, un soltar que no esperara a la cola saldría **antes** que su pulsar, y el botón
    /// se quedaría hundido igual. Y el soltar cae en el **último punto bueno** —el del arrastre,
    /// no el de la pulsación—, que es la excepción deliberada del `.suelta`.
    @MainActor func test_el_soltar_defensivo_va_detras_de_la_cola_y_en_el_ultimo_punto_bueno() async {
        let puerta = PrimeraEnLaPuerta()
        let mando = MandoDeMentira(antesDeMandar: { await puerta.pasa() })
        let sesion = BrowserMandoSesion(mando: mando)
        let t0 = ContinuousClock.Instant.now

        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                                  dimensionesDelCable: cable, ahora: t0))
        XCTAssertTrue(sesion.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                                  dimensionesDelCable: cable, ahora: t0.advanced(by: .seconds(1))))
        // El dedo sale de la imagen: no se manda, y el último punto bueno sigue siendo el cuarto.
        XCTAssertFalse(sesion.toca(punto: fuera, vista: imagen, tamañoDeLaImagen: imagen,
                                   dimensionesDelCable: cable, ahora: t0.advanced(by: .seconds(2))))

        let colgado = await puerta.esperaQueAlguienEntre()
        XCTAssertTrue(colgado, "el `mousePressed` no llegó a la puerta: la prueba no mediría el orden")

        let enVuelo = sesion.retira()
        XCTAssertNotNil(enVuelo, "con un gesto abierto y mensajes en vuelo, retirar tiene que devolver la cola")
        puerta.abre()
        let salio = await esperaHasta { mando.entradas.count >= 3 }
        XCTAssertTrue(salio, "la cola no se vació")
        XCTAssertEqual(mando.entradas, [pulsadoEnElCentro, movidoAlCuarto, soltadoEnElCuarto],
                       "el soltar defensivo adelantó a la cola, o no cayó en el último punto bueno")

        // Y la sesión queda CERRADA: un `.onEnded` tardío, o cualquier toque, ya no manda nada.
        sesion.levanta(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable)
        _ = sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable)
        XCTAssertNil(sesion.retira(), "tras retirarla, la sesión sigue teniendo algo en vuelo")
        for _ in 0..<1_000 { await Task.yield() }
        XCTAssertEqual(mando.entradas.count, 3, "una sesión retirada siguió mandando")
    }

    /// **PERDER EL VOLANTE POR OTRO CAMINO CIERRA EL GESTO, SIN MANDAR NADA.** Por un `.closed` o
    /// por un `mando` del servidor el soltar no llegaría (sin canal, o el relé descarta lo que no
    /// es del portador), pero el gesto sí tiene que cerrarse aquí: si no, el primer toque tras
    /// recuperar el volante se clasificaba como `.mueve` —un `mouseMoved` sin `mousePressed`— y
    /// **ningún clic funcionaba**.
    @MainActor func test_perder_el_volante_por_otro_camino_cierra_el_gesto_sin_mandar_nada() async {
        let mando = MandoDeMentira()
        let sesion = BrowserMandoSesion(mando: mando)
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        let primero = await esperaHasta { mando.entradas.count == 1 }
        XCTAssertTrue(primero)

        sesion.olvidaElGesto()
        // Lo único que queda en vuelo es el `mousePressed` que ya salió: si `retira` añadiera un
        // soltar, el gesto no se habría olvidado.
        await sesion.retira()?.value
        XCTAssertEqual(mando.entradas, [pulsadoEnElCentro],
                       "olvidar el gesto mandó algo, o lo dejó abierto para un soltar posterior")

        let otra = BrowserMandoSesion(mando: mando)
        XCTAssertTrue(otra.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        otra.olvidaElGesto()
        XCTAssertTrue(otra.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        let tres = await esperaHasta { mando.entradas.count == 3 }
        XCTAssertTrue(tres)
        XCTAssertEqual(mando.entradas.last,
                       #"{"button":"left","clickCount":1,"eventType":"mousePressed","type":"input_mouse","x":320,"y":180}"#,
                       "el primer toque tras perder el volante no fue un clic: el gesto viejo seguía abierto")
    }

    // MARK: el anillo: de dónde sale su punto, ejecutado (antes era forma del texto)

    /// `toca` dice «salió un mensaje» exactamente cuando salió uno, que es lo único que el anillo
    /// puede marcar:
    ///
    ///   - **M4**: un `.mueve` fuera de la imagen conserva la página vieja con CERO mensajes; si
    ///     `toca` mirara `pagina` y no `mensajes`, diría que sí.
    ///   - **M5**: una muestra que el muestreo descarta no se manda; si la decisión se tomara
    ///     antes de la puerta del muestreo, diría que sí.
    @MainActor func test_la_sesion_solo_marca_el_anillo_cuando_sale_un_mensaje() async {
        let mando = MandoDeMentira()
        let sesion = BrowserMandoSesion(mando: mando)
        let t0 = ContinuousClock.Instant.now
        let i = BrowserMandoEntrada.intervaloDeMuestreo

        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                                  dimensionesDelCable: cable, ahora: t0),
                      "la pulsación sale siempre: sin este acierto el resto pasaría con `false` constante")
        XCTAssertFalse(sesion.toca(punto: fuera, vista: imagen, tamañoDeLaImagen: imagen,
                                   dimensionesDelCable: cable, ahora: t0.advanced(by: i)),
                       "M4: fuera de la imagen no sale nada, aunque la página vieja se conserve")
        XCTAssertFalse(sesion.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                                   dimensionesDelCable: cable, ahora: t0.advanced(by: i + i / 2)),
                       "M5: dentro del intervalo el muestreo descarta la muestra, así que no sale nada")
        XCTAssertTrue(sesion.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                                  dimensionesDelCable: cable, ahora: t0.advanced(by: i * 3)))
        let dos = await esperaHasta { mando.entradas.count == 2 }
        XCTAssertTrue(dos, "salieron \(mando.entradas.count) mensajes y tenían que ser dos")
    }

    #endif

    // MARK: utilidades

    /// Espera a que `condicion` se cumpla, **acotada**: devuelve si se cumplió, y la prueba lo
    /// afirma. Una espera sin tope convirtió en este proyecto un fallo en un cuelgue de 23
    /// minutos, y un cuelgue no es un rojo: no dice qué propiedad se rompió.
    @MainActor private func esperaHasta(vueltas: Int = 100_000, _ condicion: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<vueltas {
            if condicion() { return true }
            await Task.yield()
        }
        return condicion()
    }

    private final class Contador: @unchecked Sendable {
        private let candado = NSLock()
        private var _valor = 0
        var valor: Int { candado.withLock { _valor } }
        func suma() { candado.withLock { _valor += 1 } }
    }

    /// Lo que había salido en el instante en que se cerró el socket.
    private final class Foto: @unchecked Sendable {
        private let candado = NSLock()
        private var _foto: [String]?
        var tomada: Bool { candado.withLock { _foto != nil } }
        var foto: [String]? { candado.withLock { _foto } }
        func toma(_ entradas: [String]) { candado.withLock { if _foto == nil { _foto = entradas } } }
    }

    /// Cuelga el PRIMER envío hasta que la prueba abre; los demás pasan.
    private final class PrimeraEnLaPuerta: @unchecked Sendable {
        private let candado = NSLock()
        private var abierta = false
        private var entraron = 0

        func abre() { candado.withLock { abierta = true } }

        func pasa() async {
            let soyLaPrimera = candado.withLock { () -> Bool in entraron += 1; return entraron == 1 }
            guard soyLaPrimera else { return }
            for _ in 0..<1_000_000 {
                if candado.withLock({ abierta }) { return }
                await Task.yield()
            }
        }

        /// Acotada, por lo mismo que `esperaHasta`.
        func esperaQueAlguienEntre(vueltas: Int = 100_000) async -> Bool {
            for _ in 0..<vueltas {
                if candado.withLock({ entraron }) > 0 { return true }
                await Task.yield()
            }
            return false
        }
    }
}
