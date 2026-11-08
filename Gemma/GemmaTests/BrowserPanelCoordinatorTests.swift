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
        Self.closeBrowser(c)
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
        Self.closeBrowser(c)
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
        Self.closeBrowser(c)
        c.endTurn()
        try await Self.waitUntil { flag.terminated }
    }

    // MARK: - El panel sobrevive al turno si el navegador sigue abierto

    private static let closeOK = #"{"status":"success","message":"Navegador cerrado."}"#

    /// Lo que hace el arnés cuando el agente llama a `browser_close` y termina bien.
    @MainActor private static func closeBrowser(_ c: BrowserPanelCoordinator) {
        _ = c.openIfNeeded(toolName: "browser_close")
        c.toolFinished(toolName: "browser_close", result: closeOK)
    }

    /// Fábrica que reparte un flujo controlable por panel y recuerda las banderas de terminación.
    @MainActor private final class Rig {
        final class Flags: @unchecked Sendable { var terminated: [Bool] = [] }
        var conts: [AsyncStream<BrowserRelayEvent>.Continuation] = []
        let flags = Flags()
        lazy var coordinator = BrowserPanelCoordinator(stream: { [self] in
            let n = conts.count
            flags.terminated.append(false)
            let flags = self.flags
            let stream = AsyncStream<BrowserRelayEvent> { cont in
                cont.onTermination = { _ in flags.terminated[n] = true }
                self.conts.append(cont)
            }
            return stream
        })
    }

    @MainActor func test_turno_que_termina_con_el_navegador_abierto_deja_el_panel_vivo_y_consumiendo() async throws {
        let rig = Rig(); let c = rig.coordinator
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        rig.conts[0].yield(.state(live: true, collapsed: false))
        try await Self.waitUntil { c.panels[id]!.isLive }
        c.endTurn()
        XCTAssertNil(c.activeID)
        XCTAssertEqual(c.livePanelID, id)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(rig.flags.terminated[0], "el visor no se va: el video sigue a la vista")
        XCTAssertTrue(c.panels[id]!.isLive)
        // Y sigue recibiendo: no es una foto congelada que se dice en vivo.
        rig.conts[0].yield(.frame(seq: 7, jpeg: Data([0x07]), capturedAt: .now))
        try await Self.waitUntil { c.panels[id]!.jpeg == Data([0x07]) }
    }

    @MainActor func test_turno_que_termina_con_browser_close_congela_como_antes() async throws {
        let rig = Rig(); let c = rig.coordinator
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        rig.conts[0].yield(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        try await Self.waitUntil { c.panels[id]!.jpeg != nil }
        _ = c.openIfNeeded(toolName: "browser_close")
        c.toolFinished(toolName: "browser_close", result: Self.closeOK)
        c.endTurn()
        XCTAssertNil(c.livePanelID)
        XCTAssertTrue(c.panels[id]!.isCollapsed)
        XCTAssertNil(c.panels[id]!.jpeg)
        try await Self.waitUntil { rig.flags.terminated[0] }
    }

    @MainActor func test_un_browser_close_que_falla_no_congela_un_navegador_que_sigue_abierto() throws {
        let rig = Rig(); let c = rig.coordinator
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        _ = c.openIfNeeded(toolName: "browser_close")
        c.toolFinished(toolName: "browser_close", result: #"{"status":"error","message":"servicio caído"}"#)
        c.toolFinished(toolName: "browser_close", result: "no es json")
        c.endTurn()
        XCTAssertEqual(c.livePanelID, id)
    }

    @MainActor func test_un_turno_que_no_acaba_por_su_pie_congela_aunque_el_navegador_siga_abierto() async throws {
        let rig = Rig(); let c = rig.coordinator
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        c.endTurn(survive: false)
        XCTAssertNil(c.livePanelID)
        XCTAssertTrue(c.panels[id]!.isCollapsed)
        try await Self.waitUntil { rig.flags.terminated[0] }
    }

    @MainActor func test_abrir_otra_vez_tras_cerrar_en_el_mismo_turno_deja_el_navegador_abierto() throws {
        let rig = Rig(); let c = rig.coordinator
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        Self.closeBrowser(c)
        _ = c.openIfNeeded(toolName: "browser_open")
        c.endTurn()
        XCTAssertEqual(c.livePanelID, id)
    }

    @MainActor func test_un_panel_pasado_congelado_sigue_congelado_y_conviven_con_el_vivo() async throws {
        let rig = Rig(); let c = rig.coordinator
        let old = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        Self.closeBrowser(c)
        c.endTurn()                                   // turno 1: cerrado -> congelado
        let live = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        c.endTurn()                                   // turno 2: abierto -> vivo
        XCTAssertEqual(c.panels.count, 2)
        XCTAssertTrue(c.panels[old]!.isCollapsed)
        XCTAssertFalse(c.panels[live]!.isCollapsed)
        XCTAssertEqual(c.livePanelID, live)
        // Un frame tardío del flujo viejo no resucita el panel congelado.
        rig.conts[0].yield(.state(live: true, collapsed: false))
        rig.conts[0].yield(.frame(seq: 9, jpeg: Data([0x09]), capturedAt: .now))
        rig.conts[1].yield(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        try await Self.waitUntil { c.panels[live]!.jpeg != nil }
        XCTAssertNil(c.panels[old]!.jpeg)
        XCTAssertFalse(c.panels[old]!.isLive)
    }

    @MainActor func test_el_panel_vivo_se_retira_cuando_el_turno_siguiente_abre_otro() async throws {
        let rig = Rig(); let c = rig.coordinator
        let first = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        c.endTurn()
        XCTAssertEqual(c.livePanelID, first)
        let second = try XCTUnwrap(c.openIfNeeded(toolName: "browser_click"))
        XCTAssertNotEqual(first, second)
        XCTAssertNil(c.livePanelID, "el viejo ya no es el vivo")
        XCTAssertTrue(c.panels[first]!.isCollapsed)
        XCTAssertFalse(c.panels[second]!.isCollapsed)
        try await Self.waitUntil { rig.flags.terminated[0] }
        XCTAssertFalse(rig.flags.terminated[1])
    }

    @MainActor func test_el_browser_close_de_un_turno_posterior_deja_congelado_el_panel_que_abrio() async throws {
        let rig = Rig(); let c = rig.coordinator
        let first = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        c.endTurn()                                   // video en marcha, panel vivo
        let second = try XCTUnwrap(c.openIfNeeded(toolName: "browser_close"))
        c.toolFinished(toolName: "browser_close", result: Self.closeOK)
        c.endTurn()
        XCTAssertNil(c.livePanelID)
        XCTAssertTrue(c.panels[first]!.isCollapsed)
        XCTAssertTrue(c.panels[second]!.isCollapsed)
        try await Self.waitUntil { rig.flags.terminated[0] && rig.flags.terminated[1] }
    }

    @MainActor func test_si_el_flujo_del_panel_vivo_termina_el_panel_se_congela() async throws {
        let rig = Rig(); let c = rig.coordinator
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        rig.conts[0].yield(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
        try await Self.waitUntil { c.panels[id]!.jpeg != nil }
        c.endTurn()
        rig.conts[0].finish()                         // el cliente se rindió tras sus reintentos
        try await Self.waitUntil { c.panels[id]!.isCollapsed }
        XCTAssertNil(c.panels[id]!.jpeg)
    }

    @MainActor func test_retireLivePanel_congela_y_corta_el_flujo() async throws {
        let rig = Rig(); let c = rig.coordinator
        let id = try XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
        c.endTurn()
        c.retireLivePanel()
        XCTAssertNil(c.livePanelID)
        XCTAssertTrue(c.panels[id]!.isCollapsed)
        try await Self.waitUntil { rig.flags.terminated[0] }
    }

    @MainActor private static func waitUntil(_ cond: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if cond() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condición no cumplida a tiempo")
    }
}
