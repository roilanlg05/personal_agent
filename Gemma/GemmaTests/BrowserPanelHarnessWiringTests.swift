import XCTest
@testable import Gemma

/// Pinta el CABLEADO entre el arnés y el coordinador de paneles. Las pruebas del coordinador
/// prueban su lógica; si nadie la llamara, el turno ordinario dejaría un panel vivo para siempre
/// y todas seguirían verdes. Estas pasan por `consumeAgentEvents`, el mismo bucle que usa
/// `runAgentTurn`, con un flujo de eventos falso (sin modelo ni red).
@MainActor
final class BrowserPanelHarnessWiringTests: XCTestCase {
    private static let ok = #"{"status":"success"}"#
    private static let fail = #"{"status":"error","message":"fallo"}"#

    /// Un coordinador cuyo flujo no termina (como el relé real) y el modelo que lo usa.
    private func makeModel(idle: Duration = BrowserPanelCoordinator.defaultLiveIdleLimit)
        -> (HarnessModel, AsyncStream<BrowserRelayEvent>.Continuation) {
        let (stream, cont) = AsyncStream<BrowserRelayEvent>.makeStream()
        // `almacen:` para no leer la entrada de producción del llavero: `init` → `ensureVoice()`
        // → el token del servicio de memoria.
        let model = HarnessModel(browserPanels: BrowserPanelCoordinator(stream: { (stream, MandoDeMentira()) }, liveIdleLimit: idle),
                                 almacen: AlmacenEnMemoria())
        return (model, cont)
    }

