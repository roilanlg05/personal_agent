import XCTest
@testable import Gemma

final class BrowserPanelStateTests: XCTestCase {
    @MainActor func test_el_en_vivo_llega_del_i3_no_se_calcula() {
        let s = BrowserPanelState()
        XCTAssertFalse(s.isLive)
        s.apply(.state(live: true, collapsed: false))
        XCTAssertTrue(s.isLive, "la app no decide si está vivo: lo recibe")
    }

    @MainActor func test_pagina_quieta_sigue_en_vivo_porque_la_edad_no_decide() {
        let s = BrowserPanelState()
        s.apply(.state(live: true, collapsed: false))
        s.apply(.frame(seq: 1, jpeg: Data([0xFF, 0xD8, 0xFF]), capturedAt: Date(timeIntervalSinceNow: -30)))
        XCTAssertTrue(s.isLive)
        XCTAssertNotNil(s.lastFrameAt, "la edad se muestra, pero no decide")
    }

    @MainActor func test_solo_guarda_el_frame_mas_nuevo() {
        let s = BrowserPanelState()
        s.apply(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        s.apply(.frame(seq: 2, jpeg: Data([0x02]), capturedAt: .now))
        XCTAssertEqual(s.jpeg, Data([0x02]), "un frame a la vez: el anterior se suelta")
    }

    @MainActor func test_freeze_colapsa_y_suelta_la_imagen() {
        let s = BrowserPanelState()
        s.apply(.state(live: true, collapsed: false))
        s.apply(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        s.freeze()
        XCTAssertTrue(s.isCollapsed)
        XCTAssertFalse(s.isLive)
        XCTAssertNil(s.jpeg, "§6.2(g): un panel congelado no deja imagen en el historial")
    }

    /// `.closed` NO es terminal: el cliente reconecta y el panel debe poder revivir.
    @MainActor func test_closed_apaga_el_en_vivo_pero_no_congela_y_un_state_nuevo_revive() {
        let s = BrowserPanelState()
        s.apply(.state(live: true, collapsed: false))
        s.apply(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        s.apply(.closed(reason: "relé cerrado"))
        XCTAssertFalse(s.isLive)
        XCTAssertFalse(s.isCollapsed, "closed no congela")
        XCTAssertNotNil(s.jpeg, "closed no suelta la imagen")
        s.apply(.frame(seq: 2, jpeg: Data([0x02]), capturedAt: .now))
        XCTAssertEqual(s.jpeg, Data([0x02]), "tras reconectar siguen llegando frames")
        s.apply(.state(live: true, collapsed: false))
        XCTAssertTrue(s.isLive, "el panel revive")
    }

    /// Un frame que llega después de congelar no puede reabrir el secreto en reposo.
    @MainActor func test_un_frame_despues_de_congelar_no_repinta() {
        let s = BrowserPanelState()
        s.freeze()
        s.apply(.frame(seq: 9, jpeg: Data([0x01]), capturedAt: .now))
        XCTAssertNil(s.jpeg)
    }

    @MainActor func test_congelar_es_irreversible_ni_un_state_ni_narracion_lo_deshacen() {
        let s = BrowserPanelState()
        s.freeze()
        s.apply(.state(live: true, collapsed: false))
        s.apply(.narration("haciendo clic"))
        XCTAssertTrue(s.isCollapsed)
        XCTAssertFalse(s.isLive)
        XCTAssertEqual(s.phrase, "abriendo el navegador")
    }

    @MainActor func test_un_state_con_collapsed_suelta_la_imagen() {
        let s = BrowserPanelState()
        s.apply(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        s.apply(.state(live: false, collapsed: true))
        XCTAssertTrue(s.isCollapsed)
        XCTAssertNil(s.jpeg)
        s.apply(.frame(seq: 2, jpeg: Data([0x02]), capturedAt: .now))
        XCTAssertNil(s.jpeg, "plegado no pinta")
    }

    /// Fija que un mensaje del relé nunca congela: plegar y desplegar deja revivir.
    @MainActor func test_collapsed_true_y_luego_false_revive_y_vuelve_a_pintar() {
        let s = BrowserPanelState()
        s.apply(.state(live: true, collapsed: true))
        s.apply(.state(live: true, collapsed: false))
        s.apply(.frame(seq: 3, jpeg: Data([0x03]), capturedAt: .now))
        XCTAssertFalse(s.isCollapsed)
        XCTAssertEqual(s.jpeg, Data([0x03]))
    }

    @MainActor func test_el_resumen_llega_aunque_este_congelado() {
        let s = BrowserPanelState()
        s.freeze()
        s.apply(.summary("navegó en amazon.es · 7 acciones"))
        XCTAssertEqual(s.summary, "navegó en amazon.es · 7 acciones")
    }

    @MainActor func test_la_narracion_y_el_resumen_se_guardan_tal_como_llegan() {
        let s = BrowserPanelState()
        s.apply(.narration("haciendo clic"))
        s.apply(.summary("navegó en amazon.es · 7 acciones"))
        XCTAssertEqual(s.phrase, "haciendo clic")
        XCTAssertEqual(s.summary, "navegó en amazon.es · 7 acciones")
    }

    // MARK: - Revisión final: el panel informa

    /// Sin mensajes del relé no hay nada detrás: la vista no pinta (spec §6.2(e), §8).
    @MainActor func test_sin_mensajes_del_rele_no_hay_nada_que_pintar() {
        let s = BrowserPanelState()
        XCTAssertFalse(s.hasReceivedMessage)
        s.freeze()
        XCTAssertFalse(s.hasReceivedMessage, "congelar no resucita un panel que nunca recibió nada")
    }

    /// `closed` lo fabrica también el cliente al fallar la conexión: no prueba que haya un i3.
    @MainActor func test_un_closed_solo_no_cuenta_como_mensaje() {
        let s = BrowserPanelState()
        s.apply(.closed(reason: "fallo de recepción"))
        XCTAssertFalse(s.hasReceivedMessage)
    }

    @MainActor func test_un_state_basta_para_que_el_panel_se_pinte() {
        let s = BrowserPanelState()
        s.apply(.state(live: true, collapsed: false))
        XCTAssertTrue(s.hasReceivedMessage)
    }

    @MainActor func test_freeze_no_borra_haber_recibido() {
        let s = BrowserPanelState()
        s.apply(.state(live: true, collapsed: false))
        s.freeze()
        XCTAssertTrue(s.hasReceivedMessage)
    }

    @MainActor func test_el_motivo_del_closed_se_guarda_y_un_state_nuevo_lo_borra() {
        let s = BrowserPanelState()
        s.apply(.state(live: true, collapsed: false))
        s.apply(.closed(reason: "sesión cerrada por inactividad"))
        XCTAssertEqual(s.closedReason, "sesión cerrada por inactividad")
        XCTAssertFalse(s.isLive)
        s.apply(.state(live: true, collapsed: false))
        XCTAssertNil(s.closedReason, "reconectó: el motivo ya no aplica")
    }

    @MainActor func test_el_host_se_guarda() {
        let s = BrowserPanelState()
        XCTAssertNil(s.host)
        s.apply(.host("example.com"))
        XCTAssertEqual(s.host, "example.com")
    }

    // MARK: quién conduce

    /// EL CICLO COMPLETO, y completo a propósito. Afirmar `.agente` sin haber hecho nada pasaría
    /// con la característica entera borrada, porque `.agente` es el valor de arranque: la única
    /// forma de medir la vuelta al agente es llegar primero a `.yo`. Y la reconexión se mide
    /// hasta el final: tras el corte llegan un `state` y un `frame` de la conexión nueva, y el
    /// volante tiene que seguir siendo del agente.
    @MainActor func test_el_volante_vuelve_al_agente_al_cortarse_la_conexion_y_la_reconexion_no_lo_resucita() {
        let s = BrowserPanelState()
        XCTAssertEqual(s.quienConduce, .agente, "precondición del arranque, no la aserción de esta prueba")
        s.apply(.mando(quien: .yo))
        XCTAssertEqual(s.quienConduce, .yo, "el servidor confirmó que el volante es mío")
        s.apply(.closed(reason: "fallo de recepción"))
        XCTAssertEqual(s.quienConduce, .agente,
                       "el portador del mando es la CONEXIÓN: el socket que muere se lo lleva")
        s.apply(.state(live: true, collapsed: false))
        s.apply(.frame(seq: 1, jpeg: Data([0xFF, 0xD8]), capturedAt: Date()))
        XCTAssertEqual(s.quienConduce, .agente,
                       "la conexión nueva nunca tuvo el volante: hay que volver a pedirlo")
    }

    /// `otroVisor` no es `agente`, y la vista se comporta distinto: con el agente al volante
    /// pedirlo funciona; con otro humano al volante el servidor rechaza la toma en silencio.
    @MainActor func test_otro_visor_al_volante_no_es_lo_mismo_que_el_agente() {
        let s = BrowserPanelState()
        s.apply(.mando(quien: .otroVisor))
        XCTAssertEqual(s.quienConduce, .otroVisor)
        s.apply(.mando(quien: .agente))
        XCTAssertEqual(s.quienConduce, .agente, "y vuelve a estar libre cuando el otro lo devuelve")
    }

    @MainActor func test_un_panel_congelado_no_le_dice_al_usuario_que_conduce() {
        let s = BrowserPanelState()
        s.apply(.mando(quien: .yo))
        XCTAssertEqual(s.quienConduce, .yo)
        s.freeze()
        XCTAssertEqual(s.quienConduce, .agente, "un panel del historial no manda nada a ninguna parte")
        s.apply(.mando(quien: .yo))
        XCTAssertEqual(s.quienConduce, .agente, "y ya no se mueve: congelar es irreversible")
    }

    /// Un `mando` lo manda el i3, así que prueba que el servidor habló y el panel debe aparecer.
    @MainActor func test_un_mando_cuenta_como_que_el_servidor_hablo() {
        let s = BrowserPanelState()
        XCTAssertFalse(s.hasReceivedMessage)
        s.apply(.mando(quien: .agente))
        XCTAssertTrue(s.hasReceivedMessage)
        XCTAssertEqual(s.mensajesRecibidos, 1)
    }
}

/// El hueco de la imagen del panel. Ver `BrowserPanelView.textoSinImagen`: antes, sin imagen, la
/// vista pintaba un color plano y nada más, y en modo oscuro eso es un rectángulo negro mudo. El
/// usuario lo reportó como «la pantalla del navegador se veía negra» y no podía saber si era el
/// stream, la app o la página.
final class BrowserPanelHuecoSinImagenTests: XCTestCase {

    /// La propiedad que de verdad importa: NINGUNA combinación de estado puede dejar el hueco sin
    /// texto. Un rectángulo mudo es el defecto, y lo fácil es reintroducirlo con un `return ""`.
    func test_ninguna_combinacion_deja_el_hueco_mudo() {
        for motivo in [nil, "", "socket caído"] as [String?] {
            for vivo in [true, false] {
                let texto = BrowserPanelView.textoSinImagen(closedReason: motivo, isLive: vivo)
                XCTAssertFalse(texto.trimmingCharacters(in: .whitespaces).isEmpty,
                               "hueco mudo con motivo=\(String(describing: motivo)) vivo=\(vivo)")
            }
        }
    }

    func test_cerrado_lo_dice_aunque_el_motivo_venga_vacio() {
        XCTAssertTrue(BrowserPanelView.textoSinImagen(closedReason: "", isLive: true).contains("cerró"))
        XCTAssertTrue(BrowserPanelView.textoSinImagen(closedReason: "socket caído", isLive: false).contains("cerró"))
    }

    func test_congelado_y_esperando_se_distinguen() {
        XCTAssertTrue(BrowserPanelView.textoSinImagen(closedReason: nil, isLive: false).contains("congelado"))
        XCTAssertTrue(BrowserPanelView.textoSinImagen(closedReason: nil, isLive: true).contains("Esperando"))
    }

    /// La ruedecita solo gira cuando de verdad va a llegar algo: prometer una imagen sobre un
    /// panel cerrado o congelado es peor que no decir nada.
    func test_la_ruedecita_solo_gira_cuando_se_espera_una_imagen() {
        XCTAssertTrue(BrowserPanelView.esperandoLaPrimera(closedReason: nil, isLive: true))
        XCTAssertFalse(BrowserPanelView.esperandoLaPrimera(closedReason: nil, isLive: false))
        XCTAssertFalse(BrowserPanelView.esperandoLaPrimera(closedReason: "socket caído", isLive: true))
    }
}

/// Las cuentas del hueco. Ver `BrowserPanelState.mensajesRecibidos`: sin ellas, «no llega nada»,
/// «llegan mensajes pero ningún fotograma» y «llegan fotogramas y no se pintan» se ven idénticos.
final class BrowserPanelCuentasTests: XCTestCase {

    /// El caso que faltaba y que mandaba a buscar el fallo al sitio equivocado: con bytes de
    /// fotograma guardados, el hueco decía «Esperando la primera imagen», que es lo contrario.
    func test_un_fotograma_que_no_decodifica_no_se_confunde_con_esperar() {
        let t = BrowserPanelView.textoSinImagen(closedReason: nil, isLive: true, hayJpeg: true)
        XCTAssertTrue(t.contains("decodificar"), t)
        XCTAssertFalse(t.contains("Esperando"), t)
    }

    /// Y gana sobre los demás motivos: si hay bytes, el problema está en la app, se haya cerrado
    /// o congelado lo que sea después.
    func test_el_fotograma_sin_decodificar_gana_sobre_los_otros_motivos() {
        for (motivo, vivo) in [("socket caído", false), (nil, false), ("", true)] as [(String?, Bool)] {
            XCTAssertTrue(
                BrowserPanelView.textoSinImagen(closedReason: motivo, isLive: vivo, hayJpeg: true)
                    .contains("decodificar"))
        }
    }

    func test_la_cuenta_siempre_dice_algo() {
        XCTAssertEqual(BrowserPanelView.cuenta(mensajes: 0, fotogramas: 0, descartados: 0),
                       "mensajes 0 · fotogramas 0")
        XCTAssertTrue(BrowserPanelView.cuenta(mensajes: 9, fotogramas: 3, descartados: 2)
                        .contains("descartados 2"))
    }

    /// LA CUENTA ES DIAGNÓSTICO, Y SOLO SE PINTA CUANDO INFORMA.
    ///
    /// Los contadores los puso un commit `diag(...)` para entender «el panel se muere»; el
    /// usuario los leyó en su teléfono y los reportó. No se borran —el misterio que
    /// diagnostican, «mensajes 6 · fotogramas 0», sigue sin explicación— pero un panel que
    /// pintó cuarenta fotogramas y luego soltó la imagen al cerrarse deja un hueco NORMAL, y
    /// ahí dos números monoespaciados no diagnostican nada: son ruido de desarrollador sobre un
    /// panel que funcionó.
    ///
    /// Las dos mitades están en la misma función: devolver siempre `true` (lo de antes) mata la
    /// segunda, y devolver siempre `false` (borrar la línea, que es lo que NO se quería) mata
    /// la primera.
    func test_la_cuenta_solo_se_pinta_cuando_el_panel_no_consiguio_pintar() {
        XCTAssertTrue(BrowserPanelView.muestraLaCuenta(fotogramas: 0, descartados: 0, hayJpeg: false),
                      "ni un fotograma: es el misterio, y es lo que el usuario reportó")
        XCTAssertTrue(BrowserPanelView.muestraLaCuenta(fotogramas: 40, descartados: 3, hayJpeg: false),
                      "llegaron y se tiraron: eso hay que poder verlo")
        XCTAssertTrue(BrowserPanelView.muestraLaCuenta(fotogramas: 1, descartados: 0, hayJpeg: true),
                      "hay bytes guardados y aun así no hay imagen: no decodificó")
        XCTAssertFalse(BrowserPanelView.muestraLaCuenta(fotogramas: 40, descartados: 0, hayJpeg: false),
                       "un panel que pintó cuarenta fotogramas y soltó la imagen no necesita contadores")
    }

    /// Los descartes solo aparecen cuando los hay: una línea con «descartados 0» en cada panel
    /// sano es ruido que acaba ignorándose, y entonces no se ve el día que importa.
    func test_los_descartes_solo_se_nombran_cuando_existen() {
        XCTAssertFalse(BrowserPanelView.cuenta(mensajes: 5, fotogramas: 5, descartados: 0)
                        .contains("descartados"))
    }

    @MainActor
    func test_el_estado_cuenta_los_fotogramas_descartados_por_plegado() {
        let s = BrowserPanelState()
        s.apply(.state(live: true, collapsed: true))
        s.apply(.frame(seq: 1, jpeg: Data([0xFF, 0xD8]), capturedAt: Date()))
        XCTAssertEqual(s.fotogramasRecibidos, 1)
        XCTAssertEqual(s.fotogramasDescartados, 1, "un frame tirado por plegado debe contarse")
        XCTAssertNil(s.jpeg, "plegado no guarda imagen")
    }
}
