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
    }

    func test_initiative_stays_within_the_request_and_authorization() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedSystem.contains("Take initiative within the user's request and existing authorization."))
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
        XCTAssertTrue(line.contains("Never ask for a secret in the chat") && line.contains("If the user pastes one anyway, do not type it with `browser_fill`"),
                      "falta la prohibición de pedir un secreto por el chat o de teclear con browser_fill uno pegado: \(line)")
        XCTAssertTrue(line.contains("`present_form`") && line.contains("`browser_fill_secret`"),
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

    /// Regresión del chat de YouTube del 2026-11-08, en su TERCERA forma. Historia, porque
    /// explica por qué este test cambió de intención:
    ///
    ///   1. El prompt decía «Call `browser_close` when done» y la nota de resultado mandaba
    ///      cerrar sin condición. El usuario escribió «no cierres el navegador hasta que no
    ///      termine el video o yo te aviso» y el agente cerró igual.
    ///   2. Se hizo condicional: cerrar solo si la página era un medio para una respuesta ya
    ///      dada, y la nota pasó a ceder ante lo que el usuario hubiera dicho. El agente volvió
    ///      a cerrar, esta vez diciendo él mismo que lo dejaría abierto.
    ///   3. El usuario pidió «ábreme la Wikipedia con la página de anatomía PARA LEERLA» y el
    ///      agente la cerró al terminar el turno.
    ///
    /// Dos intentos en el prompt, dos vueltas del defecto. La conclusión es la misma que en la
    /// puerta de compra: un prompt es una petición, no un candado. El candado vive ahora en la
    /// app (`BrowserCloseIntent` + `BrowserCloseTool`), que no cierra nada si el usuario no lo
    /// ha pedido en este turno.
    ///
    /// POR ESO ESTE TEST CAMBIÓ DE INTENCIÓN, y se deja dicho aquí para quien lo lea después.
    /// La versión anterior exigía que toda mención de `browser_close` llevara una condición —
    /// protegía un prompt que SÍ mandaba cerrar, con cuidado. La intención ahora es más fuerte y
    /// más simple: el prompt NO manda cerrar en ningún caso, y además le dice al modelo que un
    /// `refused` es la respuesta correcta y no algo que reintentar. Las anclas se re-apuntaron a
    /// las palabras nuevas que llevan esa intención, como la propia versión anterior pedía que
    /// se hiciera en lugar de borrar el test.
    ///
    /// Qué protege, en el prompt Y en la nota de resultado (que se añade la última y gana sobre
    /// el prompt, así que de nada serviría arreglar solo uno):
    ///   (A) ninguna de las dos manda cerrar: no queda ninguna oración imperativa que diga
    ///       «llama a browser_close».
    ///   (B) las dos dicen que el modelo no es quien cierra.
    ///   (C) las dos nombran el `refused` como correcto, para que el modelo no entre en un bucle
    ///       de reintentos contra un candado que nunca va a ceder.
    func test_el_prompt_no_manda_cerrar_el_navegador_en_ningun_caso() throws {
        let linea = try XCTUnwrap(Agent.systemPromptText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains("browser_open(url)") }.map(String.init))
        let nota = Agent.toolResultNote(toolName: "browser_open", result: "ok")

        for (texto, donde) in [(linea, "prompt"), (nota, "nota")] {
            let t = texto.lowercased()
            // (A) ninguna orden de cerrar. Se comprueba por oración para que una frase que
            // NIEGA el cierre («you do not close the browser») no cuente como orden.
            let oraciones = t.components(separatedBy: CharacterSet(charactersIn: ".:;\n"))
            for o in oraciones where o.contains("browser_close") {
                XCTAssertFalse(o.contains("call `browser_close` when") || o.contains("call `browser_close` only when"),
                               "\(donde): sigue mandando cerrar: \(o)")
            }
            // (B) dice que no es él quien cierra.
            XCTAssertTrue(t.contains("you do not close") || t.contains("you don't close")
                          || t.contains("leave the browser open"),
                          "\(donde): debe decir que el modelo no cierra el navegador: \(texto)")
            // (C) el `refused` es correcto, no un fallo que reintentar.
            XCTAssertTrue(t.contains("refused"),
                          "\(donde): debe nombrar el `refused` del candado: \(texto)")
            XCTAssertTrue(t.contains("not an error to retry") || t.contains("must not be retried")
                          || t.contains("correct behaviour"),
                          "\(donde): debe decir que el `refused` no se reintenta: \(texto)")
        }
    }

    func test_system_prompt_asks_to_mention_all_matching_memories() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedSystem.localizedCaseInsensitiveContains("all of them"),
                      "prompt should tell the model to mention all matching memories, not only the newest")
    }
}
