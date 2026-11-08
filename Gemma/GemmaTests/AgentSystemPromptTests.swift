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

    /// Regresión del chat de YouTube del 2026-11-08: el usuario escribió «no cierres el
    /// navegador hasta que no termine el video o yo te aviso» y el agente lo cerró igual,
    /// porque tanto el prompt («Call `browser_close` when done») como la nota de resultado
    /// (que se añade la última y el propio código declara que gana sobre el prompt) mandaban
    /// cerrar sin condición. Cerrar se trataba como limpieza, pero si lo pedido ES un estado
    /// que el usuario sigue mirando, cerrar destruye el entregable.
    ///
    /// Qué protege este test: DOS propiedades del texto, no una redacción.
    ///   (A) cerrar el navegador es condicional: ninguna mención de `browser_close` es una
    ///       orden incondicional, y el texto nombra el caso en que lo pedido es algo que el
    ///       usuario sigue mirando (un vídeo, una página, un carrito).
    ///   (B) la nota de resultado —que se añade la última y el código declara que gana sobre el
    ///       prompt— cede ante lo que el usuario dijo, incluida la orden de dejar el navegador
    ///       abierto. De nada sirve que solo el prompt ceda si la nota no lo hace.
    ///
    /// Los asertos de abajo usan fragmentos literales (`keep looking at`, `leave the browser
    /// open`, `outranks this note`) porque sobre prosa no se puede afirmar nada sin alguna
    /// palabra: SON ANCLAS de esas dos propiedades, no la propiedad misma. Si alguien reescribe
    /// la nota y este test se pone rojo, la reacción correcta es releer (A) y (B), comprobar que
    /// la nueva redacción las conserva y RE-APUNTAR las anclas a las palabras nuevas que las
    /// llevan; no borrar el test ni forzar la redacción antigua. Ya se perdió un día con un test
    /// de prompt que se puso rojo ante una reescritura que conservaba el sentido (ver el de
    /// logins, arriba).
    ///
    /// Además se comprueba (A) por estructura —cada oración con `browser_close` lleva una
    /// condición— y no solo por palabras, que es la parte menos frágil.
    func test_cerrar_el_navegador_es_condicional_y_cede_ante_el_usuario() throws {
        func sentences(_ text: String) -> [String] {
            text.components(separatedBy: CharacterSet(charactersIn: ".:;\n")).map { $0.lowercased() }
        }
        func assertEveryCloseIsConditional(_ text: String, _ donde: String) {
            let closes = sentences(text).filter { $0.contains("browser_close") }
            XCTAssertFalse(closes.isEmpty, "\(donde): debe seguir explicando cómo cerrar")
            for c in closes {
                XCTAssertTrue(["only when", "only if", "unless", "if ", "when what", "when the page"].contains { c.contains($0) } || c.contains("means to"),
                              "\(donde): `browser_close` aparece sin condición: \(c)")
            }
        }
        let linea = try XCTUnwrap(Agent.systemPromptText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains("browser_open(url)") }.map(String.init))
        assertEveryCloseIsConditional(linea, "prompt")

        let nota = Agent.toolResultNote(toolName: "browser_open", args: "{}", result: "ok")
        assertEveryCloseIsConditional(nota, "nota")
        let n = nota.lowercased()
        XCTAssertTrue(n.contains("keep looking at") || n.contains("keep watching"),
                      "la nota debe nombrar el caso en que lo pedido se sigue mirando: \(nota)")
        XCTAssertTrue(n.contains("leave the browser open") || n.contains("leave it open"),
                      "la nota debe nombrar la instrucción del usuario de dejarlo abierto: \(nota)")
        XCTAssertTrue(n.contains("outranks this note"),
                      "la nota debe ceder ante lo que dijo el usuario: \(nota)")
    }

    func test_system_prompt_asks_to_mention_all_matching_memories() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedSystem.localizedCaseInsensitiveContains("all of them"),
                      "prompt should tell the model to mention all matching memories, not only the newest")
    }
}
