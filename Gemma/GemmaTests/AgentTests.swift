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
        // El conjunto es el INVENTARIO de herramientas de navegador, no un numero: lo que esta
        // prueba necesita es que el bucle de arriba haya recorrido TODAS las que la app
        // registra. Escrito a mano («count == 8») se quedaba viejo en cuanto apareciera la
        // novena y se ponia rojo sin decir por que; derivado del registro, una herramienta
        // nueva entra sola en el bucle, y si alguien la registra sin anadirla a
        // `browserToolNames` el fallo nombra cual falta.
        let registradas = Set(HarnessModel.browserToolRegistry().tools
            .map { type(of: $0).name }
            .filter { $0.hasPrefix("browser_") })
        XCTAssertEqual(Agent.browserToolNames, registradas)
        XCTAssertFalse(registradas.isEmpty, "sin inventario el bucle de arriba no comprueba nada")
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

    // MARK: - Cortar la cola de acciones cuando la página cambia

    /// Herramienta de navegador de prueba: devuelve un resultado fijo y cuenta las veces que
    /// se ejecutó. Hacen falta DOS tipos (uno por nombre) porque `AgentTool.name` es estática.
    final class FakeBrowserOpen: AgentTool {
        static let name = "browser_open"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        nonisolated(unsafe) static var resultado = #"{"status":"success","url":"https://a.test/"}"#
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    final class FakeBrowserFill: AgentTool {
        static let name = "browser_fill"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return #"{"status":"success","message":"Campo '@e9' rellenado."}"#
        }
    }

    final class FakeBrowserClick: AgentTool {
        static let name = "browser_click"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        nonisolated(unsafe) static var resultado = #"{"status":"success","url":"https://b.test/x","message":"Clic ejecutado en '@e3'."}"#
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    /// Runtime que pide VARIAS acciones en la MISMA ronda, guionizadas ronda a ronda. Es lo que
    /// `RepeatingToolRuntime` no puede hacer (pide una sola) y es justo el caso que el corte
    /// gobierna. Una ronda vacía termina el turno.
    final class ScriptedRuntime: ToolCallingRuntime {
        var rondas: [[(name: String, args: String)]]
        var prompts: [String] = []
        private var ronda = 0
        init(_ rondas: [[(name: String, args: String)]]) { self.rondas = rondas }
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            prompts.append(prompt)
            let calls = ronda < rondas.count ? rondas[ronda] : []
            ronda += 1
            return AsyncThrowingStream { c in
                for call in calls { c.yield(.toolCallStarted(name: call.name, args: call.args)) }
                c.yield(.completed(GenerationResult(text: calls.isEmpty ? "listo" : "",
                                                    metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    private func registroDeNavegadorFalso() -> ToolRegistry {
        FakeBrowserOpen.calls = 0
        FakeBrowserClick.calls = 0
        FakeBrowserFill.calls = 0
        let r = ToolRegistry()
        r.register(FakeBrowserOpen())
        r.register(FakeBrowserClick())
        r.register(FakeBrowserFill())
        return r
    }

    /// Marca estable del aviso de corte, DERIVADA del propio aviso: así el test no vuelve a
    /// escribir a mano un texto que ya vive en `BrowserRules` (que es su única fuente).
    private var marcaDelCorte: String {
        String(BrowserRules.queueCutNote(tras: "browser_open", pendientes: ["browser_click"]).prefix(40))
    }

    /// Abrir una página es navegar por definición: el documento es otro y las `@eN` de
    /// cualquier snapshot anterior apuntan a elementos que ya no existen. Corta incluso
    /// aterrizando en la MISMA URL, porque una recarga también destruye las referencias.
    func test_cortaLaCola_navegar_invalida_las_referencias() {
        XCTAssertTrue(Agent.cortaLaCola(trasHerramienta: "browser_open",
                                        resultado: #"{"status":"success","url":"https://b.test/"}"#,
                                        urlConocida: "https://a.test/"))
        XCTAssertTrue(Agent.cortaLaCola(trasHerramienta: "browser_open",
                                        resultado: #"{"status":"success","url":"https://a.test/"}"#,
                                        urlConocida: "https://a.test/"))
        // Cerrar mata la sesión entera: su propia descripción dice que las `@eN` dejan de valer.
        XCTAssertTrue(Agent.cortaLaCola(trasHerramienta: "browser_close",
                                        resultado: #"{"status":"success","message":"Navegador cerrado."}"#,
                                        urlConocida: "https://a.test/"))
    }

    /// Las herramientas que LEEN la página no cortan nunca, ni aunque el resultado traiga una
    /// URL distinta: un snapshot es justo el paso con el que el modelo se recupera de un
    /// corte, y cortar detrás de él convertiría el arreglo en un bucle.
    func test_cortaLaCola_leer_la_pagina_no_corta_nunca() {
        XCTAssertFalse(Agent.browserReadOnlyToolNames.isEmpty)
        XCTAssertTrue(Agent.browserReadOnlyToolNames.isSubset(of: Agent.browserToolNames))
        for nombre in Agent.browserReadOnlyToolNames {
            XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: nombre,
                                             resultado: #"{"status":"success","url":"https://b.test/"}"#,
                                             urlConocida: "https://a.test/"),
                           nombre)
        }
    }

    /// Una acción sobre la página corta SI el resultado demuestra que la página cambió, y no
    /// corta si demuestra que no cambió. Es el caso del encargo: `click` que navega.
    func test_cortaLaCola_una_accion_corta_solo_si_la_pagina_cambio() {
        XCTAssertTrue(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                        resultado: #"{"status":"success","url":"https://b.test/x"}"#,
                                        urlConocida: "https://a.test/"))
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                         resultado: #"{"status":"success","url":"https://a.test/"}"#,
                                         urlConocida: "https://a.test/"))
    }

    /// Dirección segura: ante un resultado sin URL, ilegible o fallido, NO se corta. Incluye
    /// lo que las herramientas de interacción devuelven HOY de verdad (status + message, sin
    /// URL): mientras sea así, el corte por URL no se dispara detrás de ellas.
    func test_cortaLaCola_la_duda_no_corta() {
        let conocida = "https://a.test/"
        // Lo que `BrowserClickTool` devuelve hoy: ni una URL.
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                         resultado: #"{"status":"success","message":"Clic ejecutado en '@e3'."}"#,
                                         urlConocida: conocida))
        // Resultado que no es JSON (p. ej. el `error: no tool named …` del propio bucle).
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                         resultado: "error: no tool named browser_click",
                                         urlConocida: conocida))
        // La acción falló: no pasó nada que pueda invalidar una referencia.
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                         resultado: #"{"status":"error","url":"https://b.test/x"}"#,
                                         urlConocida: conocida))
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_open",
                                         resultado: #"{"status":"error","message":"timeout"}"#,
                                         urlConocida: conocida))
        // `browser_close` rechazado por el candado de la app: la página sigue abierta.
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_close",
                                         resultado: #"{"status":"refused","message":"No se ha cerrado"}"#,
                                         urlConocida: conocida))
        // No sabíamos en qué página estábamos: un cambio no se puede demostrar.
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                         resultado: #"{"status":"success","url":"https://b.test/x"}"#,
                                         urlConocida: nil))
        // Una herramienta que no es del navegador no manda sobre las `@eN`.
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "web_search",
                                         resultado: #"{"status":"success","url":"https://b.test/"}"#,
                                         urlConocida: conocida))
    }

    /// EL DEFECTO. El modelo pide `browser_open` + `browser_click` en la misma ronda: el clic
    /// lleva una `@eN` de la página anterior, así que no se ejecuta. Y lo que queda sin
    /// ejecutar NO se descarta en silencio: el aviso viaja en la nota con cuántas acciones
    /// quedaron y por qué.
    func test_la_cola_se_corta_cuando_la_pagina_cambia_y_el_modelo_se_entera() async throws {
        let runtime = ScriptedRuntime([
            [(name: "browser_open", args: #"{"url":"https://a.test/"}"#),
             (name: "browser_click", args: #"{"selector":"@e3"}"#)],
            []
        ])
        let registro = registroDeNavegadorFalso()
        for try await _ in Agent(runtime: runtime, registry: registro).run(prompt: "x", options: GenerationOptions()) {}

        XCTAssertEqual(FakeBrowserOpen.calls, 1, "la primera acción de la ronda sí se ejecuta")
        XCTAssertEqual(FakeBrowserClick.calls, 0, "el clic llevaba una referencia de la página anterior")
        let segundo = try XCTUnwrap(runtime.prompts.dropFirst().first, "el bucle no volvió a llamar al modelo")
        XCTAssertTrue(segundo.contains(BrowserRules.queueCutNote(tras: "browser_open", pendientes: ["browser_click"])),
                      "el modelo tiene que recibir el aviso del corte, con la cuenta y el motivo")
    }

    /// Y lo vuelve a pedir: la acción cortada NUNCA se ejecutó, así que el siguiente intento
    /// tiene que correr de verdad. Si algún freno la tomara por repetida, habríamos cambiado
    /// un defecto por otro peor (una acción que ya nadie puede ejecutar en el turno).
    func test_la_accion_cortada_se_puede_volver_a_pedir() async throws {
        let runtime = ScriptedRuntime([
            [(name: "browser_open", args: #"{"url":"https://a.test/"}"#),
             (name: "browser_click", args: #"{"selector":"@e3"}"#)],
            [(name: "browser_click", args: #"{"selector":"@e3"}"#)],
            []
        ])
        let registro = registroDeNavegadorFalso()
        for try await _ in Agent(runtime: runtime, registry: registro).run(prompt: "x", options: GenerationOptions()) {}

        XCTAssertEqual(FakeBrowserClick.calls, 1, "el clic re-pedido tiene que ejecutarse")
        let tercero = try XCTUnwrap(runtime.prompts.dropFirst(2).first, "faltó la tercera ronda")
        XCTAssertTrue(tercero.contains("Clic ejecutado"), "el resultado real del clic: \(tercero.suffix(400))")
        XCTAssertFalse(tercero.contains("DUPLICATE_CALL_IGNORED"),
                       "una acción que no se ejecutó no es una repetición")
    }

    /// Una ronda con UNA sola acción se comporta igual que hoy: se ejecuta y no hay aviso de
    /// corte, porque detrás de ella no quedaba nada en la cola.
    func test_una_ronda_de_una_sola_accion_no_cambia() async throws {
        let runtime = ScriptedRuntime([
            [(name: "browser_open", args: #"{"url":"https://a.test/"}"#)],
            [(name: "browser_click", args: #"{"selector":"@e3"}"#)],
            []
        ])
        let registro = registroDeNavegadorFalso()
        for try await _ in Agent(runtime: runtime, registry: registro).run(prompt: "x", options: GenerationOptions()) {}

        XCTAssertEqual(FakeBrowserOpen.calls, 1)
        XCTAssertEqual(FakeBrowserClick.calls, 1)
        for prompt in runtime.prompts {
            XCTAssertFalse(prompt.contains(marcaDelCorte), "no había cola que cortar: \(prompt.suffix(300))")
        }
        let segundo = try XCTUnwrap(runtime.prompts.dropFirst().first)
        XCTAssertTrue(segundo.contains(Agent.toolResultNote(toolName: "browser_open",
                                                            args: #"{"url":"https://a.test/"}"#,
                                                            result: FakeBrowserOpen.resultado)),
                      "la nota de resultado de siempre sigue entera")
    }

    /// El aviso del corte es una regla del navegador, así que vive en `BrowserRules` (su única
    /// fuente), dice CUÁNTAS acciones quedaron y no se lee como un fallo del modelo.
    func test_el_aviso_del_corte_cuenta_lo_que_quedo_y_no_culpa_al_modelo() {
        let una = BrowserRules.queueCutNote(tras: "browser_open", pendientes: ["browser_click"])
        XCTAssertTrue(una.contains("browser_click"), una)
        XCTAssertTrue(una.contains("browser_open"), una)
        XCTAssertTrue(una.contains("browser_snapshot"), "el paso de recuperación: \(una)")
        XCTAssertTrue(una.contains("1"), "la cuenta de lo que quedó sin ejecutar: \(una)")

        let dos = BrowserRules.queueCutNote(tras: "browser_click", pendientes: ["browser_fill", "browser_press"])
        XCTAssertTrue(dos.contains("2"), dos)
        XCTAssertTrue(dos.contains("browser_fill") && dos.contains("browser_press"), dos)
        XCTAssertNotEqual(una, dos)
    }

    /// El caso literal del encargo, y el que obliga a RECORDAR la URL de una ronda a la
    /// siguiente: el modelo abre la pagina en una ronda y en la siguiente pide `browser_click`
    /// + `browser_fill`; el clic navega, asi que el `@e9` del fill es de la pagina vieja. Sin
    /// memoria de la URL entre rondas no habria con que comparar y el fill se ejecutaria.
    func test_la_url_conocida_cruza_las_rondas_y_el_fill_no_se_ejecuta() async throws {
        let runtime = ScriptedRuntime([
            [(name: "browser_open", args: #"{"url":"https://a.test/"}"#)],
            [(name: "browser_click", args: #"{"selector":"@e3"}"#),
             (name: "browser_fill", args: #"{"selector":"@e9","value":"hola"}"#)],
            []
        ])
        let registro = registroDeNavegadorFalso()
        for try await _ in Agent(runtime: runtime, registry: registro).run(prompt: "x", options: GenerationOptions()) {}

        XCTAssertEqual(FakeBrowserOpen.calls, 1)
        XCTAssertEqual(FakeBrowserClick.calls, 1, "el clic es la accion que si se ejecuta")
        XCTAssertEqual(FakeBrowserFill.calls, 0, "el `@e9` era de la pagina de antes del clic")
        let tercero = try XCTUnwrap(runtime.prompts.dropFirst(2).first, "falto la tercera ronda")
        XCTAssertTrue(tercero.contains(BrowserRules.queueCutNote(tras: "browser_click", pendientes: ["browser_fill"])),
                      "el aviso del corte tiene que llegar al prompt vivo")
    }

    // MARK: - Presupuesto de fallos consecutivos, contado POR ACCION

    /// Herramienta de navegador que SIEMPRE falla, con el contrato de estados real de las
    /// herramientas (`AgentBrowserToolOutput`: `status` + `message`). El motivo es largo a
    /// proposito: es lo que mide que el error vuelve al modelo entero.
    final class FakeBrowserAlwaysFails: AgentTool {
        static let name = "browser_press"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        /// Mas largo que el recorte de browser-use (100 + 100 caracteres), para que un recorte
        /// se note.
        static let motivo = "El navegador devolvio una respuesta ilegible: "
            + String(repeating: "abcdefghij", count: 40)
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return "{\"status\":\"error\",\"message\":\"\(Self.motivo)\"}"
        }
    }

    /// Herramienta que NO es del navegador y siempre tiene exito.
    final class FakeOkSearch: AgentTool {
        static let name = "web_search"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        static let resultado = #"{"status":"success","message":"ok"}"#
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    /// Herramienta que NO es del navegador y siempre falla. `read_webpage` esta registrada en la
    /// app pero NO es del navegador (`browserToolNames` no la contiene), asi que sirve para
    /// medir que el presupuesto no es una regla del navegador sino del bucle.
    final class FakeFailingRead: AgentTool {
        static let name = "read_webpage"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        static let resultado = #"{"status":"error","message":"la pagina no respondio"}"#
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    private func registroConLaQueFalla() -> ToolRegistry {
        FakeBrowserAlwaysFails.calls = 0
        let r = registroDeNavegadorFalso()
        r.register(FakeBrowserAlwaysFails())
        return r
    }

    private func pulsaciones(_ rango: Range<Int>) -> [(name: String, args: String)] {
        rango.map { (name: "browser_press", args: "{\"key\":\"Enter\",\"n\":\($0)}") }
    }

    /// Recoge de un turno lo que el USUARIO acaba viendo: los textos finales y los errores.
    private func ejecuta(_ runtime: ScriptedRuntime,
                         _ registro: ToolRegistry) async throws -> (completados: [String], fallados: [String]) {
        var completados: [String] = []
        var fallados: [String] = []
        for try await e in Agent(runtime: runtime, registry: registro).run(prompt: "x", options: GenerationOptions()) {
            if case .completed(let r) = e { completados.append(r.text) }
            if case .failed(let m) = e { fallados.append(m) }
        }
        return (completados, fallados)
    }

    /// LA PRUEBA QUE LA IMPLEMENTACION DE BROWSER-USE NO PASARIA. En su `_post_process` el
    /// contador de fallos solo sube si el paso tuvo EXACTAMENTE una accion, asi que una ronda
    /// con seis acciones todas fallidas cuenta cero y el tope no acota el peor caso. Aqui se
    /// cuenta por accion: la sexta ya no se ejecuta.
    func test_cinco_acciones_fallidas_en_una_sola_ronda_agotan_el_presupuesto() async throws {
        let runtime = ScriptedRuntime([pulsaciones(0..<(Agent.maxConsecutiveFailures + 1))])
        let registro = registroConLaQueFalla()
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeBrowserAlwaysFails.calls, Agent.maxConsecutiveFailures,
                       "la accion que sobrepasa el presupuesto no se ejecuta, y es de la MISMA ronda")
        XCTAssertEqual(runtime.prompts.count, 1, "el turno no llega a una segunda ronda")
        XCTAssertEqual(visto.fallados, [], "no se sale con un `.failed`: el usuario recibe una respuesta")
        XCTAssertEqual(visto.completados.count, 1, "un mensaje, ni dos ni ninguno: \(visto.completados)")
        XCTAssertTrue(visto.completados.first?.contains("browser_press") ?? false,
                      "el mensaje nombra la herramienta que fallo: \(visto.completados)")
    }

    /// Un exito reinicia la cuenta. El caso recorre de verdad el camino que la reinicia: cuatro
    /// fallos, un exito, cuatro fallos mas. Son ocho fallos en la misma ronda pero nunca cinco
    /// seguidos, asi que la ronda entera se ejecuta; sin el reinicio, la quinta accion mataria
    /// el turno y el `browser_fill` no llegaria a correr.
    func test_un_exito_reinicia_la_cuenta_de_fallos() async throws {
        let tope = Agent.maxConsecutiveFailures
        var ronda = pulsaciones(0..<(tope - 1))
        ronda.append((name: "browser_fill", args: #"{"selector":"@e9","text":"hola"}"#))
        ronda += pulsaciones((tope - 1)..<(2 * tope - 2))
        let runtime = ScriptedRuntime([ronda, []])
        let registro = registroConLaQueFalla()
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeBrowserAlwaysFails.calls, 2 * (tope - 1),
                       "ningun fallo sobra: nunca hubo \(tope) seguidos")
        XCTAssertEqual(FakeBrowserFill.calls, 1, "el exito del medio es el que reinicia la cuenta")
        XCTAssertEqual(runtime.prompts.count, 2, "la ronda termino entera y el bucle volvio al modelo")
        XCTAssertEqual(visto.completados, ["listo"], "el turno termina por lo normal: \(visto.completados)")
    }

    /// Un resultado que no es JSON valido no cuenta como exito (no reinicia), no cuenta como
    /// fallo (no gasta presupuesto) y no revienta el bucle. Son TRES estados, no dos.
    func test_un_resultado_ilegible_no_es_exito_ni_fallo() {
        for ilegible in ["error: no tool named browser_wait", "", "12:00", "[1,2,3]",
                         #"{"status":42}"#, #"{"status":"una_cosa_que_no_existe"}"#, #"{"message":"sin status"}"#] {
            XCTAssertFalse(Agent.esFallo(resultado: ilegible), "no gasta presupuesto: \(ilegible)")
            XCTAssertFalse(Agent.esExito(resultado: ilegible), "no reinicia la cuenta: \(ilegible)")
        }
    }

    /// Lo anterior por la via larga, que es donde se puede medir que no REINICIA: cuatro
    /// fallos, el resultado ilegible que produce el propio bucle cuando el modelo llama a una
    /// herramienta que no existe, y un quinto fallo. Si lo ilegible contara como exito, el
    /// presupuesto no se agotaria y la ronda terminaria entera.
    func test_un_resultado_ilegible_no_reinicia_el_presupuesto_ni_revienta_el_bucle() async throws {
        let tope = Agent.maxConsecutiveFailures
        var ronda = pulsaciones(0..<(tope - 1))
        // `browser_wait` NO esta en este registro: el bucle devuelve `error: no tool named …`,
        // que no es JSON.
        ronda.append((name: "browser_wait", args: "{}"))
        ronda += pulsaciones((tope - 1)..<tope)
        let runtime = ScriptedRuntime([ronda, []])
        let registro = registroConLaQueFalla()
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeBrowserAlwaysFails.calls, tope, "los \(tope) fallos siguen siendo seguidos")
        XCTAssertEqual(runtime.prompts.count, 1, "el presupuesto se agoto: no hay segunda ronda")
        XCTAssertEqual(visto.fallados, [], "un resultado ilegible no revienta el bucle: \(visto.fallados)")
        XCTAssertEqual(visto.completados.count, 1, "\(visto.completados)")
    }

    /// El mensaje con el que el turno termina: dice la herramienta, las veces y —cuando el
    /// resultado lo declara— el motivo. Si no hay motivo legible no se inventa ninguno.
    func test_el_mensaje_de_presupuesto_agotado_dice_la_herramienta_las_veces_y_el_motivo() {
        let conMotivo = Agent.mensajeDePresupuestoAgotado(
            herramienta: "browser_click", fallos: 5,
            resultado: #"{"status":"error","message":"no existe el elemento '@e3'"}"#)
        XCTAssertTrue(conMotivo.contains("browser_click"), conMotivo)
        XCTAssertTrue(conMotivo.contains("5"), conMotivo)
        XCTAssertTrue(conMotivo.contains("no existe el elemento '@e3'"),
                      "el motivo que dio la herramienta: \(conMotivo)")

        let sinMotivo = Agent.mensajeDePresupuestoAgotado(
            herramienta: "browser_click", fallos: 5, resultado: "error: no tool named browser_click")
        XCTAssertTrue(sinMotivo.contains("browser_click"), sinMotivo)
        XCTAssertFalse(sinMotivo.contains("devolvió"), "sin motivo legible no se inventa uno: \(sinMotivo)")
        XCTAssertNotEqual(conMotivo, sinMotivo)
    }

    /// El error vuelve al modelo ENTERO. browser-use lo recorta a los primeros 100 caracteres
    /// mas los ultimos 100 con un `......` en medio, que es la forma mas segura de perder la
    /// parte que explica que paso.
    func test_el_error_vuelve_al_modelo_entero_y_sin_recortar() async throws {
        let runtime = ScriptedRuntime([[(name: "browser_press", args: #"{"key":"Enter"}"#)], []])
        let registro = registroConLaQueFalla()
        _ = try await ejecuta(runtime, registro)

        XCTAssertGreaterThan(FakeBrowserAlwaysFails.motivo.count, 200,
                             "el motivo tiene que ser mas largo que el recorte que no hacemos")
        let segundo = try XCTUnwrap(runtime.prompts.dropFirst().first, "el bucle no volvio a llamar al modelo")
        XCTAssertTrue(segundo.contains(FakeBrowserAlwaysFails.motivo),
                      "el motivo entero tiene que estar en el prompt vivo: \(segundo.suffix(400))")
        XCTAssertFalse(segundo.contains("......"), "nada de elipsis de recorte: \(segundo.suffix(400))")
    }

    /// DECISION DIFICIL (3): el tope de fallos alcanzado en la MISMA ronda en que se agotan las
    /// iteraciones. Dos caminos de salida compitiendo, y el usuario tiene que recibir UN
    /// mensaje: ni dos ni ninguno. La colision se construye sin depender de que los dos numeros
    /// coincidan: todas las rondas menos la ultima tienen exito, y la ultima trae de golpe las
    /// acciones fallidas que agotan el presupuesto.
    func test_el_presupuesto_gana_a_la_salida_por_iteraciones_y_el_usuario_recibe_un_mensaje() async throws {
        var rondas: [[(name: String, args: String)]] = Array(
            repeating: [(name: "web_search", args: #"{"query":"x"}"#)],
            count: Agent.maxIterations - 1)
        rondas.append((0..<Agent.maxConsecutiveFailures).map { (name: "read_webpage", args: "{\"n\":\($0)}") })
        let runtime = ScriptedRuntime(rondas)
        let registro = ToolRegistry()
        FakeOkSearch.calls = 0
        FakeFailingRead.calls = 0
        registro.register(FakeOkSearch())
        registro.register(FakeFailingRead())
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(runtime.prompts.count, Agent.maxIterations, "la colision es en la ultima ronda")
        XCTAssertEqual(FakeOkSearch.calls, Agent.maxIterations - 1)
        XCTAssertEqual(FakeFailingRead.calls, Agent.maxConsecutiveFailures)
        XCTAssertEqual(visto.fallados, [],
                       "la salida por no convergencia no se emite: diria menos y encima seria el segundo mensaje")
        XCTAssertEqual(visto.completados.count, 1, "un mensaje, ni dos ni ninguno: \(visto.completados)")
        XCTAssertTrue(visto.completados.first?.contains("read_webpage") ?? false,
                      "y es el del presupuesto, que dice algo concreto: \(visto.completados)")
    }

    /// Un turno sin ninguna herramienta de navegador y sin ningun fallo no paga nada nuevo: el
    /// prompt vivo de la segunda ronda es EXACTAMENTE el de antes mas la nota de resultado de
    /// siempre, byte a byte. El presupuesto de fallos no mete un solo token en el prompt.
    func test_un_turno_limpio_sin_navegador_no_paga_un_solo_token_nuevo() async throws {
        let args = #"{"query":"x"}"#
        let runtime = ScriptedRuntime([[(name: "web_search", args: args)], []])
        let registro = ToolRegistry()
        FakeOkSearch.calls = 0
        registro.register(FakeOkSearch())
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeOkSearch.calls, 1)
        let primero = try XCTUnwrap(runtime.prompts.first)
        let segundo = try XCTUnwrap(runtime.prompts.dropFirst().first, "el bucle no volvio a llamar al modelo")
        XCTAssertEqual(segundo, primero + "\n\n" + Agent.toolResultNote(toolName: "web_search",
                                                                       args: args,
                                                                       result: FakeOkSearch.resultado))
        XCTAssertEqual(visto.completados, ["listo"])
        XCTAssertEqual(visto.fallados, [])
    }

    /// DECISION DIFICIL (2): una accion que falla Y ADEMAS trae una URL nueva. Gasta
    /// presupuesto y NO corta la cola, y las dos cosas son por construccion: `cortaLaCola`
    /// exige `success` (una accion que fallo no actuo, luego no invalido ninguna `@eN`) y un
    /// exito reinicia el contador. Las dos salidas son disjuntas.
    func test_una_accion_que_falla_con_url_nueva_gasta_presupuesto_pero_no_corta_la_cola() async throws {
        let fallidoConUrlNueva = #"{"status":"error","url":"https://b.test/x","message":"no existe '@e3'"}"#
        XCTAssertTrue(Agent.esFallo(resultado: fallidoConUrlNueva))
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                         resultado: fallidoConUrlNueva,
                                         urlConocida: "https://a.test/"))
        // Disjuntas: lo que corta la cola nunca gasta presupuesto, y al reves.
        for nombre in Agent.browserToolNames {
            for resultado in [fallidoConUrlNueva,
                              #"{"status":"success","url":"https://b.test/x"}"#,
                              #"{"status":"refused","message":"no"}"#,
                              #"{"status":"no_content","message":"nada"}"#] {
                let corta = Agent.cortaLaCola(trasHerramienta: nombre, resultado: resultado,
                                              urlConocida: "https://a.test/")
                if corta { XCTAssertFalse(Agent.esFallo(resultado: resultado), "\(nombre) / \(resultado)") }
                if Agent.esFallo(resultado: resultado) { XCTAssertFalse(corta, "\(nombre) / \(resultado)") }
            }
        }

        // Por la via larga: el clic falla con una URL distinta y el `browser_fill` de detras SI
        // se ejecuta, porque el clic no llego a mover la pagina.
        let anterior = FakeBrowserClick.resultado
        defer { FakeBrowserClick.resultado = anterior }
        FakeBrowserClick.resultado = fallidoConUrlNueva
        let runtime = ScriptedRuntime([
            [(name: "browser_open", args: #"{"url":"https://a.test/"}"#)],
            [(name: "browser_click", args: #"{"selector":"@e3"}"#),
             (name: "browser_fill", args: #"{"selector":"@e9","text":"hola"}"#)],
            []
        ])
        let registro = registroDeNavegadorFalso()
        _ = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeBrowserClick.calls, 1)
        XCTAssertEqual(FakeBrowserFill.calls, 1,
                       "el clic fallo: no actuo, luego no pudo invalidar el `@e9` de la cola")
        for prompt in runtime.prompts {
            XCTAssertFalse(prompt.contains(marcaDelCorte), "una accion fallida no corta: \(prompt.suffix(300))")
        }
    }

    /// Los dos conjuntos de estados son los del contrato real de las herramientas
    /// (`AgentBrowserToolOutput`), y son disjuntos: ningun estado gasta y reinicia a la vez.
    func test_los_estados_de_fallo_y_de_exito_son_el_contrato_real_y_son_disjuntos() {
        for estado in ["error", "refused", "not_available"] {
            XCTAssertTrue(Agent.esFallo(resultado: "{\"status\":\"\(estado)\"}"), estado)
            XCTAssertFalse(Agent.esExito(resultado: "{\"status\":\"\(estado)\"}"), estado)
        }
        for estado in ["success", "no_content"] {
            XCTAssertTrue(Agent.esExito(resultado: "{\"status\":\"\(estado)\"}"), estado)
            XCTAssertFalse(Agent.esFallo(resultado: "{\"status\":\"\(estado)\"}"), estado)
        }
        XCTAssertTrue(Agent.estadosDeFallo.isDisjoint(with: Agent.estadosDeExito))
        XCTAssertGreaterThan(Agent.maxConsecutiveFailures, 1, "con 1 no cabe un reintento")
        XCTAssertLessThan(Agent.maxConsecutiveFailures, Agent.maxBrowserIterations,
                          "el presupuesto tiene que morder antes que el tope de rondas")
    }

    /// Coherencia con lo que el usuario VE. `Agent.estadosDeFallo` y el censo de estados que
    /// pinta la fila del chat (`ToolLogRow`) son conjuntos distintos a proposito —el segundo es
    /// mas ancho—, pero no pueden contradecirse: un turno que muere por un estado que la fila
    /// pintaba con tilde verde seria inexplicable para quien lo esta mirando, y al reves, un
    /// estado que reinicia el presupuesto no puede salir con cruz roja.
    func test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat() {
        func esFalloEnLaFila(_ estado: String) -> Bool {
            if case .failure = ToolLogRow.summarize(toolName: "browser_click",
                                                    resultJSON: "{\"status\":\"\(estado)\"}") { return true }
            return false
        }
        for estado in Agent.estadosDeFallo {
            XCTAssertTrue(esFalloEnLaFila(estado), "gasta presupuesto y la fila no lo pinta como fallo: \(estado)")
        }
        for estado in Agent.estadosDeExito {
            XCTAssertFalse(esFalloEnLaFila(estado), "reinicia el presupuesto y la fila lo pinta como fallo: \(estado)")
        }
    }
}