    private func turn(_ events: [AgentEvent], throwing error: Error? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            if let error { c.finish(throwing: error) } else { c.finish() }
        }
    }

    private func done() -> AgentEvent {
        .completed(GenerationResult(text: "listo", metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil)))
    }

    func test_un_turno_ordinario_que_deja_el_navegador_abierto_deja_el_panel_vivo() async {
        let (model, cont) = makeModel(); defer { cont.finish() }
        _ = await model.consumeAgentEvents(turn([
            .toolCallStarted(name: "browser_open", args: "{}"), .toolCallFinished(name: "browser_open", result: Self.ok), done()]))
        let panels = model.browserPanels
        XCTAssertNil(panels.activeID, "el turno acabó: no hay panel activo")
        XCTAssertNotNil(panels.livePanelID)
        XCTAssertFalse(panels.panels[panels.livePanelID!]!.isCollapsed)
    }

    /// El caso común: sin toolFinished cableado, este turno dejaría el panel vivo para siempre.
    func test_un_turno_que_cierra_el_navegador_congela_su_panel() async {
        let (model, cont) = makeModel(); defer { cont.finish() }
        _ = await model.consumeAgentEvents(turn([
            .toolCallStarted(name: "browser_open", args: "{}"), .toolCallFinished(name: "browser_open", result: Self.ok),
            .toolCallStarted(name: "browser_close", args: "{}"), .toolCallFinished(name: "browser_close", result: Self.ok), done()]))
        let panels = model.browserPanels
        XCTAssertNil(panels.livePanelID)
        XCTAssertNil(panels.activeID)
        XCTAssertEqual(panels.panels.count, 1)
        XCTAssertTrue(panels.panels.values.first!.isCollapsed)
    }

    func test_el_turno_que_falla_congela_aunque_el_navegador_siga_abierto() async {
        struct Boom: Error {}
        let (model, cont) = makeModel(); defer { cont.finish() }
        _ = await model.consumeAgentEvents(turn([
            .toolCallStarted(name: "browser_open", args: "{}"), .toolCallFinished(name: "browser_open", result: Self.ok)],
            throwing: Boom()))
        XCTAssertNil(model.browserPanels.livePanelID)
        XCTAssertNil(model.browserPanels.activeID)
        XCTAssertTrue(model.browserPanels.panels.values.first!.isCollapsed)
    }

    func test_el_turno_cancelado_congela_aunque_el_navegador_siga_abierto() async {
        let (model, cont) = makeModel(); defer { cont.finish() }
        _ = await model.consumeAgentEvents(turn([
            .toolCallStarted(name: "browser_open", args: "{}"), .toolCallFinished(name: "browser_open", result: Self.ok)],
            throwing: CancellationError()))
        XCTAssertNil(model.browserPanels.livePanelID)
        XCTAssertTrue(model.browserPanels.panels.values.first!.isCollapsed)
    }

    func test_un_browser_open_fallido_en_el_turno_no_deja_panel_vivo() async {
        let (model, cont) = makeModel(); defer { cont.finish() }
        _ = await model.consumeAgentEvents(turn([
            .toolCallStarted(name: "browser_open", args: "{}"), .toolCallFinished(name: "browser_open", result: Self.fail), done()]))
        XCTAssertNil(model.browserPanels.livePanelID)
    }

    /// Interrumpir un turno a medias congela su panel; el panel vivo de un turno anterior no se toca.
    func test_interrumpir_un_turno_a_medias_congela_su_panel_activo() throws {
        let (model, cont) = makeModel(); defer { cont.finish() }
        model.turnRunnerOverride = { _ in }
        let id = try XCTUnwrap(model.browserPanels.openIfNeeded(toolName: "browser_open"))
        model.browserPanels.toolFinished(toolName: "browser_open", result: Self.ok)
        model.startAgentTurn("otra cosa")
        XCTAssertNil(model.browserPanels.livePanelID)
        XCTAssertTrue(model.browserPanels.panels[id]!.isCollapsed)
    }

    func test_empezar_un_turno_nuevo_no_retira_el_panel_vivo_de_un_turno_anterior() async throws {
        let (model, cont) = makeModel(); defer { cont.finish() }
        model.turnRunnerOverride = { _ in }
        _ = await model.consumeAgentEvents(turn([
            .toolCallStarted(name: "browser_open", args: "{}"), .toolCallFinished(name: "browser_open", result: Self.ok), done()]))
        let live = try XCTUnwrap(model.browserPanels.livePanelID)
        model.startAgentTurn("gracias")
        XCTAssertEqual(model.browserPanels.livePanelID, live)
        XCTAssertFalse(model.browserPanels.panels[live]!.isCollapsed)
    }

    /// Hablarle al agente (startAgentTurn) reinicia el reloj del panel vivo.
    func test_hablarle_al_agente_reinicia_el_reloj_del_panel_vivo() async throws {
        let (model, cont) = makeModel(idle: .milliseconds(200)); defer { cont.finish() }
        model.turnRunnerOverride = { _ in }
        _ = await model.consumeAgentEvents(turn([
            .toolCallStarted(name: "browser_open", args: "{}"), .toolCallFinished(name: "browser_open", result: Self.ok), done()]))
        let live = try XCTUnwrap(model.browserPanels.livePanelID)
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(100))
            model.startAgentTurn("sigamos charlando")
        }
        XCTAssertEqual(model.browserPanels.livePanelID, live)
    }

    func test_un_chat_nuevo_tras_mucho_silencio_retira_el_panel_vivo() async throws {
        let (model, cont) = makeModel(); defer { cont.finish() }
        // `startNewChatIfIdle` escribe `activeThreadId` en los ajustes reales: se restaura.
        let saved = UserDefaults.standard.object(forKey: "activeThreadId")
        defer { UserDefaults.standard.set(saved, forKey: "activeThreadId") }
        _ = await model.consumeAgentEvents(turn([
            .toolCallStarted(name: "browser_open", args: "{}"), .toolCallFinished(name: "browser_open", result: Self.ok), done()]))
        let live = try XCTUnwrap(model.browserPanels.livePanelID)
        model.lastTurnEndedAt = 1_000
        model.startNewChatIfIdle(now: 1_000 + 60)          // poco silencio: sigue vivo
        XCTAssertEqual(model.browserPanels.livePanelID, live)
        model.startNewChatIfIdle(now: 1_000 + 1_801)       // más de 30 min: se retira
        XCTAssertNil(model.browserPanels.livePanelID)
        XCTAssertTrue(model.browserPanels.panels[live]!.isCollapsed)
    }
}
