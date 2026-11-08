import XCTest
@testable import Gemma

@MainActor
final class AgentSystemPromptTests: XCTestCase {
    final class CapturingRuntime: ToolCallingRuntime {
        var capturedSystem: String = ""
        var capturedPrompt: String = ""
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            capturedSystem = options.systemPrompt ?? ""
            capturedPrompt = prompt
            return AsyncThrowingStream { c in
                c.yield(.completed(GenerationResult(text: "ok", metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func test_system_prompt_has_no_save_memory_instruction() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertFalse(rt.capturedSystem.lowercased().contains("save_memory"),
                       "live-turn system prompt must not instruct the model to call save_memory")
        XCTAssertTrue(rt.capturedSystem.contains("Answer only what was asked"),
                      "the answer-only guidance stays")
    }

    func test_current_date_rides_the_tail_not_the_static_prefix() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        // JARVIS rework: the date is intentionally OUT of the static system prefix (kept byte-stable
        // for the APC prefix cache) and now rides the per-turn message tail via nowContext().
        XCTAssertFalse(rt.capturedSystem.contains(today), "static prefix must NOT carry the date")
        XCTAssertTrue(rt.capturedPrompt.contains(today), "the per-turn tail must carry today's date")
    }

    /// El prompt enumeraba `logins` entre las tareas del navegador, que es justo la clase de
    /// tarea que `browser_fill` prohíbe («PROHIBIDO usarla para contraseñas, tokens, claves o
    /// códigos de verificación») y para la que no ofrecía alternativa.
    func test_the_browser_line_does_not_send_the_model_to_do_logins() throws {
        let line = try XCTUnwrap(Agent.systemPromptText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains("browser_open(url)") }
            .map(String.init), "falta la línea del navegador en el prompt")
        XCTAssertFalse(line.contains("logins"), "el prompt no debe mandar al modelo a hacer logins: \(line)")
        // Las dos intenciones que este candado protege desde el principio: que no
        // teclee un secreto, y que diga qué hacer en su lugar en vez de dejar al
        // usuario colgado. Se afirman por intención y no por la frase literal: la
        // redacción cambió en 2026-11-08 y la versión vieja afirmaba palabras,
        // así que se puso roja por un cambio que conservaba las dos intenciones.
        XCTAssertTrue(line.contains("must not type is a password"),
                      "falta la prohibición de teclear una contraseña: \(line)")
        XCTAssertTrue(line.contains("ask them to do that step"),
                      "la cláusula debe decir qué hacer en su lugar: \(line)")
    }

    /// Regresión de 2026-11-08: el agente se negó a escribir la DIRECCIÓN DE CORREO
    /// del usuario en el portal de Gmail. La causa estaba en el prompt, no en el
    /// modelo: decía «If a page asks for credentials, say that you cannot sign in
    /// for them», y una página de acceso pide credenciales, así que la cláusula se
    /// disparaba con un campo que no es un secreto. El usuario lo dijo así: «se
    /// negó aunque sólo le pedí el correo no la contraseña… me puede dar un
    /// consejo, pero no se puede negar así».
    func test_el_prompt_no_convierte_un_campo_de_correo_en_una_negativa() throws {
        let p = Agent.systemPromptText
        XCTAssertTrue(p.contains("An email address is NOT a secret"),
                      "el prompt debe decir que una dirección de correo no es un secreto")
        XCTAssertFalse(p.contains("cannot sign in for them"),
                       "la negativa en bloque ante una página de acceso no debe volver")
        XCTAssertTrue(p.contains("Advice, not refusal"),
                      "el prompt debe pedir consejo en una línea y luego hacer lo pedido")
        XCTAssertTrue(p.contains("never dress a failure as a refusal"),
                      "un fallo de herramienta no se disfraza de negativa")
    }

    func test_system_prompt_asks_to_mention_all_matching_memories() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedSystem.localizedCaseInsensitiveContains("all of them"),
                      "prompt should tell the model to mention all matching memories, not only the newest")
    }
}
