import XCTest
@testable import Gemma

final class BrowserPanelCoordinatorTests: XCTestCase {
    /// Fábrica falsa: cada llamada da un flujo nuevo que la prueba controla.
    @MainActor private static func coordinator() -> BrowserPanelCoordinator {
        BrowserPanelCoordinator(stream: { AsyncStream { _ in } })
    }

    @MainActor func test_una_herramienta_que_no_es_de_navegador_no_abre_panel() {
        let c = Self.coordinator()
        XCTAssertNil(c.openIfNeeded(toolName: "save_memory"))
        XCTAssertTrue(c.panels.isEmpty)
    }

    @MainActor func test_la_primera_herramienta_de_navegador_abre_un_panel() {
        let c = Self.coordinator()
        let id = c.openIfNeeded(toolName: "browser_open")
        XCTAssertNotNil(id)
        XCTAssertEqual(c.activeID, id)
    }

    @MainActor func test_un_turno_con_varias_acciones_tiene_un_solo_panel() {
        let c = Self.coordinator()
        let first = c.openIfNeeded(toolName: "browser_open")
        XCTAssertNil(c.openIfNeeded(toolName: "browser_click"))
        XCTAssertNil(c.openIfNeeded(toolName: "browser_snapshot"))
        XCTAssertEqual(c.panels.count, 1)
        XCTAssertEqual(c.activeID, first)
    }

    @MainActor func test_el_turno_siguiente_abre_otro_panel_y_el_viejo_queda_colapsado() throws {
        let c = Self.coordinator()
        let first = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        c.endTurn()
        XCTAssertNil(c.activeID)
        let second = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(c.panels[first]!.isCollapsed)
        XCTAssertFalse(c.panels[second]!.isCollapsed)
        XCTAssertEqual(c.panels.count, 2, "los dos siguen en el historial; solo uno conectado")
    }

    @MainActor func test_abrir_dos_veces_sin_endTurn_no_crea_segundo_panel() throws {
        let c = Self.coordinator()
        let first = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        XCTAssertNil(c.openIfNeeded(toolName: "browser_open"), "dentro del mismo turno no hay segundo panel")
        XCTAssertEqual(c.panels.count, 1)
        c.endTurn()
        XCTAssertTrue(c.panels[first]!.isCollapsed)
    }

    /// Review Focus 2: sin i3 configurado, la fábrica devuelve nil y no aparece panel.
    @MainActor func test_sin_rele_no_aparece_panel() {
        let c = BrowserPanelCoordinator(stream: { nil })
        XCTAssertNil(c.openIfNeeded(toolName: "browser_open"))
        XCTAssertTrue(c.panels.isEmpty)
        XCTAssertNil(c.activeID)
    }

    func test_isBrowserTool_cubre_las_ocho_y_no_read_webpage() {
        for name in Agent.browserToolNames { XCTAssertTrue(BrowserPanelCoordinator.isBrowserTool(name), name) }
        // read_webpage no comparte sesión con el relé del i3 (sessioned: false) y conectar el
        // visor despertaría un Chromium que esa herramienta existe para evitar.
        XCTAssertFalse(BrowserPanelCoordinator.isBrowserTool("read_webpage"))
        XCTAssertFalse(BrowserPanelCoordinator.isBrowserTool("web_search"))
    }

    @MainActor func test_los_eventos_del_flujo_llegan_al_panel() async throws {
        var cont: AsyncStream<BrowserRelayEvent>.Continuation!
        let stream = AsyncStream<BrowserRelayEvent> { cont = $0 }
        let c = BrowserPanelCoordinator(stream: { stream })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        cont.yield(.state(live: true, collapsed: false))
        cont.yield(.narration("haciendo clic"))
        try await Self.waitUntil { c.panels[id]!.phrase == "haciendo clic" }
        XCTAssertTrue(c.panels[id]!.isLive)
    }

    /// El `.closed` no congela: el cliente reconecta y siguen llegando eventos.
    @MainActor func test_un_closed_no_congela_el_panel_y_el_siguiente_state_lo_revive() async throws {
        var cont: AsyncStream<BrowserRelayEvent>.Continuation!
        let stream = AsyncStream<BrowserRelayEvent> { cont = $0 }
        let c = BrowserPanelCoordinator(stream: { stream })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        cont.yield(.state(live: true, collapsed: false))
        try await Self.waitUntil { c.panels[id]!.isLive }
        cont.yield(.closed(reason: "relé cerrado"))
        try await Self.waitUntil { !c.panels[id]!.isLive }
        cont.yield(.state(live: true, collapsed: false))
        try await Self.waitUntil { c.panels[id]!.isLive }
        XCTAssertFalse(c.panels[id]!.isCollapsed)
    }

    /// Red de seguridad: si se pierde el `.closed` del búfer, terminar el flujo congela igual.
    @MainActor func test_al_terminar_el_flujo_el_panel_se_congela() async throws {
        var cont: AsyncStream<BrowserRelayEvent>.Continuation!
        let stream = AsyncStream<BrowserRelayEvent> { cont = $0 }
        let c = BrowserPanelCoordinator(stream: { stream })
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        cont.yield(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        try await Self.waitUntil { c.panels[id]!.jpeg != nil }
        cont.finish()
        try await Self.waitUntil { c.panels[id]!.isCollapsed }
        XCTAssertNil(c.panels[id]!.jpeg)
    }

    /// Mide la cancelación, no el congelado: `onTermination` solo se dispara si la tarea
    /// consumidora se cancela de verdad (lo que cierra el socket contra el i3).
    @MainActor func test_endTurn_cancela_la_tarea_que_consume_el_flujo() async throws {
        final class Flag: @unchecked Sendable { var terminated = false }
        let flag = Flag()
        let stream = AsyncStream<BrowserRelayEvent> { cont in
            cont.onTermination = { _ in flag.terminated = true }
        }
        let c = BrowserPanelCoordinator(stream: { stream })
        _ = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(flag.terminated, "mientras el turno sigue, el flujo sigue abierto")
        c.endTurn()
        try await Self.waitUntil { flag.terminated }
    }

    @MainActor private static func waitUntil(_ cond: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if cond() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condición no cumplida a tiempo")
    }
}
