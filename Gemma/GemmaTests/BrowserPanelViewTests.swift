import CoreGraphics
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

/// La interfaz del mando compartido: el botón, el rótulo de quién conduce, el toque y el
/// teclado.
///
/// POR QUÉ ESTA PANTALLA EXISTE, PORQUE GOBIERNA CADA ASERCIÓN DE ABAJO. El navegador vive en el
/// servidor doméstico y el agente tiene prohibido teclear contraseñas, así que hay cosas que no
/// podrá hacer nunca: entrar en una cuenta. El perfil persistente del navegador del i3 está
/// desplegado y **vacío**, porque nadie ha podido escribir una contraseña en él. Esto es el
/// último trozo que falta para que el usuario teclee él. Las dos formas de fallar que estas
/// pruebas existen para cerrar:
///
///   - **Si el gesto manda la coordenada equivocada**, el usuario pulsa otro botón de su propia
///     cuenta: la página de al otro lado tiene su sesión abierta y nadie aguas abajo valida nada
///     (el relé reenvía al demonio verbatim y valida solo el `type`).
///   - **Si el rótulo miente sobre de quién es el turno**, el usuario teclea su contraseña
///     contra una página que no la recibe: el relé descarta la entrada ajena **en silencio**
///     (`_reenvia_entrada` compara el portador por su socket), así que no hay ningún aviso.
///
/// LA TRAMPA DE ESTE FICHERO, DICHA EN VOZ ALTA. `quienConduce` arranca en `.agente` y
/// `capturaLosGestos` es `false` por omisión, así que **una prueba que afirme esos dos valores
/// en reposo pasa con la característica entera borrada**. Por eso la prueba de la captura no
/// afirma un estado: recorre el **ciclo completo** sobre un `BrowserPanelState` de verdad
/// (encender → comprobar encendido → perder el volante → comprobar apagado). Lo mismo con el
/// mapa: una función que devuelve `[]` para todo pasa todas las pruebas de «no manda nada», así
/// que cada una de ésas tiene al lado su prueba de acierto con las cifras escritas a mano.
///
/// DE DÓNDE SALEN LAS CIFRAS. Viewport medido del demonio 1280×720, JPEG que llega 1080×608
/// (`agent-browser 0.41.2`, medición de la Tarea 2). El tope de caudal del relé es **120
/// mensajes por ventana de 1 s** por visor, con el acuse exento
/// (`MAX_ENTRADAS_POR_VENTANA`/`VENTANA_DE_ENTRADA`, `browser/relay.py:469-470`).
final class BrowserPanelViewTests: XCTestCase {

    // MARK: atajos

    private typealias Cable = BrowserInputMapper.DimensionesDelCable
    private typealias Entrada = BrowserMandoEntrada

    /// El viewport y el fotograma medidos, y una vista que comparte proporción con la imagen
    /// (que es lo que pasa de verdad, porque el gesto va enganchado a la `Image` y
    /// `.scaledToFit()` hace que la vista de la imagen SEA el rectángulo dibujado).
    private let cableMedido = Cable(anchoDelViewport: 1280, altoDelViewport: 720)
    private let imagenMedida = CGSize(width: 1080, height: 608)

    // MARK: el botón

    /// El botón ofrece tomar el volante cuando lo tiene el agente, y devolverlo cuando es del
    /// usuario. **La frase completa, no sus palabras**: una aserción por palabras clave pasa con
    /// la frase equivocada y falla con la correcta.
    func test_el_boton_ofrece_tomar_el_volante_y_devolverlo() {
        XCTAssertEqual(BrowserPanelView.textoDelBoton(quienConduce: .agente), "Tomar el volante")
        XCTAssertEqual(BrowserPanelView.textoDelBoton(quienConduce: .yo), "Devolverlo")
    }

    /// Con OTRO VISOR al volante el botón no ofrece tomarlo, y además no actúa.
    ///
    /// POR QUÉ, MEDIDO: `Mando.toma` devuelve `False` cuando ya lo tiene otro y el manejador del
    /// visor **descarta ese booleano** (`relay.py:965`). No hay respuesta de error. Un botón que
    /// ofreciera «tomar el volante» prometería algo que no va a pasar y el usuario no recibiría
    /// ninguna explicación.
    ///
    /// Se afirma de las dos formas a propósito: el texto distinto solo, y el predicado solo,
    /// pasarían con un cuerpo degenerado cada uno (una función constante). Y el predicado se
    /// afirma `true` en los otros dos valores, porque un `elBotonActua` que devolviera `false`
    /// siempre pasaría la mitad de esta prueba.
    func test_con_otro_visor_el_boton_no_ofrece_tomarlo_ni_actua() {
        XCTAssertNotEqual(BrowserPanelView.textoDelBoton(quienConduce: .otroVisor), "Tomar el volante")
        XCTAssertEqual(BrowserPanelView.textoDelBoton(quienConduce: .otroVisor), "Lo tiene otro visor")
        XCTAssertFalse(BrowserPanelView.elBotonActua(quienConduce: .otroVisor))
        XCTAssertTrue(BrowserPanelView.elBotonActua(quienConduce: .agente))
        XCTAssertTrue(BrowserPanelView.elBotonActua(quienConduce: .yo))
    }

    /// El rótulo dice de quién es el turno, y los tres casos dicen cosas distintas.
    ///
    /// EL TERCERO NO ES COSMÉTICO. Mientras conduce un humano, **el fotograma va solo a su
    /// socket** (`relay.py:1033`); el estado, el resumen y el `mando` siguen yendo a todos,
    /// precisamente para que un visor que no conduce lo SEPA. Sin esta frase el usuario ve una
    /// imagen parada y vuelve al fallo de «la foto congelada sin explicación» que ya se arregló
    /// una vez.
    func test_el_rotulo_dice_de_quien_es_el_turno_y_explica_la_imagen_parada() {
        XCTAssertEqual(BrowserPanelView.rotuloDeQuienConduce(quienConduce: .agente),
                       "Conduce el agente.")
        XCTAssertEqual(BrowserPanelView.rotuloDeQuienConduce(quienConduce: .yo),
                       "Conduces tú: lo que toques y escribas va a la página.")
        XCTAssertEqual(BrowserPanelView.rotuloDeQuienConduce(quienConduce: .otroVisor),
                       "Conduce otro visor: la imagen no se actualiza aquí.")
    }

    // MARK: la captura

    /// `capturaLosGestos` solo está encendida cuando conduce el usuario.
    ///
    /// *(Foco de revisión 1.)* El relé descarta la entrada ajena en silencio, así que si la
    /// interfaz no impide el gesto el usuario toca y no pasa nada **sin que nada se lo diga**.
    ///
    /// Esta prueba sola NO basta y no pretende bastar: el `false` de dos de los tres valores es
    /// el valor por omisión de un `Bool`. Lo que la hace valer es el `true` del medio y, sobre
    /// todo, el ciclo completo de la prueba siguiente.
    func test_la_captura_solo_esta_encendida_cuando_conduce_el_usuario() {
        XCTAssertTrue(BrowserPanelView.capturaLosGestos(quienConduce: .yo))
        XCTAssertFalse(BrowserPanelView.capturaLosGestos(quienConduce: .agente))
        XCTAssertFalse(BrowserPanelView.capturaLosGestos(quienConduce: .otroVisor))
    }

    /// EL CICLO COMPLETO: la captura se enciende con el `mando` del servidor y se apaga **en el
    /// mismo cambio de estado** en que el volante deja de ser del usuario. Sin esperar un plazo,
    /// sin esperar a que acabe un gesto, sin `await` de nada.
    ///
    /// *(Foco de revisión 2, y es lo que más importa de esta tarea.)* El plazo del mando mide
    /// **inactividad**, y pensar no es actividad: el volante se le puede caer al usuario
    /// **mientras teclea su contraseña**. Si la captura siguiera encendida un instante más, ese
    /// instante se lo lleva el relé a la basura en silencio y el usuario sigue escribiendo.
    ///
    /// Se recorren los TRES caminos por los que se pierde: el `mando` del servidor, el corte de
    /// conexión (el portador del mando es el socket) y el congelado del panel. Y cada uno se
    /// mide **después** de haber comprobado que estaba encendido, que es lo que esta prueba
    /// tiene y la anterior no.
    // 🔴 LAS CINCO PRUEBAS DE ABAJO LLEVAN PUERTA DE PLATAFORMA, Y ÉSTE ES EL MOTIVO MEDIDO,
    // que es lo que las tres puertas de fichero de este subsistema NO tenían escrito.
    //
    // **El test host de iOS no puede instanciar `BrowserPanelState` ni `BrowserPanelCoordinator`:
    // el proceso aborta.** No es una aserción que falle —no hay una sola línea `XCTAssert…failed`
    // en el log de iOS— es `Test crashed with signal abrt`, y XCTest reinicia el host y marca
    // como fallida la prueba que tenía en vuelo.
    //
    // ES PREEXISTENTE Y NO ES DE ESTA TAREA, y se midió aislándolo: `BrowserPanelStateTests`
    // —fichero de la Tarea 4, **sin ninguna puerta de plataforma**, que esta tarea no creó—
    // corrido SOLO en iOS 26.2 (iPhone 17, `-parallel-testing-enabled NO`) da
    // «Executed 0 tests» y, al mismo tiempo, **las 21 pruebas que lista salen fallidas**, con
    // 21 «Restarting after unexpected exit»: el host de pruebas muere antes de correr ninguna.
    // La señal que lo delata es la que NO está —**cero** líneas `XCTAssert…failed` en todo el
    // log— y por eso no es un rojo de aserciones. Lo mismo le pasa a
    // `BrowserPanelCoordinatorTests` y a `BrowserCrossPlatformTests`. En macOS esa misma clase
    // da **21 de 21 verdes**. Diagnosticar ese aborto es un sub-proyecto propio (es un
    // `@Observable @MainActor` en el host de pruebas de iOS) y no cabe en una ronda de arreglos
    // de la interfaz.
    //
    // POR QUÉ LA PUERTA VA POR PRUEBA Y NO POR FICHERO: así **33 de las 38** pruebas del mando
    // sí corren en el aparato del usuario —que es su iPhone— en vez de ninguna. Las cinco de
    // aquí son exactamente las que instancian uno de los dos tipos que abortan; todo lo demás
    // (la aritmética del puntero y del teclado, el reparto, la cola, el botón, el rótulo, la
    // lista blanca y las dos aserciones estructurales) es puro y corre en las dos plataformas.
    // Cuando el aborto se arregle, estas cinco puertas se quitan y la medición de arriba es la
    // que dice si ya se puede.
    #if os(macOS)
    @MainActor func test_la_captura_se_apaga_en_el_mismo_cambio_de_estado_que_pierde_el_volante() {
        for perderElVolante in Self.losCuatroCaminosQuePierdenElVolante {
            let s = BrowserPanelState()
            XCTAssertFalse(BrowserPanelView.capturaLosGestos(quienConduce: s.quienConduce),
                           "antes de que el servidor lo diga, el volante no es del usuario")

            s.apply(.mando(quien: .yo))
            XCTAssertTrue(BrowserPanelView.capturaLosGestos(quienConduce: s.quienConduce),
                          "el `mando` del servidor tiene que ENCENDER la captura; sin esto el "
                          + "resto de la prueba pasaría con la característica borrada")

            perderElVolante.quitar(s)
            XCTAssertFalse(BrowserPanelView.capturaLosGestos(quienConduce: s.quienConduce),
                           "la captura sigue encendida tras \(perderElVolante.nombre): el usuario "
                           + "puede estar a medio teclear una contraseña")
        }
    }
    #endif

    /// Los cuatro caminos por los que el volante deja de ser del usuario, sin que él haga nada.
    private struct CaminoQuePierdeElVolante {
        let nombre: String
        let quitar: @MainActor (BrowserPanelState) -> Void
    }

