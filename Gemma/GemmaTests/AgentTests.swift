import XCTest
@testable import Gemma

@MainActor
final class AgentTests: XCTestCase {
    /// Stub tool-calling runtime that emits a fixed event sequence.
    final class StubRuntime: ToolCallingRuntime {
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(.token("It is "))
                c.yield(.toolCallStarted(name: "get_current_time", args: "{}"))
                c.yield(.toolCallFinished(name: "get_current_time", result: "12:00"))
                c.yield(.token("12:00."))
                c.yield(.completed(GenerationResult(text: "It is 12:00.", metrics: RuntimeMetrics(tokensGenerated: 2, elapsedSeconds: 0.1, timeToFirstTokenSeconds: 0.05, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func test_run_relaysEventsAsAgentEvents() async throws {
        let agent = Agent(runtime: StubRuntime(), registry: ToolRegistry.withDefaults())
        var kinds: [String] = []
        var finalText: String?
        for try await event in agent.run(prompt: "what time is it?", options: GenerationOptions(maxTokens: 64)) {
            switch event {
            case .token: kinds.append("token")
            case .thought: break
            case .toolCallStarted(let n, _): kinds.append("start:\(n)")
            case .toolCallFinished(let n, _): kinds.append("done:\(n)")
            case .completed(let r): finalText = r.text; kinds.append("completed")
            case .failed(let m): XCTFail("unexpected failure: \(m)")
            }
        }
        XCTAssertEqual(kinds, ["token", "start:get_current_time", "done:get_current_time", "token", "completed"])
        XCTAssertEqual(finalText, "It is 12:00.")
    }

    /// New ServerRuntime semantics: call 1 surfaces a tool call and an EMPTY completed (the model
    /// stopped to call a tool); the runtime does NOT execute the tool or emit `.toolCallFinished`.
    /// The Agent must drive the loop: run the tool, emit `.toolCallFinished`, re-call → final text.
    func test_run_executesToolAndFinishes() async throws {
        final class TwoStepRuntime: ToolCallingRuntime {
            var call = 0
            var prompts: [String] = []
            func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
                call += 1
                prompts.append(prompt)
                let isFirst = call == 1
                return AsyncThrowingStream { c in
                    if isFirst { c.yield(.toolCallStarted(name: "get_current_time", args: "{}")) }
                    else { c.yield(.token("done")) }
                    c.yield(.completed(GenerationResult(text: isFirst ? "" : "done", metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    c.finish()
                }
            }
        }
        let runtime = TwoStepRuntime()
        let agent = Agent(runtime: runtime, registry: ToolRegistry.withDefaults())
        var sawToolFinished = false
        var toolResult = ""
        var finalText = ""
        for try await e in agent.run(prompt: "time?", options: GenerationOptions()) {
            if case .toolCallFinished(_, let r) = e { sawToolFinished = true; toolResult = r }
            if case .completed(let r) = e { finalText = r.text }
        }
        XCTAssertTrue(sawToolFinished)
        XCTAssertEqual(finalText, "done")
        // The tool result must be fed back: the runtime's SECOND call should receive a prompt
        // augmented with the bracketed tool-result note (this exercises the M1 prompt-augmentation
        // mechanism, which is otherwise untested).
        XCTAssertEqual(runtime.prompts.count, 2)
        let secondPrompt = runtime.prompts[1]
        XCTAssertTrue(secondPrompt.contains("get_current_time"), "second prompt should mention the called tool: \(secondPrompt)")
        XCTAssertTrue(secondPrompt.contains(toolResult), "second prompt should contain the tool result \(toolResult): \(secondPrompt)")
        XCTAssertTrue(secondPrompt.contains("it returned:"), "second prompt should contain the augmentation note: \(secondPrompt)")
    }

    /// Regression: the model returns BOTH visible text AND a requested-but-unexecuted tool call in
    /// the same iteration. The visible text must NOT cause the pending (side-effecting) tool call to
    /// be skipped — the Agent must still execute it before treating the turn as final.
    func test_run_executesToolEvenWhenModelAlsoReturnsText() async throws {
        final class TextPlusToolRuntime: ToolCallingRuntime {
            var call = 0
            func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
                call += 1
                let isFirst = call == 1
                return AsyncThrowingStream { c in
                    if isFirst {
                        c.yield(.token("Got it"))
                        c.yield(.toolCallStarted(name: "get_current_time", args: "{}"))
                        c.yield(.completed(GenerationResult(text: "Got it", metrics: .init(tokensGenerated: 1, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    } else {
                        c.yield(.token("It is 12:00."))
                        c.yield(.completed(GenerationResult(text: "It is 12:00.", metrics: .init(tokensGenerated: 1, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    }
                    c.finish()
                }
            }
        }
        let agent = Agent(runtime: TextPlusToolRuntime(), registry: ToolRegistry.withDefaults())
        var sawToolFinished = false
        var finalText = ""
        for try await e in agent.run(prompt: "time?", options: GenerationOptions()) {
            if case .toolCallFinished = e { sawToolFinished = true }
            if case .completed(let r) = e { finalText = r.text }
        }
        XCTAssertTrue(sawToolFinished, "pending tool must execute even though the model also emitted visible text")
        XCTAssertEqual(finalText, "It is 12:00.")
    }

    // MARK: - Herramientas de navegador: el bucle tiene que dejar conducir la página

    /// Runtime que pide SIEMPRE la misma herramienta y nunca la ejecuta. Sirve para medir
    /// cuántas rondas le concede el bucle a un turno y qué nota recibe el modelo. Como el
    /// registro que se le pasa va vacío, ninguna herramienta real llega a correr.
    final class RepeatingToolRuntime: ToolCallingRuntime {
        let toolName: String
        var prompts: [String] = []
        init(toolName: String) { self.toolName = toolName }
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            prompts.append(prompt)
            let name = toolName
            return AsyncThrowingStream { c in
                c.yield(.toolCallStarted(name: name, args: "{}"))
                c.yield(.completed(GenerationResult(text: "", metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    /// La nota de resultado es lo ÚLTIMO que el modelo lee, así que su `DO NOT call ... again`
    /// incondicional ganaba sobre la línea del prompt que enseña el bucle del navegador y
    /// mataba el turno después del primer `browser_open`.
    func test_browser_tool_note_lets_the_model_keep_driving_the_page() {
        let note = Agent.toolResultNote(toolName: "browser_open",
                                        args: #"{"url":"https://a.test"}"#,
                                        result: #"{"status":"success","title":"Ejemplo"}"#)
        XCTAssertTrue(note.contains(#"{"status":"success","title":"Ejemplo"}"#), "la nota sigue dando el resultado: \(note)")
        XCTAssertFalse(note.contains("DO NOT call"), "una herramienta de navegador no puede cerrar el turno: \(note)")
        XCTAssertTrue(note.contains("You MAY keep calling browser tools"), "falta el permiso de continuar: \(note)")
        XCTAssertTrue(note.contains("`browser_snapshot`"), "falta el paso siguiente: \(note)")
        XCTAssertTrue(note.contains("`browser_close`"), "falta cómo cerrar la tarea: \(note)")
        XCTAssertTrue(note.contains("NEVER volunteer the current date or time"), "la cláusula ortogonal se queda: \(note)")

        for name in Agent.browserToolNames {
            XCTAssertFalse(Agent.toolResultNote(toolName: name, args: "{}", result: "r").contains("DO NOT call"), name)
        }
        XCTAssertEqual(Agent.browserToolNames.count, 8)
    }

    /// Las otras ~71 herramientas dependen de esta frase: el modelo spameaba herramientas y
    /// la nota es lo que lo obliga a cerrar el turno. El literal va entero a propósito, para
    /// que cualquier cambio en la rama que NO sea de navegador rompa este test.
    func test_non_browser_tool_note_is_byte_for_byte_the_one_that_was_there() {
        XCTAssertEqual(Agent.toolResultNote(toolName: "web_search", args: #"{"query":"x"}"#, result: "ok"),
                       #"[You called the tool `web_search` with arguments {"query":"x"}; it returned: ok. Tool execution is complete for this action. Formulate your final response to the user in a natural, friendly sentence explaining this result. DO NOT call `web_search` or any other tool again. NEVER volunteer the current date or time.]"#)
        // `read_webpage` es de una sola llamada: le sirve la nota de cierre y queda fuera.
        XCTAssertFalse(Agent.browserToolNames.contains("read_webpage"))
        XCTAssertTrue(Agent.toolResultNote(toolName: "read_webpage", args: "{}", result: "ok").contains("DO NOT call"))
    }

    /// Un bucle de navegador realista (`open → snapshot → fill → snapshot → click → snapshot
    /// → get → close`) son ocho rondas; con las cinco de un turno normal no cabía.
    func test_a_turn_that_touches_the_browser_gets_a_bigger_iteration_budget() async throws {
        let normal = RepeatingToolRuntime(toolName: "web_search")
        for try await _ in Agent(runtime: normal, registry: ToolRegistry()).run(prompt: "x", options: GenerationOptions()) {}
        XCTAssertEqual(normal.prompts.count, Agent.maxIterations,
                       "el presupuesto de un turno sin navegador no cambia")

        let browser = RepeatingToolRuntime(toolName: "browser_open")
        for try await _ in Agent(runtime: browser, registry: ToolRegistry()).run(prompt: "x", options: GenerationOptions()) {}
        XCTAssertEqual(browser.prompts.count, Agent.maxBrowserIterations)
        XCTAssertGreaterThan(Agent.maxBrowserIterations, Agent.maxIterations)
        // Las herramientas se retiran en `iteration >= max - 2`, así que las rondas que de
        // verdad pueden llamar herramientas son `max - 1`: tienen que llegar a ocho.
        XCTAssertGreaterThanOrEqual(Agent.maxBrowserIterations - 1, 8)
    }

    /// Lo anterior por la vía larga: la nota del navegador llega de verdad al prompt vivo a
    /// través de `Agent.run`, que es lo que nada en la rama ejercitaba.
    func test_the_browser_note_reaches_the_live_prompt_through_the_loop() async throws {
        let runtime = RepeatingToolRuntime(toolName: "browser_snapshot")
        for try await _ in Agent(runtime: runtime, registry: ToolRegistry()).run(prompt: "abre la página", options: GenerationOptions()) {}
        let second = try XCTUnwrap(runtime.prompts.dropFirst().first, "el bucle no volvió a llamar al modelo")
        XCTAssertTrue(second.contains("You MAY keep calling browser tools"), "prompt: \(second)")
        XCTAssertFalse(second.contains("DO NOT call"), "prompt: \(second)")
    }
}
