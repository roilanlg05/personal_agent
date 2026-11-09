import CoreGraphics
import XCTest
@testable import Gemma

#if os(macOS)

/// El mapa de un toque en la pantalla del usuario a una coordenada del viewport remoto.
///
/// QUÉ SE ESTÁ CLAVANDO, Y POR QUÉ IMPORTA MÁS QUE LA MEDIA. Si este mapa se equivoca, el
/// usuario pulsa **otro botón de su propia cuenta**: el agente le ha dado el volante justo
/// porque va a teclear una contraseña, así que el clic cae sobre una página con sesión abierta.
/// No hay nadie aguas abajo que lo valide: el relé reenvía el mensaje al demonio verbatim y
/// valida solo el `type` (`relay.py:678-684`), y el demonio dispara el clic donde se le diga.
/// Por eso la dirección segura es fija y es `nil` — «no mandes nada» — y por eso hay tantas
/// pruebas de `nil` como de acierto.
///
/// LA TRAMPA DE ESTE FICHERO, DICHA EN VOZ ALTA. Una función que devuelve `nil` para todo pasa
/// **todas** las pruebas de `nil` de abajo. Las pruebas de `nil`, solas, no prueban nada. Lo que
/// las hace valer son las pruebas del acierto, que mueren con ese mismo cuerpo degenerado: el
/// `nil` y el acierto comparten la mutación «`return nil` al principio», y la tabla de
/// mutaciones del informe lo mide. Cada prueba de `nil` de abajo tiene además su propia
/// mutación, la del guarda concreto que la produce, para que no pase por el motivo equivocado
/// (otro guarda, o el degenerado).
///
/// DE DÓNDE SALEN LOS NÚMEROS. El viewport medido del demonio es 1280×720 y el JPEG que llega
/// es 1080×608 (`agent-browser 0.41.2`, medición del implementador de la Tarea 2, campos
/// `viewport_width`/`viewport_height` del mensaje `frame`). Esas dos parejas son las que
/// aparecen en las pruebas del acierto. 1080/1280 = 0.84375, y 0.84375 × 720 = **607.5**, que
/// el demonio redondea a 608: ese medio píxel de desajuste es real y es el motivo de que la
/// comprobación de proporción tenga tolerancia en vez de exigir una proporción exacta.
///
/// LO QUE NO SE SUMA. El scroll NO viaja por el cable y NO se suma. El implementador de la
/// Tarea 2 lo midió: al desplazar 900 px el `scrollOffsetY` del demonio pasó de 0 a 900
/// mientras las dimensiones **y el JPEG** no cambiaron. El fotograma retrata siempre el
/// viewport y el demonio quiere coordenadas del viewport; sumar el scroll serían 900 px de
/// error, es decir un clic en otro botón. No hay prueba de esto porque no hay término que
/// probar: se afirma aquí y en el fuente de producción para que nadie lo añada «arreglando» un
/// desajuste que vendrá de otro sitio.
final class BrowserInputMapperTests: XCTestCase {

    // MARK: atajos

    private typealias Cable = BrowserInputMapper.DimensionesDelCable

    /// El viewport medido.
    private let viewportMedido = Cable(anchoDelViewport: 1280, altoDelViewport: 720)
    /// El JPEG medido que el demonio manda para ese viewport.
    private let imagenMedida = CGSize(width: 1080, height: 608)

    private func mapa(_ x: CGFloat, _ y: CGFloat,
                      vista: CGSize,
                      imagen: CGSize? = nil,
                      cable: Cable?? = nil) -> CGPoint? {
        BrowserInputMapper.paginaDesde(
            punto: CGPoint(x: x, y: y),
            tamañoDeLaVista: vista,
            tamañoDeLaImagen: imagen ?? imagenMedida,
            dimensionesDelCable: cable ?? viewportMedido)
    }

