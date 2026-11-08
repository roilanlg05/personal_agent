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

    @MainActor func test_un_state_con_collapsed_congela() {
        let s = BrowserPanelState()
        s.apply(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        s.apply(.state(live: false, collapsed: true))
        XCTAssertTrue(s.isCollapsed)
        XCTAssertNil(s.jpeg)
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
}
