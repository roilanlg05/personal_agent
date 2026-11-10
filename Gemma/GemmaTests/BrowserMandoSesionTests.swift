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
                       "Hay un problema con la entrada o el volante. Comprueba la página, vuelve a tomar el volante y repite lo que falte.",
                       "la frase completa: dice qué pasó y qué hacer, y nada de lo escrito")
    }

    /// El primer fallo corta su lote; el lote posterior sigue intentando salir.
    /// Invalida durante el reparto que separa down y up: el up debe salir,
    /// pero no el siguiente down. Mide la salida completa, no solo un contador vacío.
    @MainActor func test_la_generacion_solo_corta_entre_pares_de_teclado() async {
        let mando = MandoDeMentira()
        let corte = Contador()
        let terminado = Contador()
        let mensajes = BrowserMandoEntrada.mensajesDeTeclado(anterior: "", nuevo: "ab")
        let cola = BrowserMandoEnvio.encola(mensajes, por: mando, tras: nil,
            vigente: { corte.valor == 0 }, enPares: true,
            espera: { _ in corte.suma() }, alFallar: { XCTFail("el envío no debía fallar") })
        Task { await cola?.value; terminado.suma() }
        let fin = await esperaHastaPorReloj(.seconds(2)) { terminado.valor == 1 }
        XCTAssertTrue(fin)
        XCTAssertEqual(mando.entradas, Array(mensajes.prefix(2)))
    }

    @MainActor func test_un_lote_fallido_no_cancela_el_lote_posterior() async {
        let mando = MandoDeMentira(salida: false)
        let fallos = Contador()
        let primera = BrowserMandoEnvio.encola(["a", "b"], por: mando, tras: nil,
                                              espera: { _ in }, alFallar: { fallos.suma() })
        _ = BrowserMandoEnvio.encola(["c", "d"], por: mando, tras: primera,
                                    espera: { _ in }, alFallar: { fallos.suma() })
        let drenado = await esperaHastaPorReloj(.seconds(2)) { fallos.valor == 2 }
        XCTAssertTrue(drenado)
        XCTAssertEqual(mando.entradas, ["a", "c"])
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
        // EL `mousePressed` SE QUEDA COLGADO EN EL ENVÍO, y es lo que hace medible el orden. Sin
        // la puerta, todo sale en el mismo puñado de saltos del hilo principal y el cierre del
        // socket (que también es asíncrono: `onTermination` no corre en el `cancel()`) llegaba
        // detrás por suerte. MEDIDO: con el consumidor cancelado ANTES de esperar al soltar
        // (h3b de la ronda 6) la versión sin puerta de esta prueba seguía verde.
        let puerta = PrimeraEnLaPuerta()
        let mando = MandoDeMentira(antesDeMandar: { await puerta.pasa() })
        let alCerrar = Foto()
        let c = BrowserPanelCoordinator(stream: {
            (AsyncStream { cont in cont.onTermination = { _ in alCerrar.toma(mando.entradas) } }, mando)
        })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        let sesion = try XCTUnwrap(c.sesion(de: id), "el coordinador no entrega la sesión del panel que abrió")

        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable),
                      "el toque en el centro tiene que mandar el `mousePressed`; sin esto el resto pasaría sin gesto")
        let colgado = await puerta.esperaQueAlguienEntre()
        XCTAssertTrue(colgado, "el `mousePressed` no llegó al envío: la prueba no mediría el orden")

        c.endTurn(survive: false, porque: "la prueba del botón hundido")
        // Con el pulsar todavía en vuelo, el socket NO puede haberse cerrado: es la propiedad.
        for _ in 0..<1_000 { await Task.yield() }
        XCTAssertFalse(alCerrar.tomada,
                       "el socket se cerró con el `mousePressed` todavía en vuelo: el soltar no llegará nunca")
        puerta.abre()
        let cerrado = await esperaHasta { alCerrar.tomada }
        XCTAssertTrue(cerrado, "el socket del panel retirado no se cerró nunca")
        XCTAssertEqual(alCerrar.foto, [pulsadoEnElCentro, soltadoEnElCentro],
                       "al cerrar el socket el botón seguía hundido en la página: falta el "
                       + "`mouseReleased`, o salió DESPUÉS del cierre y el relé no lo aceptaría")
        XCTAssertNil(c.sesion(de: id), "el panel retirado se queda con su sesión, y con ella el cliente del relé")
    }

    /// **UN ENVÍO COLGADO NO RETIENE EL SOCKET MÁS QUE EL PLAZO** (N1 de la re-revisión de la
    /// ronda 6). La espera de `retire` tenía un tope escrito y no tenía tope de verdad: con un
    /// envío que no vuelve, el socket del panel retirado se quedaba abierto, el relé seguía
    /// viendo al usuario como portador y **el agente recibía 409 en cada herramienta**.
    ///
    /// Se mide con el plazo **de producción** (`plazoParaLoQueQuedaEnVuelo`), no con uno
    /// inyectado: una prueba con su propio plazo dejaría vivo cualquier cambio del de verdad.
    /// Y con un reloj de verdad y una espera ACOTADA que devuelve un `Bool`: si el tope vuelve
    /// a desaparecer, esto es un rojo con su frase, no un cuelgue.
    @MainActor func test_un_envio_colgado_no_retiene_el_socket_mas_que_el_plazo() async throws {
        let colgado = EnvioColgado()
        defer { colgado.libera() }
        let mando = MandoDeMentira(antesDeMandar: { await colgado.cuelga() })
        let alCerrar = Foto()
        let c = BrowserPanelCoordinator(stream: {
            (AsyncStream { cont in cont.onTermination = { _ in alCerrar.toma(mando.entradas) } }, mando)
        })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        let sesion = try XCTUnwrap(c.sesion(de: id))
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        let entro = await esperaHasta { colgado.entro }
        XCTAssertTrue(entro, "el envío no llegó a colgarse: la prueba no mediría el tope")

        let plazo = BrowserMandoEnvio.plazoParaLoQueQuedaEnVuelo
        let reloj = ContinuousClock()
        let t0 = reloj.now
        c.endTurn(survive: false, porque: "la prueba del envío colgado")
        let cerrado = await esperaHastaPorReloj(plazo + .seconds(2)) { alCerrar.tomada }
        let tardo = t0.duration(to: reloj.now)
        XCTAssertTrue(cerrado,
                      "con un envío colgado el socket del panel retirado no se cerró en \(plazo + .seconds(2)): "
                      + "el relé seguiría viendo al usuario como portador y el agente recibiría 409")
        XCTAssertTrue(colgado.entro && !colgado.liberado,
                      "el socket tiene que cerrarse CON el envío todavía colgado; si no, esto no mide el tope")
        XCTAssertEqual(alCerrar.foto, [], "el envío colgado no salió, y nada salió detrás de él")
        XCTAssertGreaterThanOrEqual(tardo, plazo - .milliseconds(100),
                                    "el socket se cerró antes del plazo: no se esperó a lo que quedaba en vuelo")
    }

    /// **DEVOLVER EL VOLANTE A MITAD DE GESTO CIERRA EL GESTO** (N2), sin soltar el mando: el
    /// panel sigue vivo y el usuario puede volver a tomarlo. El soltar sale en el último punto
    /// bueno, y la sesión sigue mandando: el siguiente toque es un clic nuevo.
    @MainActor func test_cerrar_el_gesto_suelta_el_boton_y_la_sesion_sigue_viva() async {
        let mando = MandoDeMentira()
        let sesion = BrowserMandoSesion(mando: mando)
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        let cierre = sesion.cierraElGesto()
        XCTAssertNotNil(cierre, "con un gesto abierto, cerrar tiene que devolver la cola para esperarla")
        let salio = await esperaHasta { mando.entradas.count == 2 }
        XCTAssertTrue(salio)
        XCTAssertEqual(mando.entradas, [pulsadoEnElCentro, soltadoEnElCentro], "el gesto no se cerró con su soltar")

        XCTAssertTrue(sesion.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        let tres = await esperaHasta { mando.entradas.count == 3 }
        XCTAssertTrue(tres, "tras cerrar el gesto la sesión dejó de mandar: cerrar no es retirar")
        XCTAssertEqual(mando.entradas.last,
                       #"{"button":"left","clickCount":1,"eventType":"mousePressed","type":"input_mouse","x":320,"y":180}"#)
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

    // MARK: ronda 8 — una sola cadena, la generación del teclado y la devolución (Codex)

    /// **UN CLIC ENCOLADO DETRÁS DE UN PEGADO SALE DETRÁS DEL PEGADO.** Con dos colas, el clic
    /// adelantaba a las teclas pendientes (el reparto de 17 ms deja segundos de ventana): el foco
    /// saltaba a otro campo y el resto de la contraseña se escribía ahí. El orden de los mensajes
    /// es el orden de encolado, también entre teclado y puntero.
    @MainActor func test_un_clic_detras_de_un_pegado_sale_detras_del_pegado() async {
        let mando = MandoDeMentira()
        let sesion = BrowserMandoSesion(mando: mando)
        sesion.teclea(["k1", "k2", "k3"])
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        let cuatro = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count == 4 }
        XCTAssertTrue(cuatro, "salieron \(mando.entradas.count) mensajes y tenían que ser cuatro")
        XCTAssertEqual(mando.entradas, ["k1", "k2", "k3", pulsadoEnElCentro],
                       "el clic adelantó a las teclas pendientes: el resto del pegado iría a otro campo")
    }

    /// **PERDER EL VOLANTE CORTA TODOS LOS LOTES DE TECLADO EN VUELO, NO SOLO EL ÚLTIMO, Y
    /// RECUPERARLO NO LOS REVIVE.** El escenario exacto de la revisión: un pegado largo y otro
    /// lote encadenado detrás; el servidor le da el volante al agente; el usuario lo recupera
    /// antes de que el pegado hubiera acabado. Antes, cancelar la última tarea dejaba vivo el
    /// pegado, que seguía escribiendo en el campo enfocado tras la recuperación.
    ///
    /// Por el camino de producción: el coordinador aplica los `mando` del flujo y es él quien
    /// avisa a la sesión.
    @MainActor func test_perder_el_volante_corta_todos_los_lotes_de_teclado_y_recuperarlo_no_los_revive() async throws {
        let mando = MandoDeMentira()
        let (flujo, rele) = AsyncStream<BrowserRelayEvent>.makeStream()
        let c = BrowserPanelCoordinator(stream: { (flujo, mando) })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        let estado = try XCTUnwrap(c.panels[id])
        let sesion = try XCTUnwrap(c.sesion(de: id))
        rele.yield(.mando(quien: .yo))
        let mio = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce == .yo }
        XCTAssertTrue(mio)

        let pegado = BrowserMandoEntrada.mensajesDeTeclado(anterior: "", nuevo: String(repeating: "a", count: 30))
        sesion.teclea(pegado)
        sesion.teclea(["b0", "b1"])
        let empezo = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count >= 3 }
        XCTAssertTrue(empezo, "el pegado debe empezar antes de perder el mando")
        rele.yield(.mando(quien: .agente))
        let perdido = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce == .agente }
        XCTAssertTrue(perdido)
        let alPerderlo = mando.entradas.count
        rele.yield(.mando(quien: .yo))
        let otraVez = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce == .yo }
        XCTAssertTrue(otraVez)
        // La tecla nueva sirve de barrera: está detrás de TODOS los lotes viejos.
        sesion.teclea(["nuevo"])
        let drenado = await esperaHastaPorReloj(.seconds(3)) { mando.entradas.last == "nuevo" }
        XCTAssertTrue(drenado)
        XCTAssertLessThan(alPerderlo, pegado.count)
        // Si la transición cayó tras un down, se conserva exactamente su up.
        let limiteDelPar = ((alPerderlo + 1) / 2) * 2
        XCTAssertEqual(mando.entradas, Array(pegado.prefix(limiteDelPar)) + ["nuevo"])
        XCTAssertFalse(mando.entradas.contains("b0"))
        rele.finish()
    }

    /// **DEVOLVER CON UN PEGADO EN CURSO SUELTA EL BOTÓN ANTES DEL PLAZO** — lo que la revisión de
    /// Codex vio del diseño de una sola cola: el soltar defensivo esperaría detrás del teclado, y
    /// 400 mensajes con su reparto son 6,8 s contra un plazo de 1 s. Por eso devolver invalida
    /// las teclas pendientes ANTES de encolar el soltar. Se fotografía lo que había salido en el
    /// instante en que salió `mando_devolver`: el soltar tiene que estar.
    @MainActor func test_devolver_con_un_pegado_en_curso_suelta_el_boton_antes_del_plazo() async {
        let mando = MandoDeMentira()
        let sesion = BrowserMandoSesion(mando: mando)
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        sesion.teclea((0..<400).map { "k\($0)" })
        let empezo = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count >= 5 }
        XCTAssertTrue(empezo, "el pegado no llegó a empezar: la prueba no mediría la espera")

        let plazo = BrowserMandoEnvio.plazoParaLoQueQuedaEnVuelo
        let reloj = ContinuousClock()
        let t0 = reloj.now
        sesion.devuelve()
        XCTAssertTrue(sesion.devolviendo, "devolver tiene que marcarse en el acto, antes de cualquier espera")
        let devuelto = await esperaHastaPorReloj(plazo + .seconds(2)) { mando.devoluciones == 1 }
        let tardo = t0.duration(to: reloj.now)
        let alDevolver = mando.entradas
        XCTAssertTrue(devuelto, "el volante no se devolvió")
        XCTAssertEqual(alDevolver.last, soltadoEnElCentro,
                       "cuando salió `mando_devolver` el botón seguía hundido: el soltar esperaba detrás del pegado")
        XCTAssertLessThan(tardo, plazo, "devolver tardó \(tardo): el soltar no salió por su pie, venció el plazo")
        try? await Task.sleep(for: BrowserMandoEntrada.intervaloEntreTeclas * 10)
        XCTAssertEqual(mando.entradas, alDevolver, "tras devolver siguieron saliendo teclas")
    }

    /// **RETIRAR EL PANEL CON UN PEGADO EN CURSO TAMBIÉN**: el soltar defensivo sale enseguida, no
    /// tras los segundos del pegado (la generación sube en `retira()` antes de encolarlo).
    @MainActor func test_retirar_con_un_pegado_en_curso_suelta_el_boton_antes_del_plazo() async {
        let mando = MandoDeMentira()
        let sesion = BrowserMandoSesion(mando: mando)
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable))
        sesion.teclea((0..<400).map { "k\($0)" })
        let empezo = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count >= 5 }
        XCTAssertTrue(empezo)

        let enVuelo = sesion.retira()
        XCTAssertNotNil(enVuelo)
        let suelto = await esperaHastaPorReloj(BrowserMandoEnvio.plazoParaLoQueQuedaEnVuelo) {
            mando.entradas.last == self.soltadoEnElCentro
        }
        XCTAssertTrue(suelto, "al retirar con un pegado en curso, el soltar no salió dentro del plazo")
    }

    /// **MIENTRAS SE DEVUELVE, EL DEDO APOYADO NO ABRE OTRO GESTO, Y TAMPOCO TRAS RECUPERAR EL
    /// VOLANTE.** La transición entera, por el coordinador: gesto abierto → «Devolverlo» → el
    /// mismo dedo sigue moviéndose (antes: un `mousePressed` nuevo que nadie soltaría) → el
    /// servidor da el volante al agente → el usuario lo recupera → el mismo dedo sigue apoyado y
    /// se levanta (no manda nada) → un dedo NUEVO sí hace clic.
    @MainActor func test_devolver_no_deja_que_el_dedo_apoyado_abra_otro_gesto() async throws {
        let mando = MandoDeMentira()
        let (flujo, rele) = AsyncStream<BrowserRelayEvent>.makeStream()
        let c = BrowserPanelCoordinator(stream: { (flujo, mando) })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        let estado = try XCTUnwrap(c.panels[id])
        let sesion = try XCTUnwrap(c.sesion(de: id))
        rele.yield(.mando(quien: .yo))
        let mio = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce == .yo }
        XCTAssertTrue(mio)

        // El dedo empieza en el centro: ése es su `startLocation` durante todo el contacto.
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                                  dimensionesDelCable: cable, contacto: centro))
        let devolver = sesion.devuelve()
        XCTAssertTrue(sesion.devolviendo)
        XCTAssertFalse(sesion.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                                   dimensionesDelCable: cable, contacto: centro),
                       "mientras se devuelve, el dedo que sigue apoyado abrió otro gesto")
        sesion.teclea(["x"])
        let devuelto = await esperaHastaPorReloj(.seconds(2)) { mando.devoluciones == 1 }
        XCTAssertTrue(devuelto)
        _ = devolver
        XCTAssertTrue(sesion.devolviendo, "devolverlo salió, pero el servidor no ha contestado: se sigue devolviendo")

        rele.yield(.mando(quien: .agente))
        let suyo = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce == .agente }
        XCTAssertTrue(suyo)
        XCTAssertFalse(sesion.devolviendo, "el `mando` del servidor resuelve la devolución")

        rele.yield(.mando(quien: .yo))
        let otraVez = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce == .yo }
        XCTAssertTrue(otraVez)
        XCTAssertFalse(sesion.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                                   dimensionesDelCable: cable, contacto: centro),
                       "con el volante nuevo, el MISMO dedo apoyado se leyó como un clic nuevo")
        sesion.levanta(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                       dimensionesDelCable: cable, contacto: centro)
        XCTAssertTrue(sesion.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                                  dimensionesDelCable: cable, contacto: cuarto),
                      "un dedo nuevo tiene que poder hacer clic: si no, el filtro se come el mando entero")

        let tres = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count >= 3 }
        XCTAssertTrue(tres)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mando.entradas,
                       [pulsadoEnElCentro, soltadoEnElCentro,
                        #"{"button":"left","clickCount":1,"eventType":"mousePressed","type":"input_mouse","x":320,"y":180}"#],
                       "salió algo más que el gesto cerrado con su soltar y el clic del dedo nuevo")
        rele.finish()
    }

    /// **SI DEVOLVERLO NO SALE DEL APARATO, LA SESIÓN VUELVE A ACEPTAR ENTRADA.** El servidor no
    /// se ha enterado y el volante sigue siendo del usuario: dejar `devolviendo` puesto le dejaría
    /// conduciendo con todo lo que toque y teclee rechazado.
    @MainActor func test_la_sesion_conserva_el_keyUp_si_pierde_el_volante_durante_keyDown() async {
        let envio = EnvioColgado()
        let mando = MandoDeMentira(antesDeMandar: { await envio.cuelga() })
        let sesion = BrowserMandoSesion(mando: mando)
        let viejo = BrowserMandoEntrada.mensajesDeTeclado(anterior: "", nuevo: "ab")
        let nuevo = BrowserMandoEntrada.mensajesDeTeclado(anterior: "", nuevo: "c")
        sesion.teclea(viejo)
        let dentro = await esperaHastaPorReloj(.seconds(2)) { envio.entro }
        XCTAssertTrue(dentro)
        sesion.cambioElVolante()
        sesion.teclea(nuevo)
        envio.libera()
        let fin = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count >= 4 }
        XCTAssertTrue(fin)
        XCTAssertEqual(mando.entradas, Array(viejo.prefix(2)) + nuevo)
    }

    @MainActor func test_devolver_sin_confirmacion_caduca_con_aviso_y_admite_un_lote_nuevo() async {
        let mando = MandoDeMentira()
        let reloj = EnvioColgado()
        let sesion = BrowserMandoSesion(mando: mando, plazoDeDevolucion: .seconds(3),
            esperaDeDevolucion: { plazo in
                XCTAssertEqual(plazo, .seconds(3))
                await reloj.cuelga()
            })
        sesion.devuelve()
        let enviado = await esperaHastaPorReloj(.seconds(2)) { mando.devoluciones == 1 && reloj.entro }
        XCTAssertTrue(enviado)
        XCTAssertTrue(sesion.devolviendo)
        sesion.teclea(BrowserMandoEntrada.mensajesDeTeclado(anterior: "", nuevo: "x"))
        reloj.libera()
        let vencido = await esperaHastaPorReloj(.seconds(2)) { !sesion.devolviendo && sesion.entradaPerdida }
        XCTAssertTrue(vencido, "el envío salió, pero sin confirmación el bloqueo debe caducar con aviso")
        XCTAssertEqual(BrowserPanelView.avisoDeApuntado(quienConduce: .yo, sePuedeApuntar: true,
                                                       entradaPerdida: sesion.entradaPerdida),
                       BrowserPanelView.textoDeEntradaPerdida)
        let nuevo = BrowserMandoEntrada.mensajesDeTeclado(anterior: "", nuevo: "y")
        sesion.teclea(nuevo)
        let salio = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count == nuevo.count }
        XCTAssertTrue(salio)
        XCTAssertEqual(mando.entradas, nuevo, "el lote descartado no debe revivir al caducar")
    }

    @MainActor func test_un_reloj_de_devolucion_antiguo_no_resuelve_la_devolucion_nueva() async {
        let primero = EnvioColgado()
        let segundo = EnvioColgado()
        let turnos = Contador()
        let terminados = Contador()
        let sesion = BrowserMandoSesion(mando: MandoDeMentira(), esperaDeDevolucion: { _ in
            turnos.suma()
            if turnos.valor == 1 { await primero.cuelga() } else { await segundo.cuelga() }
            terminados.suma()
        })
        sesion.devuelve()
        let inicio = await esperaHastaPorReloj(.seconds(2)) { primero.entro }
        XCTAssertTrue(inicio)
        sesion.cambioElVolante()
        sesion.devuelve()
        let otro = await esperaHastaPorReloj(.seconds(2)) { segundo.entro }
        XCTAssertTrue(otro)
        primero.libera()
        let viejo = await esperaHastaPorReloj(.seconds(2)) { terminados.valor == 1 }
        XCTAssertTrue(viejo)
        XCTAssertTrue(sesion.devolviendo, "un plazo antiguo no debe abrir la puerta de la petición nueva")
        XCTAssertFalse(sesion.entradaPerdida)
        segundo.libera()
        let nuevo = await esperaHastaPorReloj(.seconds(2)) { sesion.entradaPerdida && !sesion.devolviendo }
        XCTAssertTrue(nuevo)
    }

    /// Sin await/yield entre aplicar y afirmar: Mh debe fallar aquí aunque la Task
    /// diferida pudiera ejecutarse en el próximo salto del actor.
    @MainActor func test_el_coordinador_avisa_sincronicamente_al_aplicar_mando_y_closed() throws {
        for evento in [BrowserRelayEvent.mando(quien: .agente), .closed(reason: "fin")] {
            let (flujo, rele) = AsyncStream<BrowserRelayEvent>.makeStream()
            let c = BrowserPanelCoordinator(stream: { (flujo, MandoDeMentira()) })
            let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
            let sesion = try XCTUnwrap(c.sesion(de: id))
            c.aplica(.mando(quien: .yo), al: id)
            sesion.devuelve()
            XCTAssertTrue(sesion.devolviendo)
            c.aplica(evento, al: id)
            XCTAssertFalse(sesion.devolviendo, "el coordinador difirió el aviso a la sesión")
            XCTAssertTrue(sesion.toca(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                                      dimensionesDelCable: cable, contacto: cuarto))
            sesion.levanta(punto: cuarto, vista: imagen, tamañoDeLaImagen: imagen,
                           dimensionesDelCable: cable, contacto: cuarto)
            rele.finish()
        }
    }

    /// HUECO medido: SwiftUI solo proporciona el mismo origen para dos historias
    /// indistinguibles: contacto viejo aún apoyado o clic nuevo en el mismo píxel.
    /// Se conserva el rechazo seguro hasta onEnded; no se inventa una identidad.
    @MainActor func test_colision_exacta_del_contacto_sin_onEnded_sigue_declarada() async {
        let mando = MandoDeMentira()
        let sesion = BrowserMandoSesion(mando: mando)
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                                  dimensionesDelCable: cable, contacto: centro))
        let cierre = sesion.cierraElGesto()
        sesion.cambioElVolante()
        sesion.cambioElVolante()
        let r1 = sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                             dimensionesDelCable: cable, contacto: centro)
        XCTAssertFalse(r1, "el contacto viejo debe seguir ignorado; el nuevo idéntico se pierde también")
        sesion.levanta(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                       dimensionesDelCable: cable, contacto: centro)
        let r2 = sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                             dimensionesDelCable: cable, contacto: centro)
        XCTAssertTrue(r2)
        sesion.levanta(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                       dimensionesDelCable: cable, contacto: centro)
        _ = cierre
        let fin = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count == 4 }
        XCTAssertTrue(fin)
        XCTAssertEqual(mando.entradas, [pulsadoEnElCentro, soltadoEnElCentro,
                                       pulsadoEnElCentro, soltadoEnElCentro])
    }

    @MainActor func test_si_devolver_no_sale_la_sesion_vuelve_a_aceptar_entrada() async {
        let mando = MandoDeMentira(salida: false)
        let sesion = BrowserMandoSesion(mando: mando)
        let devolver = sesion.devuelve()
        XCTAssertTrue(sesion.devolviendo)
        let recuperado = await esperaHastaPorReloj(.seconds(2)) {
            mando.devoluciones == 1 && !sesion.devolviendo
        }
        XCTAssertTrue(recuperado)
        _ = devolver
        XCTAssertEqual(mando.devoluciones, 1, "devolverlo se tiene que haber intentado")
        XCTAssertFalse(sesion.devolviendo, "devolverlo no salió y la sesión se quedó rechazando la entrada")
        XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                                  dimensionesDelCable: cable, contacto: cuarto))
    }

    /// Lo que no sale del TECLADO también se dice, ahora que el teclado encola en la sesión.
    @MainActor func test_una_tecla_que_no_sale_queda_anotada_en_la_sesion() async {
        let sesion = BrowserMandoSesion(mando: MandoDeMentira(salida: false))
        XCTAssertFalse(sesion.entradaPerdida)
        sesion.teclea(["k"])
        let anotado = await esperaHasta { sesion.entradaPerdida }
        XCTAssertTrue(anotado, "la tecla no salió y la sesión no lo anotó")
    }

    /// **EL FIN DEL FLUJO TAMBIÉN CORTA LAS TECLAS PENDIENTES.** Sin socket no sale nada, pero la
    /// sesión se suelta con su mando dentro: si el pegado siguiera, intentaría mandar por un
    /// canal muerto durante segundos.
    @MainActor func test_el_fin_del_flujo_corta_las_teclas_pendientes() async throws {
        let mando = MandoDeMentira()
        let (flujo, rele) = AsyncStream<BrowserRelayEvent>.makeStream()
        let c = BrowserPanelCoordinator(stream: { (flujo, mando) })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        let sesion = try XCTUnwrap(c.sesion(de: id))
        sesion.teclea((0..<60).map { "a\($0)" })
        let empezo = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.count >= 3 }
        XCTAssertTrue(empezo)
        rele.finish()
        let suelta = await esperaHastaPorReloj(.seconds(2)) { c.sesion(de: id) == nil }
        XCTAssertTrue(suelta)
        try? await Task.sleep(for: .milliseconds(100))
        let alAcabar = mando.entradas.count
        try? await Task.sleep(for: BrowserMandoEntrada.intervaloEntreTeclas * 20)
        XCTAssertEqual(mando.entradas.count, alAcabar, "tras terminar el flujo siguieron saliendo teclas")
    }

    /// El puntero ya entró en manda; las teclas siguen esperando. Se pierde y recupera
    /// el volante antes de abrir la puerta: ninguna tecla de ninguno de los dos lotes sale.
    @MainActor func test_lotes_pendientes_no_reviven_tras_perdida_y_concesion() async throws {
        for perdida in [BrowserRelayEvent.mando(quien: .agente), .closed(reason: "corte")] {
            let puerta = PrimeraEnLaPuerta()
            let mando = MandoDeMentira(antesDeMandar: { await puerta.pasa() })
            let (flujo, rele) = AsyncStream<BrowserRelayEvent>.makeStream()
            let c = BrowserPanelCoordinator(stream: { (flujo, mando) })
            let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
            let estado = try XCTUnwrap(c.panels[id])
            let sesion = try XCTUnwrap(c.sesion(de: id))
            rele.yield(.mando(quien: .yo))
            let concedido = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce == .yo }
            XCTAssertTrue(concedido)
            XCTAssertTrue(sesion.toca(punto: centro, vista: imagen, tamañoDeLaImagen: imagen,
                                      dimensionesDelCable: cable))
            let entro = await puerta.esperaQueAlguienEntre()
            XCTAssertTrue(entro)
            sesion.levanta(punto: centro, vista: imagen, tamañoDeLaImagen: imagen, dimensionesDelCable: cable)
            sesion.teclea(["vieja1", "vieja2"])
            sesion.teclea(["vieja3"])
            rele.yield(perdida)
            let perdido = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce != .yo }
            XCTAssertTrue(perdido)
            rele.yield(.mando(quien: .yo))
            let recuperado = await esperaHastaPorReloj(.seconds(2)) { estado.quienConduce == .yo }
            XCTAssertTrue(recuperado)
            sesion.teclea(["nueva"])
            puerta.abre()
            let drenado = await esperaHastaPorReloj(.seconds(2)) { mando.entradas.last == "nueva" }
            XCTAssertTrue(drenado)
            XCTAssertEqual(mando.entradas, [pulsadoEnElCentro, soltadoEnElCentro, "nueva"])
            rele.finish()
        }
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

    /// Como `esperaHasta`, pero por **reloj de pared**: lo que se mide aquí es un plazo en
    /// segundos, y los saltos del hilo principal no son tiempo. Acotada y devolviendo `Bool`.
    @MainActor private func esperaHastaPorReloj(_ limite: Duration, _ condicion: @MainActor () -> Bool) async -> Bool {
        let reloj = ContinuousClock()
        let fin = reloj.now.advanced(by: limite)
        while reloj.now < fin {
            if condicion() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condicion()
    }

    /// Un envío que NO VUELVE hasta que la prueba lo libera (o, como red, a los 30 s): el envío
    /// colgado de un enlace muerto, que no atiende a la cancelación.
    private final class EnvioColgado: @unchecked Sendable {
        private let candado = NSLock()
        private var _entro = false
        private var _liberado = false
        var entro: Bool { candado.withLock { _entro } }
        var liberado: Bool { candado.withLock { _liberado } }
        func libera() { candado.withLock { _liberado = true } }
        func cuelga() async {
            candado.withLock { _entro = true }
            let fin = ContinuousClock.now.advanced(by: .seconds(30))
            while !liberado, ContinuousClock.now < fin {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
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