    /// El fuente de producción, para la prueba que afirma una AUSENCIA (que no hay registro).
    /// Una ausencia no se puede observar ejecutando código: se lee el fuente, igual que hace
    /// `BrowserInputEventsTests.test_ninguna_funcion_del_fichero_registra_nada`.
    private func fuenteDeProduccion() throws -> String {
        let aqui = URL(fileURLWithPath: #filePath)
        let fichero = aqui.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/Harness/BrowserInputMapper.swift")
        return try String(contentsOf: fichero, encoding: .utf8)
    }

    // MARK: el acierto — la vista comparte proporción con la imagen, no hay bandas

    /// El centro de la vista cae en el centro de la página.
    ///
    /// Con la imagen medida (1080×608) dibujada en una vista de su mismo tamaño, el centro de la
    /// vista es (540, 304) y el centro de la página de 1280×720 es (640, 360).
    /// 540 × 1280/1080 = 640 exacto; 304 × 720/608 = 360 exacto. Nada que redondear.
    func test_el_centro_de_la_vista_cae_en_el_centro_de_la_pagina() {
        XCTAssertEqual(mapa(540, 304, vista: CGSize(width: 1080, height: 608)),
                       CGPoint(x: 640, y: 360))
    }

    /// Y sigue cayendo en el centro cuando la vista es más pequeña que la imagen, que es el caso
    /// real en el teléfono: el panel mide bastante menos de 1080 puntos de ancho. Vista a la
    /// mitad justa (540×304), así que la escala de dibujo es 0.5 y el centro de la vista es
    /// (270, 152).
    ///
    /// Esta prueba es la que mata la mutación «ignora la escala de dibujo»: con la vista al
    /// mismo tamaño que la imagen esa escala vale 1 y no se observa.
    func test_el_centro_sigue_siendo_el_centro_con_la_vista_a_la_mitad() {
        XCTAssertEqual(mapa(270, 152, vista: CGSize(width: 540, height: 304)),
                       CGPoint(x: 640, y: 360))
    }

    /// Las cuatro esquinas caen en las cuatro esquinas, al píxel.
    ///
    /// QUÉ ES «LA ESQUINA», Y POR QUÉ NO ES (1280, 720). `viewport_width` es un **recuento** de
    /// columnas de píxeles: las direccionables son 0…1279, y 1280 está FUERA de la página. Un
    /// clic en x=1280 no cae en el contenido —cae en la nada, o en la barra de desplazamiento—,
    /// que es exactamente el fallo que esta tarea existe para evitar. Así que la esquina de
    /// abajo a la derecha de la página es (1279, 719), y el mapa recorta el resultado a
    /// 0…ancho-1 y 0…alto-1.
    func test_las_cuatro_esquinas_caen_en_las_cuatro_esquinas_al_pixel() {
        let vista = CGSize(width: 1080, height: 608)
        XCTAssertEqual(mapa(0, 0, vista: vista), CGPoint(x: 0, y: 0))
        XCTAssertEqual(mapa(1080, 0, vista: vista), CGPoint(x: 1279, y: 0))
        XCTAssertEqual(mapa(0, 608, vista: vista), CGPoint(x: 0, y: 719))
        XCTAssertEqual(mapa(1080, 608, vista: vista), CGPoint(x: 1279, y: 719))
    }

    /// El resultado es SIEMPRE un píxel entero, porque quien lo consume
    /// (`BrowserInputEvents.mouse`/`touch`) toma `Int`, y `Int(_:)` de un `CGFloat` **trunca**:
    /// un 639.9999 salido de la aritmética en coma flotante se mandaría como 639, un píxel a la
    /// izquierda de donde el usuario tocó. Se redondea aquí, una vez, y se recorta DESPUÉS de
    /// redondear, para que ninguna conversión del llamante —`Int()`, `rounded()`, `floor()`—
    /// pueda salirse del rango direccionable.
    func test_el_resultado_es_un_pixel_entero_y_dentro_del_rango() throws {
        // Un punto elegido para que la división NO dé un entero: 7 × 1280/1080 = 8.296…
        let p = try XCTUnwrap(mapa(7, 11, vista: CGSize(width: 1080, height: 608)))
        XCTAssertEqual(p.x, p.x.rounded(), "la x no es un píxel entero: \(p.x)")
        XCTAssertEqual(p.y, p.y.rounded(), "la y no es un píxel entero: \(p.y)")
        XCTAssertEqual(p, CGPoint(x: 8, y: 13))  // 8.296…→8 ; 11 × 720/608 = 13.026…→13

        // Y la esquina, que es donde el recorte se nota: redondear da 1280/720, fuera de rango.
        let esquina = try XCTUnwrap(mapa(1080, 608, vista: CGSize(width: 1080, height: 608)))
        XCTAssertLessThanOrEqual(esquina.x, 1279)
        XCTAssertLessThanOrEqual(esquina.y, 719)
    }

    /// La escala de la imagen al viewport se calcula EJE A EJE, no con una sola escala para los
    /// dos. Es un aviso explícito del implementador de la Tarea 2: con el JPEG medido las dos
    /// proporciones casi coinciden (1280/1080 = 1.1852 contra 720/608 = 1.1842), así que con
    /// esos números una sola escala se equivoca en menos de un píxel y el fallo no se ve.
    ///
    /// Esta prueba lo hace visible sin salirse del contrato: la imagen es pequeña (270×151), que
    /// amplifica la misma clase de desajuste de redondeo que el 607.5→608 medido. 1280/270 =
    /// 4.7407 contra 720/151 = 4.7682. Un punto en y=100 de la imagen cae en 476.82 → **477**
    /// con la escala del eje y, y en 474.07 → **474** si se usa la del eje x. Tres píxeles.
    func test_la_escala_al_viewport_se_calcula_eje_a_eje() {
        // 151 está dentro de la tolerancia de proporción: 270/1280 × 720 = 607.5/4 = 151.875,
        // y |151 − 151.875| = 0.875 ≤ 2.
        let imagen = CGSize(width: 270, height: 151)
        XCTAssertEqual(mapa(135, 100, vista: imagen, imagen: imagen),
                       CGPoint(x: 640, y: 477))
    }

    // MARK: las bandas — el `nil` que el plan pide al píxel

    /// Con la imagen dibujada en una vista MÁS ALTA que su proporción, SwiftUI
    /// (`.resizable().scaledToFit()`, `BrowserPanelView.swift:58-60`) la centra y deja banda
    /// arriba y abajo. Un punto sobre la banda no está sobre la página.
    ///
    /// Vista 1080×1000 con imagen 1080×608: la escala de dibujo es min(1, 1.6447) = 1, así que
    /// la imagen ocupa de y=196 a y=804 y las bandas son [0,196) y (804,1000].
    func test_un_punto_sobre_la_banda_de_arriba_o_de_abajo_no_se_manda() {
        let vista = CGSize(width: 1080, height: 1000)

        // Dentro: el centro de la IMAGEN, no el de la vista.
        XCTAssertEqual(mapa(540, 500, vista: vista), CGPoint(x: 640, y: 360))
        // Los dos bordes exactos de la imagen sí están sobre la página.
        XCTAssertEqual(mapa(540, 196, vista: vista), CGPoint(x: 640, y: 0))
        XCTAssertEqual(mapa(540, 804, vista: vista), CGPoint(x: 640, y: 719))

        // Y medio punto más allá de cada borde ya es banda. Al píxel.
        XCTAssertNil(mapa(540, 195.5, vista: vista))
        XCTAssertNil(mapa(540, 804.5, vista: vista))
        XCTAssertNil(mapa(540, 10, vista: vista))
        XCTAssertNil(mapa(540, 990, vista: vista))
    }

    /// Lo mismo con una vista más ANCHA que la proporción: bandas a los lados.
    /// Vista 2000×608 con imagen 1080×608: escala de dibujo 1, imagen de x=460 a x=1540.
    func test_un_punto_sobre_la_banda_de_los_lados_no_se_manda() {
        let vista = CGSize(width: 2000, height: 608)

        XCTAssertEqual(mapa(460, 0, vista: vista), CGPoint(x: 0, y: 0))
        XCTAssertEqual(mapa(1540, 608, vista: vista), CGPoint(x: 1279, y: 719))

        XCTAssertNil(mapa(459.5, 300, vista: vista))
        XCTAssertNil(mapa(1540.5, 300, vista: vista))
        XCTAssertNil(mapa(100, 300, vista: vista))
        XCTAssertNil(mapa(1900, 300, vista: vista))
    }

    /// Un punto fuera de la vista entera tampoco se manda, aunque la vista y la imagen
    /// compartan proporción y no haya banda ninguna: el recorte al rectángulo dibujado lo cubre.
    func test_un_punto_fuera_de_la_vista_no_se_manda() {
        let vista = CGSize(width: 1080, height: 608)
        XCTAssertNil(mapa(-1, 300, vista: vista))
        XCTAssertNil(mapa(540, -1, vista: vista))
        XCTAssertNil(mapa(1081, 300, vista: vista))
        XCTAssertNil(mapa(540, 609, vista: vista))
    }

    /// Un punto que no es un número no se manda. No hay comprobación explícita de esto: las
    /// comparaciones con `NaN` son todas falsas, así que el recorte al rectángulo dibujado ya lo
    /// rechaza. Se clava para que siga siendo verdad si alguien reescribe ese recorte.
    func test_un_punto_que_no_es_un_numero_no_se_manda() {
        let vista = CGSize(width: 1080, height: 608)
        XCTAssertNil(mapa(.nan, 300, vista: vista))
        XCTAssertNil(mapa(540, .nan, vista: vista))
        XCTAssertNil(mapa(.infinity, 300, vista: vista))
        XCTAssertNil(mapa(540, -.infinity, vista: vista))
    }

    // MARK: sin dimensiones del cable

    /// Sin dimensiones del cable no hay mapa. Es el caso normal de los fotogramas viejos: el
    /// relé empezó a mandar `viewport_width`/`viewport_height` en la Tarea 2, y un servidor sin
    /// desplegar no los manda.
    func test_sin_dimensiones_del_cable_no_se_manda_nada() {
        XCTAssertNil(mapa(540, 304, vista: CGSize(width: 1080, height: 608),
                          cable: .some(nil)))
    }

    // MARK: dimensiones absurdas

    /// Un viewport de cero o negativo no se puede invertir —la división explotaría o daría
    /// infinito— y además no describe ninguna página.
    ///
    /// El relé manda los dos lados o ninguno, nunca uno solo; aun así el cliente no puede
    /// confiar en eso, porque un cliente que asume el invariante del servidor se rompe el día
    /// que el servidor cambie. Se comprueban los dos lados por separado.
    func test_un_viewport_de_cero_o_negativo_no_se_manda() {
        let vista = CGSize(width: 1080, height: 608)
        let imagen = CGSize(width: 100, height: 56)
        for cable in [Cable(anchoDelViewport: 0, altoDelViewport: 720),
                      Cable(anchoDelViewport: 1280, altoDelViewport: 0),
                      Cable(anchoDelViewport: 0, altoDelViewport: 0),
                      Cable(anchoDelViewport: -1280, altoDelViewport: 720),
                      Cable(anchoDelViewport: 1280, altoDelViewport: -720)] {
            XCTAssertNil(mapa(10, 10, vista: vista, imagen: imagen, cable: .some(cable)),
                         "viewport \(cable.anchoDelViewport)×\(cable.altoDelViewport)")
        }
    }

    /// Una imagen de tamaño cero, negativo o no finito no se puede invertir. Pasa de verdad:
    /// `BrowserPanelState` suelta el JPEG al plegarse el panel y al cerrarse la conexión, y un
    /// decodificador que falla puede dar un tamaño vacío sin lanzar.
    func test_una_imagen_de_tamano_absurdo_no_se_manda() {
        let vista = CGSize(width: 1080, height: 608)
        for imagen in [CGSize(width: 0, height: 608),
                       CGSize(width: 1080, height: 0),
                       CGSize.zero,
                       CGSize(width: -1080, height: 608),
                       CGSize(width: 1080, height: -608),
                       CGSize(width: CGFloat.nan, height: 608),
                       CGSize(width: 1080, height: CGFloat.nan),
                       CGSize(width: CGFloat.infinity, height: 608),
                       CGSize(width: 1080, height: CGFloat.infinity),
                       CGSize(width: 0.5, height: 0.5),
                       // Y EL CASO QUE LOS OTROS GUARDAS NO ATRAPAN, que es el que hace que este
                       // guarda exista. Las diez entradas de arriba se las queda otro guarda:
                       // las no finitas y las negativas no pasan «la imagen no es mayor que el
                       // viewport», las de un eje a cero fallan la proporción, y la de 0.5×0.5
                       // sale del rectángulo dibujado. Se midió quitando el guarda del tamaño de
                       // la imagen: con solo esas diez, la prueba seguía verde — era VACUA.
                       //
                       // Esta no. Media imagen CON la proporción exacta del viewport
                       // (0.5 / 1280 × 720 = 0.28125) pasa el de «no mayor», pasa el de
                       // proporción con error 0, y cae dentro del rectángulo dibujado. Sin el
                       // guarda del tamaño, el mapa devuelve una coordenada calculada sobre
                       // medio píxel de imagen, que es ruido con pinta de respuesta.
                       CGSize(width: 0.5, height: 0.28125)] {
            XCTAssertNil(mapa(10, 10, vista: vista, imagen: imagen),
                         "imagen \(imagen.width)×\(imagen.height)")
        }
    }

    /// Una vista de tamaño cero, negativo o no finito no se puede invertir. Pasa de verdad: un
    /// `GeometryReader` da 0×0 en el primer paso de maquetación, antes de que SwiftUI sepa
    /// cuánto sitio hay, y en ese instante ya puede haber un toque en vuelo.
    func test_una_vista_de_tamano_absurdo_no_se_manda() {
        for vista in [CGSize(width: 0, height: 608),
                      CGSize(width: 1080, height: 0),
                      CGSize.zero,
                      CGSize(width: -1080, height: 608),
                      CGSize(width: 1080, height: -608),
                      CGSize(width: CGFloat.nan, height: 608),
                      CGSize(width: 1080, height: CGFloat.nan),
                      CGSize(width: CGFloat.infinity, height: 608),
                      CGSize(width: 1080, height: CGFloat.infinity)] {
            XCTAssertNil(mapa(10, 10, vista: vista),
                         "vista \(vista.width)×\(vista.height)")
        }

        // Y EL CASO QUE EL RECORTE AL RECTÁNGULO DIBUJADO NO ATRAPA, que es el que hace que los
        // guardas del tamaño de la vista existan. Las nueve de arriba se las queda ese recorte
        // —una vista de 0 da un rectángulo de 0 de ancho y el punto (10, 10) se sale; una no
        // finita da un margen infinito y el punto se va a −∞—, y se midió: quitando los DOS
        // guardas de la vista a la vez, con solo esas nueve la prueba seguía verde. Era VACUA.
        //
        // Esta no. Con la vista a 0×0 el rectángulo dibujado es 0×0 con el margen a 0, así que
        // el punto (0, 0) cae DENTRO de él —0 ≤ 0 en los dos ejes— y pasa el recorte. Lo que
        // sale al otro lado es 0/0 = `NaN`, y `NaN` recorrido por `min`/`max` sale `NaN` otra
        // vez: sin los guardas, esta llamada devuelve `CGPoint(NaN, NaN)`, que no es `nil` y que
        // el llamante mandaría como coordenada. Es el peor resultado posible de esta función
        // —ruido con pinta de respuesta— y es exactamente lo que no puede pasar.
        XCTAssertNil(mapa(0, 0, vista: .zero))
    }

    /// Una imagen MÁS GRANDE que el viewport es una contradicción: el demonio escala el
    /// screencast hacia abajo para que quepa en los topes del `compose`, nunca hacia arriba. Si
    /// llega una imagen mayor que el viewport, la premisa de este mapa ya no se cumple y lo que
    /// no se sabe es si el error está en la imagen o en el viewport, así que no se manda nada.
    ///
    /// Los tamaños de aquí comparten proporción con el viewport **a propósito** (1300×731 es
    /// 1280×720 ampliado 1.015625, y 731.25 redondea a 731), para que el `nil` no pueda venir de
    /// la comprobación de proporción: viene de esta y solo de esta.
    func test_una_imagen_mas_grande_que_el_viewport_no_se_manda() {
        let vista = CGSize(width: 1080, height: 608)
        XCTAssertNil(mapa(10, 10, vista: vista, imagen: CGSize(width: 1300, height: 731)))
        // Y un solo eje de más basta.
        XCTAssertNil(mapa(10, 10, vista: vista, imagen: CGSize(width: 1281, height: 720)))
        XCTAssertNil(mapa(10, 10, vista: vista, imagen: CGSize(width: 1280, height: 721)))
        // Igual de grande SÍ se manda: es la escala 1, que es legítima.
        XCTAssertEqual(mapa(640, 360, vista: CGSize(width: 1280, height: 720),
                            imagen: CGSize(width: 1280, height: 720)),
                       CGPoint(x: 640, y: 360))
    }

    /// Una imagen que NO es el viewport escalado uniformemente no se manda.
    ///
    /// POR QUÉ ESTE GUARDA EXISTE. El plan nombra tres escalas y dice de la primera —viewport al
    /// recorte del servidor— «medido: 1280×720 → 1080×608, misma proporción, así que hoy es
    /// escala y no recorte, **compruébalo, no lo heredes**». Lo comprobado es que hoy es una
    /// escala. Pero por el cable no viaja ningún desplazamiento, así que si el servidor algún
    /// día RECORTA en vez de escalar, este mapa no tiene con qué corregirlo: multiplicar por una
    /// proporción estiraría el recorte y el usuario pulsaría otra cosa, en silencio. Lo único
    /// que se puede hacer es detectarlo y callarse, y la huella que deja un recorte es que la
    /// proporción de la imagen deja de ser la del viewport.
    ///
    /// LA TOLERANCIA NO ES COSMÉTICA. 1080/1280 × 720 = 607.5 y el demonio manda 608: medio
    /// píxel de desajuste, medido. Exigir proporción exacta dejaría el panel sin mandar nunca
    /// nada, que es el `nil` inútil. Se admiten 2 píxeles —el redondeo, y el redondeo a un
    /// tamaño par que hacen algunos codificadores— y 2 píxeles de imagen son ~2.4 píxeles de
    /// viewport con los tamaños medidos, menos de lo que un dedo distingue.
    func test_una_imagen_que_no_es_el_viewport_escalado_no_se_manda() {
        let vista = CGSize(width: 1080, height: 608)
        // Un recorte de verdad: 1080 de ancho pero solo 500 de alto, contra 607.5 esperados.
        XCTAssertNil(mapa(10, 10, vista: vista, imagen: CGSize(width: 1080, height: 500)))
        // Y el borde de la tolerancia, que es lo que fija la constante en 2 y no en 4:
        // |604 − 607.5| = 3.5 → fuera.
        XCTAssertNil(mapa(10, 10, vista: vista, imagen: CGSize(width: 1080, height: 604)))
    }

    /// El otro lado de esa tolerancia, que es lo que impide que la constante se estreche a 0 y
    /// deje el panel mudo: |606 − 607.5| = 1.5 ≤ 2, así que esta imagen SÍ se mapea.
    ///
    /// Esta prueba y la de arriba son el par: sin ella, `toleranciaDeProporcion = 0` pasaría.
    func test_una_imagen_dentro_de_la_tolerancia_de_proporcion_si_se_manda() {
        let imagen = CGSize(width: 1080, height: 606)
        // 540 × 1280/1080 = 640 ; 303 × 720/606 = 360
        XCTAssertEqual(mapa(540, 303, vista: imagen, imagen: imagen),
                       CGPoint(x: 640, y: 360))
    }

    // MARK: la ausencia

    /// Aquí no se registra nada. El mapa no ve la tecla, pero sí ve **dónde** toca el usuario, y
    /// un rastro de coordenadas sobre un teclado en pantalla reconstruye una contraseña. Vale la
    /// misma regla que en `BrowserInputEvents`: este fichero no tiene ningún camino que escriba
    /// un valor de entrada en ninguna parte.
    func test_el_mapa_no_registra_nada() throws {
        let fuente = try fuenteDeProduccion()
        // Guarda de vacuidad: la aserción de abajo es una AUSENCIA y pasaría sola si el fichero
        // estuviera vacío o la ruta estuviera mal. Primero, que sea el fichero de verdad.
        for ancla in ["enum BrowserInputMapper", "func paginaDesde", "DimensionesDelCable"] {
            XCTAssertTrue(fuente.contains(ancla),
                          "la ruta del fuente ya no apunta al fichero de producción: falta \(ancla)")
        }
        for registro in ["PanelLog", "print(", "NSLog", "os_log", "Logger", "OSLog",
                         "FileHandle", "debugPrint"] {
            XCTAssertFalse(fuente.contains(registro),
                           "el mapa no puede registrar nada: la coordenada delata la tecla (\(registro))")
        }
    }
}

#endif