    private static let losCuatroCaminosQuePierdenElVolante: [CaminoQuePierdeElVolante] = [
        .init(nombre: "el `mando` del servidor diciendo que conduce el agente",
              quitar: { $0.apply(.mando(quien: .agente)) }),
        .init(nombre: "el `mando` del servidor diciendo que conduce otro visor",
              quitar: { $0.apply(.mando(quien: .otroVisor)) }),
        .init(nombre: "el corte de la conexión, que se lleva el volante con el socket",
              quitar: { $0.apply(.closed(reason: "fallo de recepción")) }),
        .init(nombre: "el congelado del panel al terminar el turno",
              quitar: { $0.freeze() }),
    ]

    // MARK: el toque — el acierto, con las cifras a mano

    /// Una pulsación sobre el centro de la imagen manda `mousePressed` y `mouseReleased` en el
    /// centro de la página, **con las cifras escritas aquí** y no calculadas por la prueba.
    ///
    /// La aritmética, a mano: la vista mide lo que la imagen (1080×608), así que la escala de
    /// dibujo es 1 y no hay bandas; el centro de la vista es (540, 304);
    /// 540 × 1280/1080 = **640** exacto y 304 × 720/608 = **360** exacto. El centro de la página
    /// de 1280×720 es (640, 360).
    func test_una_pulsacion_en_el_centro_manda_el_clic_en_el_centro_de_la_pagina() {
        let pulsa = Entrada.mensajesDePuntero(fase: .pulsa, punto: CGPoint(x: 540, y: 304),
                                              ultimaPagina: nil,
                                              tamañoDeLaVista: imagenMedida,
                                              tamañoDeLaImagen: imagenMedida,
                                              dimensionesDelCable: cableMedido)
        XCTAssertEqual(pulsa.mensajes,
                       [#"{"button":"left","clickCount":1,"eventType":"mousePressed","type":"input_mouse","x":640,"y":360}"#])
        XCTAssertEqual(pulsa.pagina, CGPoint(x: 640, y: 360),
                       "el punto bueno se recuerda: es el que suelta el botón si el dedo sale de la imagen")

        let suelta = Entrada.mensajesDePuntero(fase: .suelta, punto: CGPoint(x: 540, y: 304),
                                               ultimaPagina: pulsa.pagina,
                                               tamañoDeLaVista: imagenMedida,
                                               tamañoDeLaImagen: imagenMedida,
                                               dimensionesDelCable: cableMedido)
        XCTAssertEqual(suelta.mensajes,
                       [#"{"button":"left","clickCount":1,"eventType":"mouseReleased","type":"input_mouse","x":640,"y":360}"#])
        XCTAssertNil(suelta.pagina, "al soltar no queda gesto en curso, así que no hay punto que recordar")
    }

    /// La esquina de abajo a la derecha de una página de 1280×720 es **(1279, 719)**, no
    /// (1280, 720): `viewport_width` es un recuento de columnas, así que x = 1280 cae fuera de
    /// la página (en la barra de desplazamiento). Es decisión del mapa y se clava desde aquí
    /// también, porque es la cifra que viaja al demonio.
    func test_la_esquina_de_la_imagen_es_la_esquina_de_la_pagina_menos_uno() {
        let r = Entrada.mensajesDePuntero(fase: .pulsa, punto: CGPoint(x: 1080, y: 608),
                                          ultimaPagina: nil,
                                          tamañoDeLaVista: imagenMedida,
                                          tamañoDeLaImagen: imagenMedida,
                                          dimensionesDelCable: cableMedido)
        XCTAssertEqual(r.mensajes,
                       [#"{"button":"left","clickCount":1,"eventType":"mousePressed","type":"input_mouse","x":1279,"y":719}"#])
    }

    /// Un arrastre manda `mouseMoved`, y con `clickCount` 0: para un movimiento el recuento de
    /// pulsaciones no significa nada.
    func test_el_arrastre_manda_el_movimiento_del_raton() {
        let r = Entrada.mensajesDePuntero(fase: .mueve, punto: CGPoint(x: 540, y: 304),
                                          ultimaPagina: CGPoint(x: 1, y: 2),
                                          tamañoDeLaVista: imagenMedida,
                                          tamañoDeLaImagen: imagenMedida,
                                          dimensionesDelCable: cableMedido)
        XCTAssertEqual(r.mensajes,
                       [#"{"button":"left","clickCount":0,"eventType":"mouseMoved","type":"input_mouse","x":640,"y":360}"#])
        XCTAssertEqual(r.pagina, CGPoint(x: 640, y: 360))
    }

    // MARK: el toque — las zonas que no se pueden mapear

    /// Un gesto sobre una zona que `paginaDesde` no sabe mapear **no manda nada**.
    ///
    /// Los tres casos realistas, y ninguno es raro: sin dimensiones del cable (un servidor sin
    /// desplegar, o un fotograma al que el demonio no le dio `metadata`), sobre la banda que
    /// deja `.scaledToFit()` cuando la vista no comparte proporción con la imagen, y con una
    /// imagen que no es el viewport escalado (el guarda de proporción del mapa).
    ///
    /// `nil` significa **no mandes nada**, nunca `.zero`: (0, 0) es una coordenada buenísima —es
    /// el logotipo de la página— así que tratar el `nil` como cero convertiría un toque
    /// imposible de mapear en un clic en la esquina de arriba a la izquierda.
    func test_un_gesto_sobre_una_zona_que_no_se_puede_mapear_no_manda_nada() {
        // (a) sin dimensiones del cable.
        let sinCable = Entrada.mensajesDePuntero(fase: .pulsa, punto: CGPoint(x: 540, y: 304),
                                                 ultimaPagina: nil,
                                                 tamañoDeLaVista: imagenMedida,
                                                 tamañoDeLaImagen: imagenMedida,
                                                 dimensionesDelCable: nil)
        XCTAssertEqual(sinCable.mensajes, [], "sin el viewport no se puede situar un toque")
        XCTAssertNil(sinCable.pagina)

        // (b) sobre la banda: vista 1080×1000 contra imagen 1080×608 → escala de dibujo 1,
        // 196 px de banda arriba y abajo. El punto y = 10 está en la banda.
        let enLaBanda = Entrada.mensajesDePuntero(fase: .pulsa, punto: CGPoint(x: 540, y: 10),
                                                  ultimaPagina: nil,
                                                  tamañoDeLaVista: CGSize(width: 1080, height: 1000),
                                                  tamañoDeLaImagen: imagenMedida,
                                                  dimensionesDelCable: cableMedido)
        XCTAssertEqual(enLaBanda.mensajes, [], "la banda no es la página")

        // (c) una imagen que no es el viewport escalado (proporción muy distinta): el mapa se
        // calla porque por el cable no viaja desplazamiento y un recorte no se puede corregir.
        let recortada = Entrada.mensajesDePuntero(fase: .pulsa, punto: CGPoint(x: 100, y: 100),
                                                  ultimaPagina: nil,
                                                  tamañoDeLaVista: CGSize(width: 400, height: 400),
                                                  tamañoDeLaImagen: CGSize(width: 400, height: 400),
                                                  dimensionesDelCable: cableMedido)
        XCTAssertEqual(recortada.mensajes, [], "una imagen cuadrada no es un viewport de 16:9 escalado")
    }

    /// Si el dedo sale de la imagen antes de levantarse, el botón se suelta **en el último punto
    /// bueno**.
    ///
    /// POR QUÉ NO SE PUEDE «NO MANDAR NADA» AQUÍ, que es lo que haría la regla general: ya se
    /// mandó un `mousePressed`. Un `mousePressed` sin su `mouseReleased` deja el botón del ratón
    /// **hundido** en la página remota, y a partir de ahí todo lo que el usuario toque arrastra.
    /// No mandar el soltar no es la dirección segura: es dejar el navegador roto.
    func test_el_soltar_fuera_de_la_imagen_se_manda_en_el_ultimo_punto_bueno() {
        let r = Entrada.mensajesDePuntero(fase: .suelta, punto: CGPoint(x: -500, y: -500),
                                          ultimaPagina: CGPoint(x: 640, y: 360),
                                          tamañoDeLaVista: imagenMedida,
                                          tamañoDeLaImagen: imagenMedida,
                                          dimensionesDelCable: cableMedido)
        XCTAssertEqual(r.mensajes,
                       [#"{"button":"left","clickCount":1,"eventType":"mouseReleased","type":"input_mouse","x":640,"y":360}"#])
        XCTAssertNil(r.pagina)
    }

    /// Pero sin NINGÚN punto bueno no se manda nada: no hay ningún `mousePressed` pendiente que
    /// cerrar, porque el `pulsa` que no se pudo mapear tampoco mandó nada.
    func test_sin_ningun_punto_bueno_el_soltar_no_manda_nada() {
        let r = Entrada.mensajesDePuntero(fase: .suelta, punto: CGPoint(x: -500, y: -500),
                                          ultimaPagina: nil,
                                          tamañoDeLaVista: imagenMedida,
                                          tamañoDeLaImagen: imagenMedida,
                                          dimensionesDelCable: cableMedido)
        XCTAssertEqual(r.mensajes, [])
        XCTAssertNil(r.pagina)
    }

    /// Un movimiento que no se puede mapear no manda nada **y no borra la memoria**: el dedo
    /// puede volver a entrar en la imagen, y si al salir se olvidara el último punto bueno el
    /// soltar de después se quedaría sin sitio donde levantar el botón.
    func test_el_movimiento_fuera_de_la_imagen_no_manda_y_conserva_el_ultimo_punto_bueno() {
        let r = Entrada.mensajesDePuntero(fase: .mueve, punto: CGPoint(x: -500, y: -500),
                                          ultimaPagina: CGPoint(x: 640, y: 360),
                                          tamañoDeLaVista: imagenMedida,
                                          tamañoDeLaImagen: imagenMedida,
                                          dimensionesDelCable: cableMedido)
        XCTAssertEqual(r.mensajes, [])
        XCTAssertEqual(r.pagina, CGPoint(x: 640, y: 360))
    }

    // MARK: el muestreo

    /// El muestreo de un gesto continuo: el primer evento pasa siempre, y después uno cada
    /// `intervaloDeMuestreo`. La frontera se mide exacta.
    ///
    /// POR QUÉ HAY QUE MUESTREAR: hay un tope de caudal en el relé y lo que lo pasa **se
    /// descarta en silencio**, pero el daño de verdad es otro — el acuse del visor es lo que
    /// mueve el ritmo del demonio, así que una inundación que se coma el presupuesto **congela
    /// el panel de todos los visores**, no solo del que inunda.
    func test_el_gesto_continuo_se_muestrea_y_la_frontera_es_exacta() {
        let t0 = ContinuousClock.Instant.now
        XCTAssertTrue(Entrada.tocaMuestrear(ultimo: nil, ahora: t0),
                      "el primer evento del gesto no espera a nadie")
        XCTAssertFalse(Entrada.tocaMuestrear(ultimo: t0, ahora: t0.advanced(by: Entrada.intervaloDeMuestreo - .milliseconds(1))))
        XCTAssertTrue(Entrada.tocaMuestrear(ultimo: t0, ahora: t0.advanced(by: Entrada.intervaloDeMuestreo)),
                      "el instante justo del intervalo ya toca")
        XCTAssertTrue(Entrada.tocaMuestrear(ultimo: t0, ahora: t0.advanced(by: .seconds(1))))
    }

    /// Y el número elegido tiene que caber en el presupuesto medido del relé **dejando sitio al
    /// teclado**, que es la razón entera de que no sea 60.
    ///
    /// La cuenta: 120 mensajes por segundo es el tope del visor; un mecanógrafo rápido hace unas
    /// 10 pulsaciones por segundo y cada una son dos mensajes (`keyDown` + `keyUp`), o sea ~20;
    /// arrastrar y teclear a la vez es el peor caso humano. Con el arrastre quedándose como
    /// mucho con la mitad del presupuesto, las dos cosas juntas no lo agotan nunca.
    ///
    /// 🔴 LAS COTAS VAN SOBRE `intervaloDeMuestreo`, QUE ES LO QUE PRODUCCIÓN LEE (H2 de la
    /// revisión de rama). Esta prueba medía antes **solo** `muestrasPorSegundo`, que ningún
    /// código de producción consumía: bajar el intervalo de verdad a 1 ms (8,3× el presupuesto
    /// del relé) la dejaba verde, y mover la constante muerta la ponía roja. Medía el número
    /// decorativo y no el que manda. Ahora el intervalo se deriva de `muestrasPorSegundo`, y
    /// aquí se fijan las dos cosas: las cotas sobre el intervalo y la relación entre los dos,
    /// para que `muestrasPorSegundo` no vuelva a quedarse huérfana.
    func test_el_muestreo_elegido_deja_sitio_al_teclado_en_el_presupuesto_del_rele() {
        XCTAssertEqual(Entrada.topeDeEntradasPorSegundoDelRele, 120,
                       "es la constante medida del relé (`MAX_ENTRADAS_POR_VENTANA`); si cambia allí, cambia aquí")
        let mitadDelPresupuesto = Entrada.topeDeEntradasPorSegundoDelRele / 2
        XCTAssertGreaterThanOrEqual(Entrada.intervaloDeMuestreo * mitadDelPresupuesto, .seconds(1),
                                    "el arrastre se queda con más de la mitad del presupuesto del visor: "
                                    + "lo que pase del tope el relé lo tira EN SILENCIO y la página deja de responder")
        XCTAssertLessThanOrEqual(Entrada.intervaloDeMuestreo * 25, .seconds(1),
                                 "por debajo del ritmo del stream (25 fps medidos) el arrastre se vería a saltos")
        XCTAssertEqual(Entrada.intervaloDeMuestreo, .seconds(1) / Entrada.muestrasPorSegundo,
                       "el intervalo ya no sale de `muestrasPorSegundo`: una de las dos es decorativa otra vez")
    }

    // MARK: el anillo del puntero del usuario

    /// **EL ANILLO MARCA ÚNICAMENTE EL ÚLTIMO PUNTO QUE PRODUJO UN MENSAJE DE ENTRADA, Y SOLO
    /// MIENTRAS ESE PUNTO SIGA SIENDO MANDABLE.**
    ///
    /// POR QUÉ ESTA SEÑAL EXISTE. La página remota **no dibuja cursor** y por el cable no viaja
    /// ninguno: lo único que el usuario ve es el JPEG del stream. Sin el anillo, un toque que
    /// cayó dos píxeles al lado del campo de la contraseña es indistinguible de un toque que no
    /// se mandó, y el usuario no tiene forma de saber cuál de los dos pasó.
    ///
    /// LO QUE EL ANILLO NO DICE, DICHO POR DELANTE: no dice «la página lo recibió». No se puede
    /// decir — el booleano del envío (que `BrowserMandoEnvio.encola` ya no tira desde la ronda 6)
    /// significa «el mensaje salió del aparato», no «la página lo aplicó». Un acuse por punto
    /// sería un dato nuevo en el cable. El anillo dice exactamente «de aquí salió entrada», que
    /// es lo máximo que este lado sabe.
    ///
    /// Y EL PUNTERO DEL AGENTE NO SE DIBUJA, que es la otra mitad de esta propiedad: el agente
    /// no pulsa por coordenada (`BrowserClickTool` corre `["click", selector]` con una
    /// referencia `@eN` o un selector CSS) y la narración que llega por el relé es
    /// `case narration(String)` y nada más, así que **no hay ningún punto que dibujar**.
    /// Inventarlo sería pintar un cursor que no corresponde a nada, que es peor que no pintar.
    func test_el_puntero_es_nil_antes_del_primer_toque() {
        XCTAssertNil(Entrada.puntero(ultimoPunto: nil, capturar: true, sePuedeApuntar: true),
                     "sin ningún toque todavía no hay nada que marcar")
    }

    /// El caso de acierto, con las cifras a mano: sin él, una función que devolviera `nil` para
    /// todo pasaría las cuatro pruebas de «no se dibuja» de abajo.
    func test_el_puntero_sale_del_ultimo_punto_tocado() {
        XCTAssertEqual(Entrada.puntero(ultimoPunto: CGPoint(x: 37, y: 91),
                                       capturar: true,
                                       sePuedeApuntar: true),
                       CGPoint(x: 37, y: 91),
                       "el anillo va donde cayó el dedo, en coordenadas de la vista")
    }

    /// Con el volante del agente **no se dibuja nada**, ni siquiera el anillo que el usuario
    /// dejó en su turno anterior.
    ///
    /// Es la prueba que cierra el caso que esta tarea **no** puede hacer: un anillo visible
    /// mientras conduce el agente sería un cursor que nadie mueve —el usuario lo leería como la
    /// posición del agente— y la posición del agente no viaja por el cable. Un puntero
    /// inventado miente más que la ausencia de puntero.
    func test_con_el_volante_del_agente_no_se_dibuja_nada() {
        XCTAssertNil(Entrada.puntero(ultimoPunto: CGPoint(x: 37, y: 91),
                                     capturar: false,
                                     sePuedeApuntar: true),
                     "con el volante del agente el anillo del turno anterior no se queda puesto")
        XCTAssertNil(Entrada.puntero(ultimoPunto: nil, capturar: false, sePuedeApuntar: true))
    }

    /// Si las dimensiones del cable desaparecen **después** del toque, el anillo viejo se va.
    ///
    /// Es una transición de verdad, no un caso de borde: el fotograma siguiente puede llegar sin
    /// `metadata`. Dejar el anillo puesto señalaría un sitio al que ya no se puede mandar nada,
    /// y el usuario vería el aviso de «este fotograma no se puede situar» junto a una marca que
    /// dice lo contrario.
    func test_sin_poder_apuntar_el_anillo_viejo_desaparece() {
        XCTAssertNil(Entrada.puntero(ultimoPunto: CGPoint(x: 37, y: 91),
                                     capturar: true,
                                     sePuedeApuntar: false),
                     "sin poder situar el fotograma el anillo señalaría un sitio al que no se manda nada")
    }

    /// Las dos puertas cerradas a la vez. Entre esta prueba y las tres de arriba quedan fijadas
    /// las **cuatro** combinaciones, que es lo que distingue un `&&` de un `||`: con `||` este
    /// caso seguiría dando `nil` pero los dos de arriba devolverían el punto.
    func test_el_puntero_no_se_dibuja_con_las_dos_puertas_cerradas() {
        XCTAssertNil(Entrada.puntero(ultimoPunto: CGPoint(x: 37, y: 91),
                                     capturar: false,
                                     sePuedeApuntar: false))
    }

    // MARK: el teclado

    /// Una tecla nueva manda `keyDown` y `keyUp` con su texto, en ese orden.
    func test_una_tecla_nueva_manda_keydown_y_keyup_con_su_texto() {
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "", nuevo: "a"),
                       [#"{"eventType":"keyDown","key":"a","text":"a","type":"input_keyboard"}"#,
                        #"{"eventType":"keyUp","key":"a","text":"a","type":"input_keyboard"}"#])
    }

    /// Borrar manda `Backspace`, una vez por carácter borrado, y sin `text`: la tecla de borrar
    /// no inserta nada.
    func test_borrar_manda_backspace_una_vez_por_caracter() {
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "ab", nuevo: "a"),
                       [#"{"eventType":"keyDown","key":"Backspace","text":"","type":"input_keyboard"}"#,
                        #"{"eventType":"keyUp","key":"Backspace","text":"","type":"input_keyboard"}"#])
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "abc", nuevo: "").count, 6,
                       "tres caracteres borrados son tres pulsaciones de Backspace")
    }

    /// Sin cambio no se manda nada. Importa porque `onChange` de SwiftUI se dispara por motivos
    /// que no son una tecla nueva, y un mensaje por cada evaluación de la vista sería una
    /// inundación del presupuesto de caudal.
    func test_sin_cambio_no_se_manda_nada() {
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "hola", nuevo: "hola"), [])
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "", nuevo: ""), [])
    }

    /// Un cambio en medio se manda como lo que es: borrar hasta el prefijo común y escribir el
    /// resto. Es el caso del autocorrector y del pegado sobre una selección.
    func test_un_cambio_en_medio_borra_hasta_el_prefijo_comun_y_escribe_el_resto() {
        // "roi" → "rob": prefijo común "ro", se borra la "i" y se escribe la "b".
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "roi", nuevo: "rob"),
                       [#"{"eventType":"keyDown","key":"Backspace","text":"","type":"input_keyboard"}"#,
                        #"{"eventType":"keyUp","key":"Backspace","text":"","type":"input_keyboard"}"#,
                        #"{"eventType":"keyDown","key":"b","text":"b","type":"input_keyboard"}"#,
                        #"{"eventType":"keyUp","key":"b","text":"b","type":"input_keyboard"}"#])
    }

    /// Un pegado largo se trocea en **una tecla por carácter**.
    ///
    /// ANTES ESTA PRUEBA AFIRMABA ADEMÁS QUE «cada mensaje cabe en el tope», Y ESA MITAD ERA
    /// VACUA: un mensaje de tecla mide ~84 bytes y el tope de tamaño del relé es 4096
    /// (`MAX_MENSAJE_VISOR`, `relay.py:641`), así que la aserción preguntaba si 84 cabe en 4096.
    /// Peor: **se cumplía con la característica borrada** — si `mensajesDeTeclado` dejara de
    /// trocear y mandara el pegado entero en un solo mensaje, ése mediría ~580 bytes y pasaría el
    /// bucle igual. Haría falta un pegado de más de 4000 caracteres para que llegara a ligar.
    ///
    /// Y el nombre prometía de más: **el tope que de verdad se come la contraseña no es el de
    /// tamaño, es el de CAUDAL**, y de ése se encarga
    /// `test_el_pegado_se_reparte_en_el_tiempo_para_que_no_se_coma_su_propia_cola`.
    func test_un_pegado_largo_se_trocea_en_una_tecla_por_caracter() {
        let largo = String(repeating: "x", count: 500)
        let mensajes = Entrada.mensajesDeTeclado(anterior: "", nuevo: largo)
        XCTAssertEqual(mensajes.count, 1000, "dos mensajes por carácter")
        // El tope de TAMAÑO se sigue afirmando, pero sobre el caso que de verdad liga: un
        // carácter cuyo JSON es grande. Un emoji compuesto con escape `\u` en el JSON es lo más
        // caro que una sola tecla puede producir, y aun así tiene que caber.
        let caro = Entrada.mensajesDeTeclado(anterior: "", nuevo: "👨‍👩‍👧‍👦")
        XCTAssertFalse(caro.isEmpty)
        for m in caro {
            XCTAssertTrue(BrowserInputEvents.cabeEnElTope(m),
                          "ni la tecla más cara puede pasar el tope de tamaño: \(m.utf8.count) bytes")
        }
    }

    /// **EL PEGADO SE REPARTE EN EL TIEMPO PARA QUE NO SE COMA SU PROPIA COLA.**
    ///
    /// Es el arreglo del hallazgo que más le costaba al usuario. Sin reparto, los 2N mensajes de
    /// un pegado caen en la misma ventana de un segundo y el relé descarta el resto **en
    /// silencio**. Umbrales medidos reimplementando el algoritmo del relé: 60 caracteres un
    /// pegado solo, **45** con un arrastre en el mismo segundo, y **30** cuando AutoFill
    /// sustituye lo que ya había (4 mensajes por carácter). El usuario pega su contraseña, llegan
    /// 30 caracteres, y el acceso falla sin un solo error.
    ///
    /// Se mide la propiedad, no el reloj: la espera es inyectable y la prueba **apunta cuánto se
    /// esperó**. Tres mensajes ⇒ dos esperas, porque antes del primero no se espera (un clic no
    /// se retrasa).
    @MainActor func test_el_pegado_se_reparte_en_el_tiempo_para_que_no_se_coma_su_propia_cola() async {
        let mando = MandoDeMentira()
        let esperas = Esperas()
        let cola = BrowserMandoEnvio.encola(["a", "b", "c"], por: mando, tras: nil,
                                            espera: { d in esperas.anota(d) }, alFallar: {})
        await cola?.value

        XCTAssertEqual(mando.entradas, ["a", "b", "c"], "los tres mensajes salen, y en orden")
        XCTAssertEqual(esperas.anotadas, [Entrada.intervaloEntreTeclas, Entrada.intervaloEntreTeclas],
                       "una espera entre mensajes consecutivos, y ninguna antes del primero")
    }

    /// Y el intervalo elegido tiene que caber en el presupuesto del relé **por los dos lados**.
    ///
    /// Por arriba: la mitad del tope (60 mensajes/s) es la misma regla que gobierna
    /// `muestrasPorSegundo`, así que el intervalo no puede ser más corto que 1 s / 60.
    /// Por abajo: una contraseña de 20 caracteres (40 mensajes, 39 esperas) tiene que entrar en
    /// **menos de un segundo**, o el reparto deja de ser imperceptible y se convierte en otro
    /// problema.
    func test_el_reparto_del_teclado_cabe_en_el_presupuesto_y_sigue_siendo_imperceptible() {
        let mitadDelPresupuesto = Entrada.topeDeEntradasPorSegundoDelRele / 2
        XCTAssertGreaterThanOrEqual(Entrada.intervaloEntreTeclas * mitadDelPresupuesto, .seconds(1),
                                    "el teclado se pasaría de su mitad del presupuesto del relé")
        XCTAssertLessThanOrEqual(Entrada.intervaloEntreTeclas * 39, .seconds(1),
                                 "una contraseña de 20 caracteres tardaría más de un segundo en entrar")
    }

    /// **LA CONTRASEÑA EN VUELO SE CORTA AL PERDER EL VOLANTE.**
    ///
    /// La cola captura las pulsaciones **ya codificadas**, y con el reparto en el tiempo la
    /// ventana en que siguen saliendo pasa de milisegundos a segundos. Hoy el relé las tiraría
    /// por portador, pero hay un camino estrecho en el que el volante vuelve a ser suyo antes de
    /// que la cola acabe y la cola vieja escribe en la página con un retraso que nadie espera.
    ///
    /// Se mide el ciclo entero: sale el primero, se cancela, **no sale el resto**. Afirmar solo
    /// que no salen pasaría con una cola que no manda nada.
    @MainActor func test_cancelar_la_cola_corta_la_contrasena_en_vuelo() async {
        let mando = MandoDeMentira()
        let puerta = Puerta()
        let cola = BrowserMandoEnvio.encola(["1", "2", "3", "4"], por: mando, tras: nil,
                                            espera: { _ in await puerta.espera() }, alFallar: {})
        // El primero sale sin esperar: eso es lo que prueba que la cola de verdad manda.
        let alguienLlegoALaPuerta = await puerta.esperaQueAlguienEntre()
        XCTAssertTrue(alguienLlegoALaPuerta,
                      "nadie esperó entre dos mensajes: la cola no reparte en el tiempo")
        XCTAssertEqual(mando.entradas, ["1"], "el primer mensaje tiene que haber salido ya")

        cola?.cancel()
        puerta.abre()
        await cola?.value
        XCTAssertEqual(mando.entradas, ["1"], "la cola cancelada siguió mandando la contraseña")
    }

    /// El botón pide el volante y lo devuelve **de verdad**, por el camino que usa la vista.
    ///
    /// Antes nada leía los contadores del doble: `grep` de `.tomas`/`.devoluciones`/`.entradas` en
    /// todo el target daba **cero**, así que cablear el botón al revés —devolver cuando hay que
    /// tomar— habría dejado la suite verde. El comentario del protocolo decía que el camino de la
    /// contraseña «se puede medir entero sin red»; se podía, y no se medía.
    @MainActor func test_el_boton_pide_el_volante_y_lo_devuelve_de_verdad() async {
        XCTAssertEqual(Entrada.accionDelBoton(quienConduce: .agente), .toma)
        XCTAssertEqual(Entrada.accionDelBoton(quienConduce: .yo), .devuelve)
        XCTAssertNil(Entrada.accionDelBoton(quienConduce: .otroVisor),
                     "con otro visor al volante no hay nada que pulsar: el servidor lo rechaza en silencio")

        let mando = MandoDeMentira()
        await BrowserMandoEnvio.ejecuta(.toma, por: mando)
        XCTAssertEqual(mando.tomas, 1)
        XCTAssertEqual(mando.devoluciones, 0, "tomar no devuelve")
        await BrowserMandoEnvio.ejecuta(.devuelve, por: mando)
        XCTAssertEqual(mando.devoluciones, 1)
        XCTAssertEqual(mando.tomas, 1, "devolver no vuelve a tomar")
    }

    /// Y el booleano que devuelve **no se tira**: es lo que baja el «pidiendo…» en el momento en
    /// vez de dejar al usuario mirando un botón inerte los seis segundos de la caducidad.
    @MainActor func test_el_envio_dice_si_el_mensaje_salio_del_aparato() async {
        let conSocketCaido = await BrowserMandoEnvio.ejecuta(.toma, por: MandoDeMentira(salida: false))
        XCTAssertFalse(conSocketCaido, "con el socket caído el cliente YA SABE que no salió")
        let conSocketSano = await BrowserMandoEnvio.ejecuta(.toma, por: MandoDeMentira())
        XCTAssertTrue(conSocketSano)
    }

    /// Una espera observable: apunta las duraciones que le piden, en vez de dormirlas.
    private final class Esperas: @unchecked Sendable {
        private let candado = NSLock()
        private var _anotadas: [Duration] = []
        var anotadas: [Duration] { candado.withLock { _anotadas } }
        func anota(_ d: Duration) { candado.withLock { _anotadas.append(d) } }
    }

    /// Una espera que no vuelve hasta que la prueba la abre, para poder cancelar la cola **a
    /// mitad** de un envío y no antes de empezarlo.
    private final class Puerta: @unchecked Sendable {
        private let candado = NSLock()
        private var abierta = false
        private var entraron = 0

        func abre() { candado.withLock { abierta = true } }

        func espera() async {
            candado.withLock { entraron += 1 }
            while !candado.withLock({ abierta }) {
                await Task.yield()
            }
        }

        /// Vuelve cuando alguien ha llegado a la puerta, o sea cuando el mensaje anterior ya
        /// salió. Sin esto la prueba cancelaría antes de que la cola hubiera mandado nada y el
        /// «no salió el resto» pasaría por el motivo equivocado.
        ///
        /// **LA ESPERA ESTÁ ACOTADA A PROPÓSITO, Y SE MIDIÓ POR QUÉ.** Una espera sin tope
        /// cuelga la suite entera cuando `encola` deja de esperar entre mensajes: nadie llega
        /// nunca a la puerta y este bucle gira para siempre. Pasó de verdad —la mutación que
        /// quita el reparto en el tiempo dejó un `xcodebuild` 23 minutos sin escribir una línea,
        /// y un cuelgue **no es un rojo**: en integración continua se lee como un trabajo
        /// atascado, no como una prueba que falla—. Con el tope, el mismo caso da un fallo con
        /// su frase. El devuelto se afirma en la prueba; no se ignora.
        @discardableResult
        func esperaQueAlguienEntre(vueltas: Int = 100_000) async -> Bool {
            for _ in 0..<vueltas {
                if candado.withLock({ entraron }) > 0 { return true }
                await Task.yield()
            }
            return false
        }
    }

    /// El salto de línea se manda como la tecla `Enter`, no como un carácter `\n`: es lo que
    /// envía un formulario, y es la tecla que el usuario necesita para entrar en su cuenta.
    func test_el_salto_de_linea_se_manda_como_la_tecla_Enter() {
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "", nuevo: "\n"),
                       [#"{"eventType":"keyDown","key":"Enter","text":"\r","type":"input_keyboard"}"#,
                        #"{"eventType":"keyUp","key":"Enter","text":"\r","type":"input_keyboard"}"#])
    }

    /// Una letra con tilde o una `ñ` es **una** pulsación, no dos. Se trocea por caracteres de
    /// Swift (grafemas) y no por escalares Unicode: `"é"` compuesta son dos escalares y un solo
    /// grafema, y mandarla como dos teclas escribiría basura en la contraseña del usuario.
    func test_una_letra_con_tilde_es_una_sola_pulsacion() {
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "", nuevo: "ñ").count, 2)
        let compuesta = "e\u{0301}"   // "é" como `e` + acento combinante: 2 escalares, 1 grafema
        XCTAssertEqual(compuesta.unicodeScalars.count, 2, "el literal de la prueba es el compuesto")
        XCTAssertEqual(Entrada.mensajesDeTeclado(anterior: "", nuevo: compuesta).count, 2,
                       "un grafema es una tecla; dos escalares no son dos teclas")
    }

    // MARK: cuando el panel se ve bien y aun así ningún toque se puede mandar

    /// Existe un camino en el que el panel se ve **perfectamente** y ningún toque se manda: sin
    /// dimensiones del cable, o con una imagen que no es el viewport escalado. Si eso pasa, el
    /// usuario tiene que poder saberlo — **no se le deja mudo**, porque «toco y no pasa nada» es
    /// indistinguible de media docena de fallos distintos y lo mandaría a buscar el problema en
    /// la red cuando está en el cable.
    ///
    /// El aviso solo sale cuando el volante es SUYO: decírselo mientras conduce el agente sería
    /// ruido sobre algo que no puede hacer de todas formas.
    func test_si_no_se_puede_apuntar_la_vista_lo_dice_y_solo_cuando_el_volante_es_suyo() {
        XCTAssertTrue(Entrada.sePuedeApuntar(tamañoDeLaVista: imagenMedida,
                                             tamañoDeLaImagen: imagenMedida,
                                             dimensionesDelCable: cableMedido),
                      "con las dimensiones medidas sí se puede apuntar; sin este caso el resto pasaría con `false` constante")
        XCTAssertFalse(Entrada.sePuedeApuntar(tamañoDeLaVista: imagenMedida,
                                              tamañoDeLaImagen: imagenMedida,
                                              dimensionesDelCable: nil))

        XCTAssertEqual(BrowserPanelView.avisoDeApuntado(quienConduce: .yo, sePuedeApuntar: false, entradaPerdida: false),
                       "Tienes el volante y puedes escribir, pero este fotograma no se puede situar: ningún toque se mandará.")
        XCTAssertNil(BrowserPanelView.avisoDeApuntado(quienConduce: .yo, sePuedeApuntar: true, entradaPerdida: false))
        XCTAssertNil(BrowserPanelView.avisoDeApuntado(quienConduce: .agente, sePuedeApuntar: false, entradaPerdida: false))
        XCTAssertNil(BrowserPanelView.avisoDeApuntado(quienConduce: .otroVisor, sePuedeApuntar: false, entradaPerdida: false))
    }

    // MARK: el viewport, del cable al panel

    /// El fotograma trae el viewport, y **no cruzado**: las dos cifras son distintas a propósito
    /// en esta prueba, porque con 1280×1280 un intercambio de ancho y alto pasaría inadvertido y
    /// mapearía todos los toques del usuario a lo largo del eje equivocado.
    func test_el_fotograma_del_cable_trae_el_viewport_y_no_cruzado() throws {
        let texto = #"{"type":"frame","seq":1,"jpeg":"","captured_at":1,"viewport_width":1280,"viewport_height":720}"#
        guard case .frame(_, _, _, let viewport) = try XCTUnwrap(BrowserRelayClient.decode(texto))
        else { return XCTFail("no decodificó un fotograma") }
        XCTAssertEqual(viewport?.anchoDelViewport, 1280)
        XCTAssertEqual(viewport?.altoDelViewport, 720)
    }

    /// Un fotograma **sin** viewport sigue llegando —el JPEG es lo importante— y las dimensiones
    /// van **ausentes, no inventadas**. Hoy es el caso normal: un servidor sin desplegar no las
    /// manda. Y un lado solo tampoco vale: media proporción no deshace ninguna escala.
    func test_un_fotograma_sin_viewport_o_con_medio_viewport_llega_sin_dimensiones() throws {
        let casos = [
            ("sin ninguno", #"{"type":"frame","seq":1,"jpeg":"","captured_at":1}"#),
            ("solo el ancho", #"{"type":"frame","seq":1,"jpeg":"","captured_at":1,"viewport_width":1280}"#),
            ("solo el alto", #"{"type":"frame","seq":1,"jpeg":"","captured_at":1,"viewport_height":720}"#),
            ("no numérico", #"{"type":"frame","seq":1,"jpeg":"","captured_at":1,"viewport_width":"1280","viewport_height":"720"}"#),
        ]
        for (nombre, texto) in casos {
            guard case .frame(let seq, _, _, let viewport) = try XCTUnwrap(BrowserRelayClient.decode(texto))
            else { return XCTFail("el fotograma tiene que llegar igual (\(nombre))") }
            XCTAssertEqual(seq, 1, "el fotograma llega entero aunque falten las dimensiones (\(nombre))")
            XCTAssertNil(viewport, "dimensiones inventadas con \(nombre)")
        }
    }

    /// Un viewport absurdo (cero, negativo) **pasa el decodificador** y lo rechaza el mapa. No
    /// hay un segundo guarda en el decodificador a propósito: sería una condición que ninguna
    /// prueba podría matar por separado, y la duplicada es la que se olvida de actualizar. Esta
    /// prueba fija DÓNDE vive el guarda, para que nadie lo añada dos veces.
    func test_un_viewport_absurdo_lo_rechaza_el_mapa_y_no_el_decodificador() throws {
        let texto = #"{"type":"frame","seq":1,"jpeg":"","captured_at":1,"viewport_width":0,"viewport_height":0}"#
        guard case .frame(_, _, _, let viewport) = try XCTUnwrap(BrowserRelayClient.decode(texto))
        else { return XCTFail("no decodificó un fotograma") }
        XCTAssertEqual(viewport?.anchoDelViewport, 0, "el decodificador no juzga: transporta")
        XCTAssertEqual(Entrada.mensajesDePuntero(fase: .pulsa, punto: .zero, ultimaPagina: nil,
                                                 tamañoDeLaVista: imagenMedida,
                                                 tamañoDeLaImagen: imagenMedida,
                                                 dimensionesDelCable: viewport).mensajes, [],
                       "el mapa es quien tiene que callarse con un viewport absurdo")
    }

    /// El panel guarda las dimensiones del fotograma y **las suelta con la imagen**.
    ///
    /// EL INVARIANTE: si las dimensiones sobrevivieran al fotograma que describen, el toque
    /// siguiente se mapearía contra el viewport de una imagen que ya no está en pantalla. Se
    /// recorre el ciclo entero: llegan, están, y se van por los tres caminos.
    // Puerta de plataforma con el motivo medido arriba: el test host de iOS aborta al instanciar
    // `BrowserPanelState`/`BrowserPanelCoordinator` (preexistente, ver el bloque largo).
    #if os(macOS)
    @MainActor func test_el_panel_guarda_el_viewport_del_fotograma_y_lo_suelta_con_la_imagen() {
        let medido = cableMedido
        func conFotograma() -> BrowserPanelState {
            let s = BrowserPanelState()
            s.apply(.frame(seq: 1, jpeg: Data([0xFF, 0xD8]), capturedAt: .now, viewport: medido))
            XCTAssertEqual(s.dimensionesDelCable, medido, "el fotograma trae el viewport al panel")
            return s
        }

        // (a) un fotograma SIN dimensiones borra las del anterior: dejarlas puestas mapearía el
        // toque siguiente contra una imagen vieja, en silencio y con el panel pintando bien.
        let s1 = conFotograma()
        s1.apply(.frame(seq: 2, jpeg: Data([0xFF, 0xD9]), capturedAt: .now, viewport: nil))
        XCTAssertNil(s1.dimensionesDelCable)

        // (b) al plegar se suelta el JPEG, así que se sueltan también.
        let s2 = conFotograma()
        s2.apply(.state(live: true, collapsed: true))
        XCTAssertNil(s2.jpeg)
        XCTAssertNil(s2.dimensionesDelCable)

        // (c) y al congelar.
        let s3 = conFotograma()
        s3.freeze()
        XCTAssertNil(s3.jpeg)
        XCTAssertNil(s3.dimensionesDelCable)
    }
    #endif

    // MARK: el cableado del mando, y el ciclo de vida del socket

    /// El coordinador entrega al panel **el mando de su propio flujo**. Antes de esto nadie
    /// tenía una referencia viva al cliente del relé: `makeRelayStream` lo construía dentro y la
    /// única referencia que quedaba era la de su `onTermination`, así que la vista no tenía a
    /// quién pedirle el volante.
    // Puerta de plataforma con el motivo medido arriba: el test host de iOS aborta al instanciar
    // `BrowserPanelState`/`BrowserPanelCoordinator` (preexistente, ver el bloque largo).
    #if os(macOS)
    @MainActor func test_el_coordinador_entrega_el_mando_del_panel_que_abrio() throws {
        let mando = MandoDeMentira()
        let c = BrowserPanelCoordinator(stream: { (AsyncStream { _ in }, mando) })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        let entregado = try XCTUnwrap(c.mando(de: id))
        XCTAssertTrue(entregado as AnyObject === mando,
                      "el panel tiene que recibir el mando de SU flujo, no otro")
    }
    #endif

    /// Sin flujo no hay panel, y por tanto no hay mando que entregar. Es el caso del relé sin
    /// configurar, que es con el que arranca la app.
    // Puerta de plataforma con el motivo medido arriba: el test host de iOS aborta al instanciar
    // `BrowserPanelState`/`BrowserPanelCoordinator` (preexistente, ver el bloque largo).
    #if os(macOS)
    @MainActor func test_sin_flujo_no_hay_panel_ni_mando() {
        let c = BrowserPanelCoordinator(stream: { nil })
        XCTAssertNil(c.openIfNeeded(toolName: "browser_open"))
        XCTAssertNil(c.mando(de: "cualquiera"))
    }
    #endif

    /// **EL CICLO DE VIDA DEL SOCKET NO SE ROMPE AL CABLEAR.** Si al guardar el mando en el
    /// coordinador el cliente del relé dejara de liberarse al retirar el panel, se habría
    /// cambiado el ciclo de vida del socket — un fallo mayor que el que se arreglaba, porque el
    /// visor cuesta del orden de 10 Mbit/s contra el servidor casero mientras dure y los paneles
    /// se quedan en el historial del chat para siempre.
    ///
    /// Se mide con una referencia **débil**: el panel sigue en `panels` (es historial), pero su
    /// mando tiene que haberse soltado. Un panel congelado no puede conducir de todas formas
    /// (`freeze()` devuelve el volante al agente).
    // Puerta de plataforma con el motivo medido arriba: el test host de iOS aborta al instanciar
    // `BrowserPanelState`/`BrowserPanelCoordinator` (preexistente, ver el bloque largo).
    #if os(macOS)
    @MainActor func test_al_retirar_el_panel_el_mando_se_suelta_de_verdad() {
        weak var debil: MandoDeMentira?
        let c = BrowserPanelCoordinator(stream: {
            let m = MandoDeMentira()
            debil = m
            return (AsyncStream { _ in }, m)
        })
        let id = c.openIfNeeded(toolName: "browser_open")!
        XCTAssertNotNil(debil, "el doble existe mientras el panel está vivo")
        XCTAssertNotNil(c.mando(de: id))

        c.endTurn(survive: false, porque: "la prueba del ciclo de vida")
        XCTAssertNil(c.mando(de: id), "el panel retirado ya no tiene mando")
        XCTAssertNotNil(c.panels[id], "el panel sigue en el historial del chat")
        XCTAssertNil(debil, "el cliente del relé no se liberó: el socket se queda abierto")
    }
    #endif

    /// `makeRelayStream` devuelve algo **solo** con una URL de navegador configurada.
    ///
    /// LO QUE ESTA PRUEBA MIDE Y LO QUE NO, DICHO POR DELANTE. La presencia del mando en el par
    /// **la impone el sistema de tipos**, no esta prueba: `VisorDelRele` es
    /// `(flujo:, mando: MandoDelNavegador)` con el mando **no opcional**, así que `par?.mando` es
    /// `nil` si y solo si `par` es `nil`, y no existe mutación que quite el mando dejando el
    /// flujo — el fichero no compilaría. Antes esta prueba afirmaba `XCTAssertNotNil(par?.mando)`
    /// con el mensaje «el mando viene con él», que se leía como una medición y era una
    /// tautología; por eso M30 la mataba por el motivo equivocado.
    ///
    /// Lo que sí mide, y es lo único que hay que medir aquí, es la **puerta de la configuración**:
    /// sin URL no hay visor, con URL sí. (Que el par llegue al panel lo miden
    /// `test_el_coordinador_entrega_el_mando_del_panel_que_abrio` y
    /// `test_al_retirar_el_panel_el_mando_se_suelta_de_verdad`, que sí son mediciones.)
    @MainActor func test_makeRelayStream_solo_devuelve_visor_con_la_url_configurada() {
        let defaults = UserDefaults(suiteName: "mando-subsistema-b-\(UUID().uuidString)")!
        XCTAssertNil(HarnessModel.makeRelayStream(defaults: defaults, almacen: AlmacenEnMemoria()), "sin URL no hay visor")

        defaults.set("http://192.0.2.1:8083", forKey: SettingsKeys.browserBaseURL)
        XCTAssertNotNil(HarnessModel.makeRelayStream(defaults: defaults, almacen: AlmacenEnMemoria()), "con URL válida sí hay visor")
        // El flujo NO se consume: abrirlo levantaría el socket contra una dirección de prueba.
    }

    // MARK: la tecla y el registro

    /// **NINGUNA RUTA DEL MANDO DE LA VISTA PASA LA TECLA A UN REGISTRO.** Lista **blanca** de
    /// identificadores, coincidencia exacta.
    ///
    /// POR QUÉ BLANCA Y NO NEGRA. Una lista negra solo prueba que no está lo que a uno se le
    /// ocurrió nombrar, y en este proyecto ya se midió el agujero: `UserDefaults.standard.set`,
    /// un acumulador `static var` y el `userInfo` de `NotificationCenter` pasaban **verdes** por
    /// una lista de palabras prohibidas. Lo que viaja por este fichero puede ser la contraseña
    /// del usuario, y no se registra ni el contenido ni **una línea por pulsación sin
    /// contenido**: una traza por tecla revela cuántas tiene la contraseña y con qué ritmo se
    /// escribió, legible por cualquier proceso con permiso en el log unificado de macOS.
    ///
    /// EL PRECIO, dicho por delante y aceptado: el día que este fichero gane una API legítima,
    /// esta prueba se pondrá roja y habrá que mirar lo que se añadió y meterlo en la lista a
    /// mano. Es ruido visible en vez de silencio.
    func test_el_mando_de_la_vista_solo_usa_identificadores_permitidos() throws {
        let fuente = try fuenteDeProduccion("Gemma/Harness/BrowserMando.swift")

        // Guarda de vacuidad 1: que la ruta apunte al fichero de verdad. Todas las aserciones de
        // esta prueba son AUSENCIAS y pasarían solas con el fichero vacío o la ruta mal.
        //
        // **Sobre el fuente TROCEADO**: el guarda es una PRESENCIA, y una presencia sobre el
        // crudo se cumple con la declaración envuelta en `/* */` —característica borrada, texto
        // conservado—. Un guarda de vacuidad que pasa con el fichero comentado no guarda nada.
        for ancla in ["enum BrowserMandoEntrada", "func mensajesDeTeclado", "protocol MandoDelNavegador"] {
            XCTAssertTrue(TroceadoDeFuente.sinComentarios(fuente).contains(ancla),
                          "la ruta del fuente ya no apunta al fichero de producción: falta \(ancla)")
        }

        let usados = TroceadoDeFuente.identificadores(de: fuente)

        // Guarda de vacuidad 2: que la extracción haya extraído algo, y algo reconocible. Sin
        // esto, un fallo del troceado daría un conjunto vacío, que está contenido en cualquier
        // lista blanca, y la prueba pasaría sin haber mirado nada.
        XCTAssertTrue(usados.contains("mensajesDeTeclado"),
                      "el troceado de identificadores no funciona: no encuentra ni `mensajesDeTeclado`")
        XCTAssertGreaterThan(usados.count, 150,
                             "el troceado de identificadores devolvió \(usados.count): no ha leído el fichero")

        let deMas = usados.subtracting(Self.identificadoresPermitidos).sorted()
        XCTAssertEqual(deMas, [],
                       """
                       el mando de la vista usa identificadores que no están en la lista blanca: \(deMas).
                       Si son legítimos, añádelos a `identificadoresPermitidos` A MANO y mira dos \
                       veces que ninguno escribe, persiste, notifica ni acumula la tecla ni la \
                       coordenada: lo que pasa por aquí puede ser la contraseña del usuario.
                       """)
    }

    /// Y la entrada del usuario no se maneja en ningún otro sitio, porque la lista blanca de
    /// arriba solo vale si el fichero que vigila es **el único** camino. `BrowserPanelView` monta
    /// el mando y no toca ni una tecla ni un gesto.
    ///
    /// EL HUECO QUE ESTO DEJA, DECLARADO: comprueba que las primitivas de entrada que hoy
    /// existen no están en el panel, no que no pueda aparecer una séptima forma de leer una
    /// tecla. Lo que lo cierra de verdad es que todo el camino de la entrada viva en un solo
    /// fichero, y eso es lo que esta prueba sostiene.
    func test_el_panel_delega_toda_la_entrada_en_el_fichero_vigilado() throws {
        let panel = try fuenteDeProduccion("Gemma/Harness/BrowserPanelView.swift")
        // La PRESENCIA de la delegación va sobre el fuente troceado (sobre el crudo se cumple con
        // la línea comentada); las AUSENCIAS de abajo van sobre el crudo, que es el lado seguro
        // de un trinquete de ausencia: ahí lo que hay que impedir es que el troceado se trague
        // una línea y la primitiva vuelva en verde.
        let codigoDelPanel = TroceadoDeFuente.sinComentarios(panel)
        for delegacion in ["BrowserMandoGestos", "BrowserMandoBarra"] {
            XCTAssertTrue(codigoDelPanel.contains(delegacion),
                          "el panel ya no delega la entrada: falta \(delegacion)")
        }
        for primitiva in ["SecureField", "TextField", "DragGesture", "onKeyPress",
                          "mensajesDeTeclado", "mensajesDePuntero", "manda(entrada:"] {
            XCTAssertFalse(panel.contains(primitiva),
                           "`\(primitiva)` ha vuelto a `BrowserPanelView.swift`: la entrada tiene "
                           + "que vivir entera en el fichero que la lista blanca vigila")
        }
    }

    /// **EL CABLEADO DEL CUERPO DE LAS DOS VISTAS DEL MANDO.**
    ///
    /// POR QUÉ ESTA PRUEBA EXISTE, Y NO ES UN PARCHE. El informe de esta tarea declaró el cuerpo
    /// de un `View` como hueco irreductible (H1) y le puso como red
    /// `test_el_panel_delega_toda_la_entrada_en_el_fichero_vigilado`. Un revisor fresco midió que
    /// **esa red no atrapaba nada**, con cuatro mutaciones y cuatro supervivientes, y tenía
    /// razón por dos motivos: esa prueba lee `BrowserPanelView.swift` y las cuatro propiedades
    /// viven en `BrowserMando.swift`; y la lista blanca, que sí lee este fichero, no se entera
    /// porque `"true"` y `"capturar"` **ya están** en ella —así que `allowsHitTesting(true)` no
    /// añade ni un identificador— y porque una lista blanca jamás puede detectar texto que se
    /// **quita**.
    ///
    /// Había forma de medirlo con la técnica que este mismo fichero ya usa dos veces: afirmar la
    /// **forma del fuente**. No es una prueba falsa —no monta lo que afirma— y cada aserción de
    /// aquí tiene detrás una mutación que sin ella sobrevive, medida, no supuesta:
    ///
    ///     MA  allowsHitTesting(capturar || !capturar)      → antes VERDE
    ///     MB  quitar `tecleado = ""` del onChange          → antes VERDE
    ///     MC  el SecureField fuera del `if` de la captura  → antes VERDE
    ///     MD  quitar el guarda del Backspace               → antes VERDE
    ///
    /// EL PRECIO, dicho por delante: el día que estas dos vistas se reescriban, esta prueba se
    /// pondrá roja y habrá que mirar lo que cambió. Es ruido visible en vez de silencio, el mismo
    /// intercambio que la lista blanca.
    func test_el_cuerpo_del_mando_cablea_las_puertas_que_la_suite_no_puede_ejecutar() throws {
        // **SOBRE EL FUENTE TROCEADO**, igual que su gemela de más abajo (la del anillo), y por
        // el mismo motivo medido: todas las aserciones de esta prueba son PRESENCIAS, y una
        // presencia sobre el texto crudo **se cumple con la característica borrada**. El par
        // oculta/control está medido con la suite entera: envolver el bloque en `/* */` dejaba la
        // suite en su verde exacto con la característica fuera, y borrarlo de verdad la ponía
        // roja. Los dos recuentos exactos (`components(separatedBy:)`) también quedan sobre
        // código y no sobre prosa, que es lo que los hace recuentos.
        let crudo = try fuenteDeProduccion("Gemma/Harness/BrowserMando.swift")
        XCTAssertFalse(crudo.contains("cola?.cancel()"), "cancelar pierde los extremos del gesto")
        XCTAssertFalse(crudo.contains("@State private var cola:"), "la barra no debe tener otra cadena")
        let f = TroceadoDeFuente.sinComentarios(crudo)

        // Guarda de vacuidad: que la ruta apunte al fichero de verdad. Todas las aserciones de
        // abajo son presencias de texto y pasarían con la ruta mal si el fichero no existiera…
        // pero `fuenteDeProduccion` lanzaría; lo que esto caza es un fichero que existe y ya no
        // es el que se cree.
        for ancla in ["struct BrowserMandoGestos", "struct BrowserMandoBarra"] {
            XCTAssertTrue(f.contains(ancla), "la ruta ya no apunta al fichero del mando: falta \(ancla)")
        }

        // MA — la puerta de los gestos es `capturar`, no una constante. Si se queda abierta, el
        // usuario toca la página mientras conduce el agente (el relé lo descarta en silencio) y
        // además pierde lo que pidió textualmente: desplazar el chat con el panel a la vista.
        XCTAssertTrue(f.contains(".allowsHitTesting(capturar)"),
                      "la puerta del hit-testing ya no depende de quién conduce")

        // MC — el campo de texto solo existe cuando el volante es suyo. Fuera del `if`, el
        // teclado del teléfono se traga las teclas mientras el panel exista.
        XCTAssertTrue(f.contains("""
                    if BrowserPanelView.capturaLosGestos(quienConduce: state.quienConduce) {
                        SecureField
        """.trimmingCharacters(in: .newlines)),
                      "el SecureField ya no está dentro del `if` de la captura")

        // MB — perder el volante borra lo escrito y suelta el foco, en el MISMO cambio de estado.
        // Es el Foco de revisión 2: puede estar a medio teclear una contraseña.
        XCTAssertTrue(f.contains(".onChange(of: state.quienConduce) { _, _ in"),
                      "ya no hay nada enganchado al cambio de quién conduce")
        XCTAssertTrue(f.contains("            tecleado = \"\"\n            enfocado = false"),
                      "perder el volante ya no borra lo tecleado ni suelta el foco")

        // Ronda 8: el teclado utiliza la cadena de la sesión, sin cola propia de la barra.
        XCTAssertTrue(f.contains("sesion?.teclea(BrowserMandoEntrada.mensajesDeTeclado(anterior: anterior, nuevo: nuevo))"))
        let coordinador = TroceadoDeFuente.codigoIncondicional(
            try fuenteDeProduccion("Gemma/Harness/BrowserPanelCoordinator.swift"))
        XCTAssertTrue(coordinador.contains("sesiones[id]?.cambioElVolante()"))

        // H4 (ronda 6) — lo que no sale SE DICE, en las tres piezas que solo viven en el cuerpo:
        // el teclado de la barra apunta su fallo en la sesión, el aviso lee la sesión, y un
        // volante nuevo lo apaga. El resto del ciclo (que `encola` llame a `alFallar`, que la
        // sesión lo anote, que el aviso salga conduzca quien conduzca) se EJECUTA en
        // `BrowserMandoSesionTests`; esto es lo único que la suite no puede ejecutar.
        XCTAssertTrue(f.contains("alFallar: { [weak self] in self?.notaQueNoSalio() })"),
                      "la sesión debe anotar el fallo de entrada")
        XCTAssertTrue(f.contains("entradaPerdida: sesion?.entradaPerdida == true) {"),
                      "la barra ya no enseña el aviso de lo que no salió")
        XCTAssertTrue(f.contains("if state.quienConduce == .yo { sesion?.olvidaElFallo() }"),
                      "el aviso de lo que no salió ya no se apaga con el volante nuevo, o se apaga con cualquier cambio")

        // El botón inicia la devolución sin suspender ni crear una tarea intermedia.
        XCTAssertTrue(f.contains("""
                if accion == .devuelve, let sesion {
                    sesion.devuelve()
                    return
                }
        """.trimmingCharacters(in: .newlines)))
        // La identidad del contacto llega en ambos callbacks; SwiftUI no se ejecuta aquí.
        XCTAssertEqual(f.components(separatedBy: "contacto: valor.startLocation").count - 1, 2)

        // MD — el borrado del campo NO manda `Backspace` a la página: el número de pulsaciones
        // delataría la longitud de la contraseña.
        XCTAssertTrue(f.contains(
            "guard BrowserPanelView.capturaLosGestos(quienConduce: state.quienConduce) else { return }"),
                      "el guarda que evita mandar Backspace tras perder el volante ha desaparecido")

        // H2 — el gesto se mide dentro de un `GeometryReader` sobre la imagen, no sobre el marco.
        XCTAssertTrue(f.contains("GeometryReader { geometria in"),
                      "el gesto ya no mide la vista donde se dibuja la imagen")

        // El reparto en el tiempo y la cadena de orden se usan en los TRES sitios que mandan: el
        // gesto (`BrowserMandoSesion`, que es donde vive desde la ronda 6), su cierre defensivo
        // al retirar el panel (`retira()`), y el teclado de la barra.
        XCTAssertEqual(f.components(separatedBy: "BrowserMandoEnvio.encola(").count - 1, 3,
                       "los tres envíos del mando tienen que ir por la cola repartida, no por su propio bucle")

        // El booleano de «el mensaje salió» NO se tira: baja el «pidiendo…» en el momento en vez
        // de dejar al usuario mirando un botón inerte los seis segundos de la caducidad. La
        // llave de cierre va en el ancla a propósito: sin ella, una mutación que añadiera una
        // condición detrás (`== false, false {`) seguiría conteniendo el ancla como PREFIJO y
        // esta aserción pasaría con el código ya roto.
        XCTAssertTrue(f.contains("if await BrowserMandoEnvio.ejecuta(accion, por: mando) == false {"),
                      "el booleano de la toma se vuelve a tirar: el botón miente seis segundos")

        // Y solo la TOMA se queda «pidiendo»: devolver el volante no espera a nada, porque el
        // servidor publica el `mando` con `"agente"` y ése es el que mueve el rótulo.
        XCTAssertTrue(f.contains("if accion == .toma { pidiendoDesde = ContinuousClock.Instant.now }"),
                      "devolver el volante dejaría el botón en «pidiendo…»")
    }

    /// **EL ANILLO DEL PUNTERO, CABLEADO DE VERDAD.** La misma técnica de la prueba de arriba y
    /// por el mismo motivo (hueco H1: el cuerpo de un `View` no se puede ejecutar en esta
    /// suite), aplicada a la única señal visual que le dice al usuario dónde cayó su último
    /// toque.
    ///
    /// LA PROPIEDAD, ENTERA: *el anillo marca únicamente el último punto que produjo un mensaje
    /// de entrada encolado, y solo mientras ese punto siga siendo mandable.* Las cinco pruebas
    /// de `BrowserMandoEntrada.puntero` de más arriba cubren las dos puertas; lo que **solo** se
    /// puede ver leyendo el fuente es de dónde sale el punto que se le pasa, y ahí está el
    /// defecto que esta prueba existe para impedir:
    ///
    ///     M4  `!salida.mensajes.isEmpty` → `salida.pagina != nil`
    ///
    /// `pagina` NO significa «se mandó». Un `.mueve` cuyo punto no se puede mapear devuelve
    /// `([], ultimaPagina)` —página **no-nil** y **cero** mensajes— a propósito, para que el
    /// `.suelta` tenga dónde levantar el botón. Con `pagina` como prueba, un dedo que sale de la
    /// imagen arrastrando movería el anillo a un punto del que **no salió nada**: exactamente la
    /// mentira que esta señal existe para no contar. Y en el otro sentido, `.suelta` devuelve
    /// `pagina: nil` **siempre**, incluso cuando sí manda el `mouseReleased`.
    ///
    /// Las otras cuatro mutaciones que sin esta prueba sobreviven, medidas:
    ///
    ///     M5  la asignación sube ANTES de la puerta del muestreo (marcaría muestras tiradas)
    ///     M6  quitar `fase != .suelta` (el soltar puede mandar en el punto VIEJO)
    ///     M7  quitar `.allowsHitTesting(false)` (el anillo se tragaría los toques)
    ///     M8/M9  quitar el borrado al perder el volante o al cambiar el tamaño de la vista
    ///
    /// DESDE LA RONDA 6, M4, M5 y M6 YA NO SE MIDEN AQUÍ POR EL TEXTO: la lógica del gesto vive en
    /// `BrowserMandoSesion` y se ejecuta (ver el cuerpo de la prueba).
    ///
    /// EL PRECIO, dicho por delante y el mismo que el de la lista blanca: el día que esta vista
    /// se reescriba, esta prueba se pondrá roja y habrá que mirar lo que cambió.
    func test_el_anillo_solo_marca_el_ultimo_punto_que_produjo_un_mensaje() throws {
        let crudo = try fuenteDeProduccion("Gemma/Harness/BrowserMando.swift")

        // Guarda de vacuidad: toda aserción de texto pasa sola si la ruta no apunta al fichero
        // que uno se cree.
        //
        // **SOBRE EL FUENTE TROCEADO**, como toda PRESENCIA (Ruling 18, guardas de vacuidad
        // incluidos): sobre el crudo, este guarda se cumplía con `struct BrowserMandoGestos`
        // citado dentro de un comentario (H8 de la revisión de rama).
        //
        // **LOS COMENTARIOS SE QUITAN ANTES DE MEDIR NADA.** Una sonda de esta misma rama dio
        // verde con la asignación del anillo escrita SOLO en un comentario, que es lo mismo que
        // no estar escrita. El troceador es el de la lista blanca, reusado.
        let f = TroceadoDeFuente.sinComentarios(crudo)
        XCTAssertTrue(f.contains("struct BrowserMandoGestos"),
                      "la ruta ya no apunta al fichero del mando: falta `struct BrowserMandoGestos`")
        XCTAssertFalse(f.contains("POR QUÉ UN PROTOCOLO Y NO EL ACTOR"),
                       "el troceador de comentarios no ha quitado los comentarios: todo lo de abajo "
                       + "se podría cumplir con prosa en vez de con código")

        // --- de dónde sale el punto del anillo (M4, M5, M6) ---
        //
        // DESDE LA RONDA 6 LA DECISIÓN SE EJECUTA, NO SE LEE. La lógica del gesto salió del
        // cuerpo de la vista a `BrowserMandoSesion` (para que retirar el panel pudiera cerrar el
        // gesto antes del socket: el botón hundido), y con ella las tres cosas que esta prueba
        // afirmaba por la forma del texto pasan a medirse ejecutando: M4 (`mensajes` y no
        // `pagina`) y M5 (después de la puerta del muestreo) en
        // `test_la_sesion_solo_marca_el_anillo_cuando_sale_un_mensaje`, y M6 (el soltar no mueve
        // el anillo) **lo impone el tipo**: `levanta` no devuelve nada. Lo que queda aquí es lo
        // único que sigue viviendo en el cuerpo: que el anillo se mueva con lo que `toca`
        // devuelve, y con el punto de ESTE evento.
        XCTAssertTrue(f.contains("""
                                    if sesion?.toca(punto: valor.location, vista: geometria.size,
                                                    tamañoDeLaImagen: tamañoDeLaImagen,
                                                    dimensionesDelCable: dimensionesDelCable,
                                                    contacto: valor.startLocation) == true {
                                        ultimoPunteroDeLaVista = valor.location
                                    }
        """.trimmingCharacters(in: .newlines)),
                      "el anillo ya no se mueve solo cuando `toca` dice que salió un mensaje, o "
                      + "ya no le pasa a `toca` el tamaño de LA VISTA y las dimensiones DEL CABLE")

        // --- el anillo del cuerpo: UN bloque contiguo, del `if let` al último modificador ---
        //
        // **POR QUÉ UNO Y NO DOS, MEDIDO.** La primera versión de esta prueba partió el literal
        // en dos justo antes de los argumentos de `sePuedeApuntar`, razonando que lo que el
        // bloque único añade —que el `Circle` está dentro del `if let`— ya lo garantiza el
        // compilador, porque `donde` no existe fuera de ese alcance. Eso es cierto y es
        // **incompleto**: el bloque único también ata los TRES ARGUMENTOS de la llamada, y ésos
        // no los ata nadie, porque las sustituciones tipan. Un revisor fresco midió dos
        // mutaciones **verdes** por ese hueco:
        //
        //     MX1  `dimensionesDelCable: nil`          → `sePuedeApuntar` siempre `false`
        //                                                → EL ANILLO NO SE DIBUJA NUNCA, y las
        //                                                  cinco pruebas puras quedan inertes
        //     MX5  `tamañoDeLaVista: tamañoDeLaImagen`  → la segunda puerta se evalúa contra el
        //                                                  tamaño equivocado
        //
        // Así que el bloque vuelve a ser uno, entero, como el encargo pedía. El precio es el
        // mismo de siempre: si esta vista se reformatea, esta prueba se pone roja. Es ruido
        // visible en vez de silencio.
        XCTAssertTrue(f.contains("""
                            if let donde = BrowserMandoEntrada.puntero(
                                    ultimoPunto: ultimoPunteroDeLaVista,
                                    capturar: capturar,
                                    sePuedeApuntar: BrowserMandoEntrada.sePuedeApuntar(
                                        tamañoDeLaVista: geometria.size,
                                        tamañoDeLaImagen: tamañoDeLaImagen,
                                        dimensionesDelCable: dimensionesDelCable)) {
                                Circle()
                                    .strokeBorder(Color.orange, lineWidth: 2)
                                    .frame(width: 24, height: 24)
                                    .position(donde)
                                    .allowsHitTesting(false)
        """.trimmingCharacters(in: .newlines)),
                      "el anillo del cuerpo ya no es el que esta prueba fija. Las cuatro cosas "
                      + "que este bloque ata: que el punto sale de `BrowserMandoEntrada.puntero(`, "
                      + "que sus dos puertas son `capturar` y el apuntado del fotograma de AHORA "
                      + "—con el tamaño de LA VISTA y las dimensiones DEL CABLE, no con otra cosa—, "
                      + "que el `Circle` se coloca en ese `donde`, y que no se traga los toques")

        // NO hay aquí una aserción de que el anillo viva dentro del mismo `GeometryReader` que
        // el gesto, y es a propósito. EL MOTIVO, ESCRITO BIEN ESTA VEZ: esa aserción
        // —`f.contains("GeometryReader { geometria in")`— **se cumple con la característica
        // borrada**. Se puede quitar el anillo entero y sigue pasando, porque lo único que mide es
        // que en el fichero haya un `GeometryReader` con ese nombre de parámetro. Ésa es la
        // pregunta con la que se cazan las pruebas vacuas de este proyecto, y ésa es la razón de
        // la retirada.
        //
        // El motivo que esto tuvo escrito antes —que «esa aserción no puede fallar nunca, porque
        // sin el `GeometryReader` el fichero no compila»— es **falso**: `GeometryReader { g in`
        // compila perfectamente y la pondría roja. Infalsable no era; decorativa sí. Y es la misma
        // clase de afirmación-no-propiedad que la ronda 2 vino a desmontar en el troceado, así que
        // queda escrita aquí en vez de borrada.
        //
        // Lo que de verdad ata el anillo a ese alcance es el compilador: `geometria.size`, que el
        // bloque contiguo de arriba sí afirma, no existe fuera de él.
        //
        // Y LA GEMELA, señalada y NO tocada en esta ronda: la misma aserción decorativa vive en
        // `test_el_cuerpo_del_mando_cablea_las_puertas_que_la_suite_no_puede_ejecutar` (su «H2»,
        // más arriba en este fichero), donde se cumple igual con la característica borrada.

        // --- las dos transiciones que lo borran (M8, M9) ---
        // Y perder el volante cierra también el gesto (H3 de la ronda 6): sin `olvidaElGesto()`
        // el primer toque tras recuperarlo sería un `.mueve` y no un clic.
        XCTAssertTrue(f.contains("""
                        .onChange(of: capturar) {
                            ultimoPunteroDeLaVista = nil
                            sesion?.olvidaElGesto()
                        }
        """.trimmingCharacters(in: .newlines)),
                      "perder el volante ya no borra el anillo: quedaría un cursor que nadie mueve")
        XCTAssertTrue(f.contains(".onChange(of: geometria.size) { ultimoPunteroDeLaVista = nil }"),
                      "redimensionar la vista ya no borra el anillo: el punto está guardado en "
                      + "coordenadas de la vista y sin su tamaño de referencia ya no señala el "
                      + "mismo sitio de la imagen")

        // Exactamente esos dos borrados y ni uno más. En particular, NO se borra en `.onEnded`:
        // ahí está el único valor del anillo, porque la página remota no dibuja cursor y tras
        // levantar el dedo es la única señal de dónde cayó el toque.
        XCTAssertEqual(f.components(separatedBy: "ultimoPunteroDeLaVista = nil").count - 1, 2,
                       "hay un borrado del anillo de más: si está en `.onEnded`, el anillo "
                       + "desaparece al levantar el dedo y no señala nada")

        // --- y el guardián de esquema CERRADO, que es lo que de verdad cierra la condición 4 ---
        //
        // **POR QUÉ LOS DOS RECUENTOS DE ARRIBA NO BASTAN, MEDIDO.** Los dos miran **formas
        // previstas**: uno cuenta `= punto` y solo **dentro** del trozo de `manda`; el otro
        // cuenta `= nil` en todo el fichero. Entre los dos quedaba un carril libre —una tercera
        // asignación, con **otro lado derecho** y **fuera** de `manda`— y un revisor fresco lo
        // midió: `ultimoPunteroDeLaVista = valor.location` dentro del `.onEnded` dejaba la suite
        // **entera verde**. Y es la mentira exacta de la condición 4: el `.suelta` puede mandar
        // el `mouseReleased` cayendo al último punto BUENO cuando el actual no se puede mapear,
        // así que un dedo que sale de la imagen y se levanta fuera dibujaría el anillo **donde
        // se levantó**, que no es donde se mandó nada.
        //
        // La respuesta no es una tercera lista de formas conocidas, que tendría el mismo
        // agujero una capa más allá: es **acotar el total**. El `@State` aparece en el fichero
        // exactamente **cinco** veces —su declaración, el argumento del `overlay`, la asignación
        // del `.onChanged` (era la de `manda` hasta la ronda 6) y los dos borrados— y se le
        // asigna exactamente **tres**. El recuento del
        // identificador a secas es el que cierra de verdad, porque no se puede esquivar
        // escribiendo `ultimoPunteroDeLaVista=punto` sin el espacio.
        XCTAssertEqual(f.components(separatedBy: "ultimoPunteroDeLaVista").count - 1, 5,
                       """
                       el anillo se usa en un sitio nuevo del fichero. Los cinco sitios \
                       legítimos son: la declaración del `@State`, el argumento del `overlay`, \
                       la asignación del `.onChanged` y los dos borrados. Un sexto uso tiene \
                       que justificarse aquí: el anillo solo puede marcar el punto que produjo \
                       un mensaje, así que asignarlo en cualquier otro sitio —en el `.onEnded`, \
                       por ejemplo— lo pone donde puede no haberse mandado nada
                       """)
        XCTAssertEqual(f.components(separatedBy: "ultimoPunteroDeLaVista =").count - 1, 3,
                       "las asignaciones al anillo ya no son las tres que tienen que ser (una en "
                       + "el `.onChanged`, con lo que devuelve `toca`, y los dos borrados)")
    }

    // MARK: lectura del fuente

    private func fuenteDeProduccion(_ ruta: String) throws -> String {
        let aqui = URL(fileURLWithPath: #filePath)
        let fichero = aqui.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(ruta)
        return try String(contentsOf: fichero, encoding: .utf8)
    }

    /// Los identificadores que el fuente del mando puede contener. Son **exactamente** los que
    /// tiene hoy —la lista se generó del fichero y se revisó entrada por entrada— y ni uno más. **Ninguno escribe, persiste, notifica ni acumula nada**, que es la propiedad que
    /// esta lista existe para conservar.
    private static let identificadoresPermitidos: Set<String> = [
        // tipos, protocolos e importaciones
        "Array", "Bool", "BrowserInputEvents", "BrowserInputMapper", "BrowserMandoBarra",
        "BrowserMandoEntrada", "BrowserMandoGestos", "BrowserPanelState", "BrowserPanelView",
        "BrowserRelayClient", "CGPoint", "CGSize", "Character", "ContinuousClock", "CoreGraphics",
        "DimensionesDelCable", "Duration", "Fase", "Foundation", "Instant", "Int",
        "MandoDelNavegador", "Never", "Self", "String", "SwiftUI", "Task", "Void",
        // palabras clave de Swift y miembros del lenguaje
        "_", "async", "await", "case", "discardableResult", "else", "enum", "extension", "false",
        "for", "func", "guard", "if", "import", "in", "let", "nil", "private", "protocol",
        "public", "return", "some", "static", "struct", "switch", "to", "true", "try", "var",
        "while",
        // la API pura del mando y los nombres de sus parámetros
        "anterior", "dimensionesDelCable", "duration", "entrada", "fase", "intervaloDeMuestreo",
        "mensajes", "mensajesDePuntero", "mensajesDeTeclado", "milliseconds", "muestrasPorSegundo",
        "nuevo", "pagina", "punto", "sePuedeApuntar", "tamañoDeLaImagen", "tamañoDeLaVista",
        "tocaMuestrear", "topeDeEntradasPorSegundoDelRele", "ultimaPagina", "ultimo",
        "ahora", "mueve", "pulsa", "suelta",
        // el protocolo del volante
        "devuelveElMando", "manda", "tomaElMando", "caducidadDeLaPeticion",
        // el mapa y los codificadores que se llaman, con su vocabulario de protocolo
        "paginaDesde", "keyboard", "mouse", "tipo", "abajo", "arriba", "boton", "izquierdo",
        "movido", "pulsaciones", "pulsado", "soltado", "tecla", "texto", "Backspace", "Enter",
        "r", "n", "x", "y", "width", "height",
        // los nombres locales del cálculo y las constantes del fichero. Ninguno es un
        // acumulador: los `let` son constantes y los dos `var` (`comun`, `salida`) son locales
        // que se devuelven. No hay un solo `static var` en el fichero.
        "antes", "append", "aviso", "caracter", "centro", "clave", "claveDe", "claveDeBorrar",
        "claveDeRetorno", "cola", "comun", "count", "despues", "donde", "encola", "isEmpty",
        "mensaje", "previa", "salida", "saltoDeLinea", "textoDe", "textoDelRetorno", "valor",
        "vista", "geometria", "now", "size", "value", "sleep",
        // las dos vistas: estado propio, gestos y presentación. `State`/`FocusState` son estado
        // en memoria de la vista, que se borra en el mismo cambio que pierde el volante; no
        // persisten nada. `textContentType` y `autocorrectionDisabled` van en la dirección
        // contraria a una fuga: impiden que el sistema aprenda o sugiera lo que se teclea.
        "FocusState", "Sendable", "State", "View", "body", "capturar", "capturaLosGestos",
        "mando", "quienConduce", "state", "tecleado", "enfocado", "pidiendoDesde",
        "ultimoMuestreo", "allowsHitTesting", "autocorrectionDisabled", "contentShape",
        "focused", "gesture", "id", "location", "minimumDistance", "onChange", "onChanged",
        "onEnded", "task", "textContentType", "DragGesture", "GeometryReader", "Rectangle",
        "SecureField", "Color", "clear", "none", "of", "text",
        // presentación pura
        "Button", "HStack", "Spacer", "State", "Text", "VStack", "alignment", "avisoDeApuntado",
        "bordered", "buttonStyle", "caption", "caption2", "controlSize", "disabled",
        "elBotonActua", "font", "foregroundStyle", "frame", "infinity", "leading", "lineLimit",
        "maxWidth", "orange", "pistaDelCampo", "rotuloDeQuienConduce", "secondary", "small",
        "spacing", "textoDelBoton", "textoDelBotonPidiendo",
        // la ronda de arreglos: la acción del botón y la cola de envíos repartida. Ninguno
        // escribe, persiste, notifica ni acumula: `cancel`/`isCancelled` son la cancelación de
        // la cola, `enumerated`/`indice` el índice del reparto, y `espera`/`esperaReal`/`Espera`
        // el reloj inyectable que la prueba observa en vez de dormirlo.
        "AccionDelBoton", "BrowserMandoEnvio", "Equatable", "Espera", "MainActor",
        "QuienConduce", "accion", "accionDelBoton", "agente", "cancel", "devuelve", "ejecuta",
        "enumerated", "escaping", "espera", "esperaReal", "indice", "intervaloEntreTeclas",
        "isCancelled", "otroVisor", "por", "toma", "tras", "typealias", "yo",
        // el anillo del puntero del usuario. Los ocho son **dibujo puro**: ninguno escribe,
        // persiste, notifica ni acumula. `Circle`/`strokeBorder`/`lineWidth`/`position`/`overlay`
        // son la forma y su sitio; `puntero`/`ultimoPunto` son la función pura y el nombre de su
        // parámetro; y `ultimoPunteroDeLaVista` es `@State` en memoria de la vista que se borra
        // al perder el volante —la misma justificación ya aceptada para `tecleado`—, con la
        // diferencia de que ésta guarda UN punto, no una secuencia: no acumula el trazo.
        "Circle", "lineWidth", "overlay", "position", "puntero", "strokeBorder",
        "ultimoPunteroDeLaVista", "ultimoPunto",
        // la ronda 6: el gesto sale del cuerpo de la vista a `BrowserMandoSesion` (H3, el botón
        // hundido) y un envío que falla se dice (H4). Revisados uno a uno, y **ninguno escribe,
        // persiste, notifica ni acumula** la tecla ni la coordenada:
        //   - `BrowserMandoSesion`, `sesion`, `toca`, `levanta`, `retira`, `olvidaElGesto`,
        //     `enVuelo`: la sesión y sus cuatro transiciones. Guarda **un** punto de la página (el
        //     último bueno, el mismo que antes guardaba el `@State` de la vista), no un trazo, y
        //     `retira`/`olvidaElGesto` lo **borran**.
        //   - `alFallar`, `notaQueNoSalio`, `olvidaElFallo`, `entradaPerdida`: un **booleano**, sin
        //     contenido, sin cuenta y sin índice — `alFallar` no recibe nada a propósito, porque
        //     el mensaje, su índice o cuántos quedaban dirían algo de lo que se escribió.
        //   - `en`: la etiqueta del parámetro de `soltado(en:)`.
        //   - `Observable`, `class`, `final`, `init`, `self`, `weak`, `set` (de `private(set)`):
        //     lenguaje. `@Observable` es la observación de SwiftUI en memoria, la misma que ya
        //     lleva `BrowserPanelState`; no persiste nada.
        "BrowserMandoSesion", "sesion", "toca", "levanta", "retira", "olvidaElGesto", "enVuelo",
        "alFallar", "notaQueNoSalio", "olvidaElFallo", "entradaPerdida", "en",
        "Observable", "class", "final", "init", "self", "weak", "set",
        // y H2: `seconds` es la unidad de la derivación `intervaloDeMuestreo = .seconds(1) / …`.
        "seconds",
        // la ronda 7: el tope de verdad de la espera (N1) y el cierre del gesto al devolver el
        // volante (N2). Revisados uno a uno: **ninguno escribe, persiste, notifica ni acumula**.
        // `withCheckedContinuation`/`CheckedContinuation`/`resume`/`continuacion` y la clase
        // `ReanudaUnaSolaVez` (`unaSola`, `reanuda`) son la carrera entre el envío y el reloj,
        // en memoria y sin datos: la continuación lleva `Void`. `espera` ya estaba;
        // `comoMucho`/`plazo`/`plazoParaLoQueQuedaEnVuelo`/`tarea` son su firma y su constante;
        // `cierraElGesto`/`cierre` cierran el gesto (borran el punto, no lo guardan);
        // `nonisolated` es lenguaje.
        "withCheckedContinuation", "CheckedContinuation", "resume", "continuacion",
        "ReanudaUnaSolaVez", "unaSola", "reanuda", "comoMucho", "plazo",
        "plazoParaLoQueQuedaEnVuelo", "tarea", "cierraElGesto", "cierre", "nonisolated",
        // Ronda 8: revisados individualmente tras el rojo del troceado compartido.
        "admite", // puerta síncrona del contacto; no registra entrada.
        "admitido", // decisión de aceptar el fin de un contacto.
        "cambioElVolante", // invalida teclado en el consumidor del flujo.
        "cierraElContacto", // recuerda la identidad del contacto cerrado.
        "contacto", // startLocation recibido del gesto; nunca se registra.
        "contactoCerrado", // una identidad cerrada, no una trayectoria.
        "contactoEnCurso", // una identidad activa, no una trayectoria.
        "devolviendo", // bloqueo síncrono antes de crear la tarea.
        "generacion", // generación capturada por un lote de teclado.
        "generacionDeTeclado", // invalida todos los lotes viejos, solo de teclado.
        "salio", // booleano del envío de devolver, sin contenido.
        "startLocation", // identidad del contacto de SwiftUI.
        "teclea", // entrada a la cadena única de la sesión.
        "vigente", // consulta la generación antes de cada par de teclado.
        // Ronda 9: los tres nombres rechazados en round9-whitelist-red.log, revisados a mano.
        "enPares", // conserva el up del down ya enviado; solo el teclado lo activa.
        "esperaDeDevolucion", // reloj inyectable sin acceso a contenido de entrada.
        "plazoDeDevolucion", // tope del bloqueo hasta confirmación del mando.
        // las palabras de la única cadena literal del fichero, la pista del campo de texto
        // («lo que escribas va a la página»). Son prosa, no identificadores, y entran porque el
        // troceado no distingue una cadena de un nombre. Son también la razón de que el corte
        // por `//` siga siendo seguro: ninguna de ellas contiene una barra.
        "a", "escribas", "la", "lo", "página", "que", "va",
    ]

}
