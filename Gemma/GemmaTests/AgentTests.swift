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
                                        result: #"{"status":"success","title":"Ejemplo"}"#)
        XCTAssertTrue(note.contains(#"{"status":"success","title":"Ejemplo"}"#), "la nota sigue dando el resultado: \(note)")
        XCTAssertFalse(note.contains("DO NOT call"), "una herramienta de navegador no puede cerrar el turno: \(note)")
        XCTAssertTrue(note.contains("You MAY keep calling browser tools"), "falta el permiso de continuar: \(note)")
        XCTAssertTrue(note.contains("`browser_snapshot`"), "falta el paso siguiente: \(note)")
        XCTAssertTrue(note.contains("`browser_close`"), "falta cómo cerrar la tarea: \(note)")
        XCTAssertTrue(note.contains("NEVER volunteer the current date or time"), "la cláusula ortogonal se queda: \(note)")

        for name in Agent.browserToolNames {
            XCTAssertFalse(Agent.toolResultNote(toolName: name, result: "r").contains("DO NOT call"), name)
        }
        // El conjunto es el INVENTARIO de herramientas de navegador, no un numero: lo que esta
        // prueba necesita es que el bucle de arriba haya recorrido TODAS las que la app
        // registra. Escrito a mano («count == 8») se quedaba viejo en cuanto apareciera la
        // novena y se ponia rojo sin decir por que; derivado del registro, una herramienta
        // nueva entra sola en el bucle, y si alguien la registra sin anadirla a
        // `browserToolNames` el fallo nombra cual falta.
        let registradas = Set(HarnessModel.browserToolRegistry(almacen: AlmacenEnMemoria()).tools
            .map { type(of: $0).name }
            .filter { $0.hasPrefix("browser_") })
        XCTAssertEqual(Agent.browserToolNames, registradas)
        XCTAssertFalse(registradas.isEmpty, "sin inventario el bucle de arriba no comprueba nada")
    }

    /// Las otras ~71 herramientas dependen de esta frase: el modelo spameaba herramientas y
    /// la nota es lo que lo obliga a cerrar el turno. El literal va entero a propósito, para
    /// que cualquier cambio en la rama que NO sea de navegador rompa este test.
    func test_non_browser_tool_note_is_byte_for_byte_the_one_that_was_there() {
        XCTAssertEqual(Agent.toolResultNote(toolName: "web_search", result: "ok"),
                       #"[You called the tool `web_search`; it returned: ok. Tool execution is complete for this action. Formulate your final response to the user in a natural, friendly sentence explaining this result. DO NOT call `web_search` or any other tool again. NEVER volunteer the current date or time.]"#)
        // Y los ARGUMENTOS no estan en la nota, que es el cambio que esta rama trajo: el JSON
        // que el modelo acaba de emitir no vuelve a su propio prompt. Ver `toolResultNote`.
        XCTAssertFalse(Agent.toolResultNote(toolName: "web_search", result: "ok").contains("with arguments"))
        // `read_webpage` es de una sola llamada: le sirve la nota de cierre y queda fuera.
        XCTAssertFalse(Agent.browserToolNames.contains("read_webpage"))
        XCTAssertTrue(Agent.toolResultNote(toolName: "read_webpage", result: "ok").contains("DO NOT call"))
    }

    /// Un bucle de navegador realista (`open → snapshot → fill → snapshot → click → snapshot
    /// → get → close`) son ocho rondas; con las cinco de un turno normal no cabía.
    /// Las herramientas se registran de verdad —y tienen EXITO— a proposito: con un registro
    /// vacio el bucle contesta a cada llamada con el resultado de «esa herramienta no existe»,
    /// que desde que habla el contrato JSON gasta presupuesto de fallos y mata el turno en la
    /// quinta ronda. Lo que se mide aqui es el tope de RONDAS, asi que el turno no puede morir
    /// por otra razon.
    func test_a_turn_that_touches_the_browser_gets_a_bigger_iteration_budget() async throws {
        let normal = RepeatingToolRuntime(toolName: "web_search")
        let registroNormal = ToolRegistry()
        FakeOkSearch.calls = 0
        registroNormal.register(FakeOkSearch())
        for try await _ in Agent(runtime: normal, registry: registroNormal).run(prompt: "x", options: GenerationOptions()) {}
        XCTAssertEqual(normal.prompts.count, Agent.maxIterations,
                       "el presupuesto de un turno sin navegador no cambia")

        let browser = RepeatingToolRuntime(toolName: "browser_open")
        for try await _ in Agent(runtime: browser, registry: registroDeNavegadorFalso()).run(prompt: "x", options: GenerationOptions()) {}
        XCTAssertEqual(browser.prompts.count, Agent.maxBrowserIterations)
        XCTAssertGreaterThan(Agent.maxBrowserIterations, Agent.maxIterations)
        // Las herramientas se retiran en `iteration >= max - 2`, así que las rondas que de
        // verdad pueden llamar herramientas son `max - 1`: tienen que llegar a ocho.
        XCTAssertGreaterThanOrEqual(Agent.maxBrowserIterations - 1, 8)
    }

    /// Lo anterior por la vía larga: la nota del navegador llega de verdad al prompt vivo a
    /// través de `Agent.run`, que es lo que nada en la rama ejercitaba.
    ///
    /// CORRE CONTRA DOBLES DE HERRAMIENTA, NO CONTRA UN REGISTRO VACÍO, y eso es un arreglo del
    /// 2026-11-08. Con el registro vacío cada `browser_snapshot` del guion caía en el resultado
    /// de «no existe esa herramienta» —que desde que habla el contrato JSON lleva `status:
    /// error`—, así que GASTABA presupuesto de fallos y el turno moría en la quinta ronda. Esta
    /// prueba no mentía porque solo lee `prompts[1]`, pero es exactamente la fragilidad que
    /// `BrowserCoreSkillTests` ya diagnosticó y arregló para sí misma: quien la extendiera más
    /// allá de tres rondas mediría el presupuesto creyendo medir la nota, y el síntoma sería un
    /// prompt corto, no un error. La premisa se AFIRMA abajo en vez de suponerse.
    func test_the_browser_note_reaches_the_live_prompt_through_the_loop() async throws {
        let runtime = RepeatingToolRuntime(toolName: "browser_snapshot")
        var resultados: [String] = []
        for try await evento in Agent(runtime: runtime, registry: registroDeNavegadorFalsoConSnapshot())
            .run(prompt: "abre la página", options: GenerationOptions()) {
            if case .toolCallFinished(_, let resultado) = evento { resultados.append(resultado) }
        }
        // La premisa: ninguna acción del guion gastó presupuesto de fallos, así que el turno
        // llegó hasta el tope de rondas de un turno de navegador y no murió por el camino.
        XCTAssertEqual(runtime.prompts.count, Agent.maxBrowserIterations,
                       "el turno murió antes de tiempo: \(runtime.prompts.count) rondas")
        XCTAssertFalse(resultados.isEmpty, "ninguna acción llegó a ejecutarse")
        for resultado in resultados {
            XCTAssertFalse(Agent.esFallo(resultado: resultado),
                           "una acción del guion gastó presupuesto de fallos: \(resultado)")
        }
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
        /// Los nombres de las herramientas que el bucle le ofreció en cada ronda. Es la única
        /// manera de comprobar desde fuera que una ronda NO perdió el navegador.
        var herramientasPorRonda: [[String]] = []
        /// Prosa que el modelo escribe en cada ronda, cuando la prueba quiere medirla. Vacío
        /// (por omisión) conserva exactamente el comportamiento anterior: una ronda con
        /// acciones no dice nada y una ronda vacía cierra el turno con «listo».
        var prosa: [String]
        private var ronda = 0
        init(_ rondas: [[(name: String, args: String)]], prosa: [String] = []) {
            self.rondas = rondas
            self.prosa = prosa
        }
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            prompts.append(prompt)
            herramientasPorRonda.append(tools.map { type(of: $0).name })
            let indice = ronda
            let calls = indice < rondas.count ? rondas[indice] : []
            let texto = indice < prosa.count ? prosa[indice] : (calls.isEmpty ? "listo" : "")
            ronda += 1
            return AsyncThrowingStream { c in
                if !texto.isEmpty { c.yield(.token(texto)) }
                for call in calls { c.yield(.toolCallStarted(name: call.name, args: call.args)) }
                c.yield(.completed(GenerationResult(text: texto,
                                                    metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    /// Herramienta de navegador que LEE la página: nunca corta la cola, y su éxito es la
    /// manera barata de dejar establecido en qué página está el navegador antes de medir otra
    /// cosa. Es además lo que `BrowserSnapshotTool` devuelve de verdad cuando el CLI trae la
    /// URL completa (ver `test_snapshot_reports_the_full_url_when_the_cli_gives_it`).
    final class FakeBrowserSnapshot: AgentTool {
        static let name = "browser_snapshot"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        nonisolated(unsafe) static var resultado =
            #"{"status":"success","url":"https://a.test/","snapshot":"- link \"Más\" [ref=e3]","element_count":1}"#
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
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

    /// El registro falso más el snapshot. Va aparte para no cambiarle el registro a las
    /// pruebas que ya había.
    private func registroDeNavegadorFalsoConSnapshot() -> ToolRegistry {
        FakeBrowserSnapshot.calls = 0
        let r = registroDeNavegadorFalso()
        r.register(FakeBrowserSnapshot())
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
        // Resultado que no es JSON de ninguna manera: prosa, y prosa que encima NOMBRA una URL
        // distinta. Lo que corta es el contrato JSON, nunca una URL leida de un texto suelto.
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                         resultado: "Clic ejecutado; la página quedó en https://b.test/x",
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
                                                            result: FakeBrowserOpen.resultado)),
                      "la nota de resultado de siempre sigue entera")
    }

    /// El aviso del corte es una regla del navegador, así que vive en `BrowserRules` (su única
    /// fuente), dice CUÁNTAS acciones quedaron y no se lee como un fallo del modelo.
    /// El agente se negó dos veces a registrar una cuenta propia (chat 2026-11-10): ninguna regla
    /// lo prohibía, era juicio del modelo. La regla tiene que decir que es tarea legítima, que la
    /// contraseña la pone el usuario y que no hay sermón.
    func test_las_reglas_del_navegador_autorizan_crear_una_cuenta_propia() {
        let t = BrowserRules.text
        XCTAssertTrue(t.contains("Creating an account of your own"))
        XCTAssertTrue(t.contains("The user types the password themselves"))
        XCTAssertTrue(t.contains("Do not lecture about fake identities"))
        // Revisión de Codex: la regla no puede mandar los códigos del usuario al chat.
        XCTAssertTrue(t.contains("never ask for those codes in the chat"))
        XCTAssertFalse(t.contains("gives you any verification code"),
                       "la frase vieja pedía al usuario que le diera sus códigos al agente")
    }

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

    /// EL BUG, MEDIDO HASTA EL CORTE. `AgentBrowserToolOutput.resolve(_:extra:)` mezcla el
    /// `extra` TAMBIEN en el objeto de fallo, asi que un `browser_open` que no llego a la
    /// pagina devolvia de todas formas la URL que se PIDIO; y el bucle la grababa como «la
    /// pagina en la que estamos» sin mirar el `status`. El efecto es exactamente el defecto que
    /// el corte existe para evitar: estamos en a.test, falla el `open` a b.test, la URL
    /// conocida pasa a b.test —una pagina en la que nunca estuvimos—, y el clic que navega DE
    /// VERDAD a b.test COINCIDE con ella, no corta, y el `@e9` de la cola se dispara contra la
    /// pagina nueva.
    ///
    /// Recorre el camino entero a proposito. Afirmar que la variable no cambio verdearia
    /// aunque el corte siguiera ciego por cualquier otro lado; lo que esta prueba exige es que
    /// el clic posterior SI corte.
    func test_un_open_fallido_no_envenena_la_url_conocida_y_el_clic_posterior_si_corta() async throws {
        let anterior = FakeBrowserOpen.resultado
        defer { FakeBrowserOpen.resultado = anterior }
        // Un fallo que arrastra la URL pedida: la forma que `BrowserOpenTool` devolvia. Y la URL
        // es EXACTAMENTE la pagina a la que el clic de detras navega de verdad —el caso del
        // encargo: el modelo intenta ir directo, no puede, y llega pulsando un enlace—. Tiene
        // que coincidir al caracter: si no coincide, el corte se dispara por otro motivo y la
        // prueba verdea con el envenenamiento intacto. (Pasó: con `https://b.test/` contra el
        // `https://b.test/x` del clic, esta prueba pasaba ANTES del arreglo.)
        FakeBrowserOpen.resultado = #"{"status":"error","url":"https://b.test/x","message":"no se pudo cargar"}"#
        let runtime = ScriptedRuntime([
            // Ronda 1: leer la pagina deja establecido que estamos en a.test (y leer no corta).
            [(name: "browser_snapshot", args: "{}")],
            // Ronda 2: el `open` a b.test/x FALLA. El clic de detras SI navega a b.test/x, asi
            // que el `@e9` del fill es de la pagina de antes del clic.
            [(name: "browser_open", args: #"{"url":"https://b.test/x"}"#),
             (name: "browser_click", args: #"{"selector":"@e3"}"#),
             (name: "browser_fill", args: #"{"selector":"@e9","text":"hola"}"#)],
            []
        ])
        let registro = registroDeNavegadorFalsoConSnapshot()
        _ = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeBrowserSnapshot.calls, 1)
        XCTAssertEqual(FakeBrowserOpen.calls, 1)
        XCTAssertEqual(FakeBrowserClick.calls, 1,
                       "el `open` fallo, luego no actuo y no corta: el clic se ejecuta")
        XCTAssertEqual(FakeBrowserFill.calls, 0,
                       "el clic navego de a.test a b.test/x: el `@e9` es de la pagina vieja")
        let tercero = try XCTUnwrap(runtime.prompts.dropFirst(2).first, "falto la tercera ronda")
        XCTAssertTrue(tercero.contains(BrowserRules.queueCutNote(tras: "browser_click",
                                                                 pendientes: ["browser_fill"])),
                      "el corte tiene que dispararse tras el clic: \(tercero.suffix(400))")
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
        /// El resultado, expuesto para que una prueba pueda construir lo que la producción
        /// construiría con ÉL y no con una copia escrita a mano. Antes solo existía dentro de
        /// `run`, así que una prueba que lo necesitara lo volvía a teclear.
        static var resultado: String { "{\"status\":\"error\",\"message\":\"\(motivo)\"}" }
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
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

    /// Herramienta cuyo resultado no es JSON de ninguna manera: PROSA. Es la cadena que
    /// `ForgetTool` devolvia de verdad antes de que las ocho herramientas que hablaban prosa
    /// pasaran al contrato `status`; hoy ninguna herramienta REGISTRADA contesta asi, y lo unico
    /// que sigue llegando al bucle sin ser JSON es el `DUPLICATE_CALL_IGNORED` que escribe el
    /// propio bucle. Se queda como el doble del tercer estado —ni exito ni fallo— y para medir
    /// que la prosa ya no reinicia el presupuesto.
    final class FakeIlegible: AgentTool {
        static let name = "forget"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        static let resultado = "Forgot 3 item(s) matching 'x'."
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    /// `forget` COMO CONTESTA HOY: el contrato `status`. Es la forma real de `ForgetTool` por su
    /// camino bueno, y es el doble que mide que el caso que obligo al parche del reinicio sigue
    /// cubierto ahora que el parche se ha quitado.
    final class FakeForgetDelContrato: AgentTool {
        static let name = "forget"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        static let resultado = #"{"forgotten_count":3,"message":"Olvidado(s) 3 recuerdo(s).","query":"x","status":"success"}"#
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    /// `create_event` COMO CONTESTA HOY: declara su exito con `created`, que es el verbo que su
    /// propia descripcion le ensena al modelo a leer («Lee 'status': 'created' = creado y
    /// comprobado, ya se lo puedes confirmar»). Es la forma REAL de `CreateEventTool` por su
    /// camino bueno, y el doble que mide que una MUTACION DE AGENDA que salio bien borra la
    /// cuenta de fallos anteriores.
    final class FakeCreateEventDelContrato: AgentTool {
        static let name = "create_event"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        static let resultado = #"{"status":"created","id":"e1","title":"dentista","message":"Agendado: dentista, 10 nov 2099 08:00."}"#
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    /// Herramienta que no pudo, y lo dice con un estado que NO es del contrato del navegador.
    /// Forma real: `CurrentLocationTool` devuelve `status: timeout` cuando el sistema no
    /// entrega una posicion a tiempo.
    final class FakeTimeoutTool: AgentTool {
        static let name = "current_location"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        static let resultado = #"{"status":"timeout","message":"no llego ninguna posicion a tiempo"}"#
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    /// `browser_close` con el candado de la app echado. Es la forma REAL del resultado
    /// (`BrowserCloseTool`, rama `guard userAskedToClose`): `status: refused` y un `message`
    /// largo redactado para el modelo.
    final class FakeBrowserCloseRefused: AgentTool {
        static let name = "browser_close"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        static let motivo = "No se ha cerrado el navegador y la página sigue abierta, porque el "
            + "mensaje del usuario en este turno no pedía cerrarla. NO vuelvas a intentarlo."
        static var resultado: String { "{\"status\":\"refused\",\"message\":\"\(motivo)\"}" }
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return Self.resultado
        }
    }

    /// Herramienta cuyo resultado SÍ es un objeto JSON pero sin `status` legible.
    ///
    /// SU EJEMPLO CAMBIO, Y EL CAMBIO ES EL ARREGLO. Esto era `ToolJSONOutput.error(_:)`, la
    /// salida de las guardas de argumentos de medio registro, que emitia `{"error": …}` sin
    /// `status`: la fila del chat lo resumia como «listo» con su tilde verde sobre un error, y el
    /// bucle no podia contarlo. Desde que `error(_:)` declara `status: error`, ese caso salio de
    /// esta categoria y es un fallo contado — lo mide
    /// `HerramientasHablanStatusTests.test_la_guarda_de_argumentos_declara_error_y_ya_no_sale_en_verde`.
    /// La categoria sigue existiendo y sigue necesitando su doble: un objeto que llega sin
    /// `status`, o con uno que no se sabe leer, no reinicia el presupuesto.
    final class FakeObjetoSinEstado: AgentTool {
        static let name = "forget_shortcut"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        static let resultado = #"{"detalle":"un objeto que llego sin `status`"}"#
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
        // El turno termina por lo normal —no por el presupuesto—, y la respuesta lleva ademas
        // la linea de estado real: la ULTIMA accion de navegador del turno fue una pulsacion
        // fallida, asi que el usuario tiene derecho a leerlo aunque el modelo diga «listo». Es
        // justo el caso para el que esa linea existe; ver
        // `test_la_ultima_accion_fallida_del_navegador_llega_al_usuario_en_la_respuesta`.
        let linea = try XCTUnwrap(
            Agent.lineaDeEstadoDelNavegador(herramienta: "browser_press",
                                            resultado: FakeBrowserAlwaysFails.resultado))
        XCTAssertEqual(visto.completados, ["listo\n\n" + linea],
                       "el turno termina por lo normal: \(visto.completados)")
    }

    /// Un resultado que no es JSON valido no cuenta como exito (no reinicia), no cuenta como
    /// fallo (no gasta presupuesto) y no revienta el bucle. Son TRES estados, no dos.
    func test_un_resultado_ilegible_no_es_exito_ni_fallo() {
        for ilegible in [FakeIlegible.resultado, "", "12:00", "[1,2,3]",
                         #"{"status":42}"#, #"{"status":"una_cosa_que_no_existe"}"#, #"{"message":"sin status"}"#] {
            XCTAssertFalse(Agent.esFallo(resultado: ilegible), "no gasta presupuesto: \(ilegible)")
            XCTAssertFalse(Agent.esExito(resultado: ilegible), "no reinicia la cuenta: \(ilegible)")
        }
    }

    /// EL PRESUPUESTO SE REINICIA CON EL CONTRATO `status`, Y CON NADA MAS.
    ///
    /// DE DONDE VIENE ESTA PRUEBA. Su version anterior declaraba la propiedad CONTRARIA —«un
    /// exito en PROSA reinicia el presupuesto»— y era un parche, escrito y declarado como tal.
    /// El defecto que arreglaba era real: ocho herramientas registradas contestaban en prosa
    /// (`forget`, `save_memory`, `reflect`, `get_current_time`, `update_event` y las tres de A to
    /// Z, tres de ellas MUTACIONES) y su exito no reiniciaba nada, asi que cinco fallos
    /// intercalados con cinco `forget` que funcionaron mataban el turno. Pero el parche se cobro
    /// un precio, escrito entonces en el codigo: un FALLO en prosa («memory unavailable») tambien
    /// reiniciaba, y el presupuesto se quedaba sin dientes justo contra el turno que no avanza.
    ///
    /// LO QUE CAMBIO: las ocho hablan `status`. La prosa dejo de ser la voz de ninguna
    /// herramienta registrada —censo verificado sobre las ochenta del registro— y el parche se
    /// ha quitado, asi que esta prueba cambia de propiedad declarada. NO es un arreglo de prueba
    /// para verdear: es la propiedad nueva, y sus tres mitades la fijan por los dos lados.
    ///
    /// LAS TRES MITADES VIVEN EN LA MISMA FUNCION A PROPOSITO. Una implementacion que reiniciara
    /// con cualquier cosa que no sea un fallo pasaria (a) y moriria en (b) y (c); una que no
    /// reiniciara nunca moriria en (a); y la de antes —la que aceptaba la prosa— pasaria (a) y
    /// (b) y moriria en (c), que es exactamente el precio que se ha quitado.
    func test_el_presupuesto_se_reinicia_con_el_contrato_y_no_con_la_prosa() async throws {
        let tope = Agent.maxConsecutiveFailures
        func rondaCon(_ delMedio: (name: String, args: String)) -> [(name: String, args: String)] {
            var r = pulsaciones(0..<(tope - 1))
            r.append(delMedio)
            r += pulsaciones((tope - 1)..<tope)
            r.append((name: "browser_fill", args: #"{"selector":"@e9","text":"hola"}"#))
            return r
        }

        // (a) EL CASO QUE OBLIGO AL PARCHE, AHORA CUBIERTO POR LA PUERTA BUENA: `forget` declara
        // `status: success` y reinicia, asi que nunca hay `tope` fallos seguidos y la ronda
        // termina entera. Es la forma REAL de `ForgetTool` por su camino bueno.
        let conContrato = ScriptedRuntime([rondaCon((name: "forget", args: "{}")), []])
        let registroContrato = registroConLaQueFalla()
        FakeForgetDelContrato.calls = 0
        registroContrato.register(FakeForgetDelContrato())
        let vistoContrato = try await ejecuta(conContrato, registroContrato)

        XCTAssertEqual(FakeForgetDelContrato.calls, 1, "el exito se ejecuto de verdad")
        XCTAssertEqual(FakeBrowserAlwaysFails.calls, tope, "los \(tope) fallos se ejecutaron todos")
        XCTAssertEqual(FakeBrowserFill.calls, 1,
                       "la ultima accion del turno tenia que correr: el exito declarado reinicio la cuenta")
        XCTAssertEqual(conContrato.prompts.count, 2, "el turno sigue vivo y vuelve al modelo")
        XCTAssertEqual(vistoContrato.fallados, [], "nada de esto revienta el bucle: \(vistoContrato.fallados)")

        // (b) UN OBJETO JSON SIN `status` LEGIBLE NO REINICIA, asi que el presupuesto sigue
        // mordiendo donde tiene que morder.
        let conObjeto = ScriptedRuntime([rondaCon((name: "forget_shortcut", args: "{}")), []])
        let registroObjeto = registroConLaQueFalla()
        FakeObjetoSinEstado.calls = 0
        registroObjeto.register(FakeObjetoSinEstado())
        let vistoObjeto = try await ejecuta(conObjeto, registroObjeto)

        XCTAssertEqual(FakeObjetoSinEstado.calls, 1, "el objeto ilegible se ejecuto de verdad")
        XCTAssertEqual(FakeBrowserAlwaysFails.calls, tope, "los \(tope) fallos siguen siendo seguidos")
        XCTAssertEqual(FakeBrowserFill.calls, 0, "el presupuesto se agoto antes de la ultima accion")
        XCTAssertEqual(conObjeto.prompts.count, 1, "el presupuesto se agoto: no hay segunda ronda")
        XCTAssertEqual(vistoObjeto.completados.count, 1, "\(vistoObjeto.completados)")

        // (c) LA PROSA TAMPOCO REINICIA, Y ES EL PRECIO QUE SE HA QUITADO. Antes esta misma
        // ronda terminaba entera; ahora el presupuesto se agota, porque un resultado que no
        // sabemos leer no puede hacer de exito.
        let conProsa = ScriptedRuntime([rondaCon((name: "forget", args: "{}")), []])
        let registroProsa = registroConLaQueFalla()
        FakeIlegible.calls = 0
        registroProsa.register(FakeIlegible())
        let vistoProsa = try await ejecuta(conProsa, registroProsa)

        XCTAssertEqual(FakeIlegible.calls, 1, "la prosa se ejecuto de verdad")
        XCTAssertEqual(FakeBrowserFill.calls, 0,
                       "la prosa ya no hace de exito: el presupuesto se agota")
        XCTAssertEqual(conProsa.prompts.count, 1, "no hay segunda ronda")
        XCTAssertEqual(vistoProsa.fallados, [], "y sigue sin reventar el bucle: \(vistoProsa.fallados)")

        // (d) Y la funcion pura, que es donde la linea esta escrita.
        XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: FakeForgetDelContrato.resultado),
                      "un exito declarado reinicia")
        XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: #"{"status":"success"}"#))
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: FakeIlegible.resultado),
                       "la prosa ya no reinicia: \(FakeIlegible.resultado)")
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: "memory unavailable"),
                       "y un FALLO en prosa menos: era el precio del parche")
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: FakeObjetoSinEstado.resultado),
                       "un objeto JSON sin `status` legible NO reinicia: \(FakeObjetoSinEstado.resultado)")
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: #"{"status":"error"}"#))
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: "\(Agent.duplicadoIgnorado): ya estaba hecho"),
                       "el atajo del propio bucle no es una herramienta contestando")
    }

    /// UNA MUTACION DE AGENDA QUE SALIO BIEN TAMBIEN REINICIA EL PRESUPUESTO.
    ///
    /// EL DEFECTO QUE ARREGLA, MEDIDO EN EL BUCLE. `Agent.estadosDeExito` era
    /// `["success", "no_content"]`, y `create_event` / `cancel_events` declaraban su exito con
    /// el verbo que sus descripciones le ensenan al modelo a leer: `created`,
    /// `created_with_warnings` y `cancelled`. Ninguno estaba en el conjunto, asi que el agente
    /// creaba un evento CORRECTAMENTE y ese acierto no borraba la cuenta de fallos anteriores:
    /// esta misma ronda —cuatro fallos, el evento creado, un fallo mas— mataba el turno y el
    /// `browser_fill` del final no llegaba a correr, con la agenda del usuario ya escrita. Es el
    /// mismo defecto que `test_el_presupuesto_se_reinicia_con_el_contrato_y_no_con_la_prosa`
    /// quito por la puerta de la prosa, entrando por la puerta del verbo.
    ///
    /// QUE CAMINO LE TOCO A CADA ESTADO, Y POR QUE: el razonamiento entero esta en
    /// `TresCorreccionesDelStatusTests
    /// .test_los_exitos_de_create_event_y_cancel_events_reinician_el_presupuesto`. En resumen,
    /// `created` y `created_with_warnings` ENTRAN en el conjunto —los leen el modelo (por la
    /// descripcion de seis herramientas) y una decena de pruebas, y las dos ramas tienen que
    /// seguir distinguiendose—, mientras que `cancelled` NO entra y `cancel_events` pasa a
    /// declarar `success`: el conjunto se indexa por nombre de estado, y `cancelled` significa
    /// «el USUARIO lo descarto» en `run_shortcut` y `send_message`.
    func test_un_evento_creado_reinicia_el_presupuesto_como_cualquier_otro_exito() async throws {
        let tope = Agent.maxConsecutiveFailures
        var ronda = pulsaciones(0..<(tope - 1))
        ronda.append((name: "create_event", args: #"{"title":"dentista","start":"2099-11-10T08:00"}"#))
        ronda += pulsaciones((tope - 1)..<tope)
        ronda.append((name: "browser_fill", args: #"{"selector":"@e9","text":"hola"}"#))

        let runtime = ScriptedRuntime([ronda, []])
        let registro = registroConLaQueFalla()
        FakeCreateEventDelContrato.calls = 0
        registro.register(FakeCreateEventDelContrato())
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeCreateEventDelContrato.calls, 1, "el evento se creo de verdad")
        XCTAssertEqual(FakeBrowserAlwaysFails.calls, tope, "los \(tope) fallos se ejecutaron todos")
        XCTAssertEqual(FakeBrowserFill.calls, 1,
                       "la ultima accion del turno tenia que correr: el evento creado reinicio la cuenta")
        XCTAssertEqual(runtime.prompts.count, 2, "el turno sigue vivo y vuelve al modelo")
        XCTAssertEqual(visto.fallados, [], "nada de esto revienta el bucle: \(visto.fallados)")

        // Y la funcion pura, por los tres estados de las dos herramientas.
        XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: FakeCreateEventDelContrato.resultado),
                      "got: \(FakeCreateEventDelContrato.resultado)")
        for estado in ["created", "created_with_warnings", "success"] {
            XCTAssertTrue(Agent.reiniciaElPresupuesto(resultado: "{\"status\":\"\(estado)\"}"), estado)
        }
        // Lo que NO entra: «conteste, y no habia nada que cancelar» no es un acierto...
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: #"{"status":"nothing_to_cancel"}"#),
                       "no se cancelo nada: no borra fallos")
        // ...y `cancelled` tampoco, porque en `run_shortcut` y `send_message` significa que el
        // USUARIO lo descarto. Por eso `cancel_events` declara `success` y no `cancelled`.
        XCTAssertFalse(Agent.reiniciaElPresupuesto(resultado: #"{"status":"cancelled","shortcut":"X"}"#),
                       "un atajo que el usuario descarto no es un acierto del agente")
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
            herramienta: "browser_click", fallos: 5, resultado: FakeIlegible.resultado)
        XCTAssertTrue(sinMotivo.contains("browser_click"), sinMotivo)
        XCTAssertFalse(sinMotivo.contains("devolvió"), "sin motivo legible no se inventa uno: \(sinMotivo)")
        XCTAssertNotEqual(conMotivo, sinMotivo)
    }

    /// EL MENSAJE NO LE CUELGA LOS CINCO FALLOS A UNA SOLA HERRAMIENTA.
    ///
    /// EL CASO MEDIDO, Y ES UNA MENTIRA COMPROBABLE. Con tres fallos de `read_webpage` y dos de
    /// `browser_press`, el mensaje decia «He llamado a `read_webpage` 5 veces seguidas y las 5
    /// han fallado». El contador es global al turno y se cuenta POR ACCION —que es la mitad
    /// buena del diseno, asi queda acotado el peor caso—, pero la frase lo presentaba como si
    /// fuera por herramienta. El usuario puede abrir las filas del chat y contar tres llamadas a
    /// `read_webpage`: lo que aprende es que su asistente se inventa cifras, y eso gasta la
    /// credibilidad de todos los demas textos de la app.
    func test_el_mensaje_de_presupuesto_no_le_cuelga_los_cinco_fallos_a_una_sola_herramienta() async throws {
        // read, press, read, press, read: cinco fallos, TRES de `read_webpage` y DOS de
        // `browser_press`. El quinto es un `read_webpage`, asi que es el que el mensaje nombra.
        let ronda: [(name: String, args: String)] = [
            (name: "read_webpage", args: #"{"n":1}"#),
            (name: "browser_press", args: #"{"key":"Enter","n":1}"#),
            (name: "read_webpage", args: #"{"n":2}"#),
            (name: "browser_press", args: #"{"key":"Enter","n":2}"#),
            (name: "read_webpage", args: #"{"n":3}"#),
            (name: "browser_fill", args: #"{"selector":"@e9","text":"hola"}"#),
        ]
        let runtime = ScriptedRuntime([ronda])
        let registro = registroConLaQueFalla()
        FakeFailingRead.calls = 0
        registro.register(FakeFailingRead())
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeFailingRead.calls, 3, "`read_webpage` se llamo TRES veces, no cinco")
        XCTAssertEqual(FakeBrowserAlwaysFails.calls, 2, "`browser_press` fallo las otras dos")
        XCTAssertEqual(FakeBrowserFill.calls, 0, "el presupuesto se agoto antes de la ultima accion")
        let mensaje = try XCTUnwrap(visto.completados.first, "el turno no entrego mensaje")

        // Lo que SI dice: cuantas acciones, cual fue la ultima y que devolvio.
        XCTAssertTrue(mensaje.contains("\(Agent.maxConsecutiveFailures) acciones"),
                      "la cuenta es de ACCIONES, que es lo que el bucle cuenta: \(mensaje)")
        XCTAssertTrue(mensaje.contains("`read_webpage`"),
                      "nombra la ultima, que es la que acabo de fallar: \(mensaje)")
        XCTAssertTrue(mensaje.contains("la pagina no respondio"),
                      "y lo que devolvio, que es el motivo: \(mensaje)")
        // Y LA AFIRMACION FALSA QUE SE MIDIO, QUE YA NO PUEDE HACER.
        XCTAssertFalse(mensaje.contains("llamado a `read_webpage`"),
                       "no se le cuelgan a una herramienta llamadas que no hizo: \(mensaje)")
        XCTAssertFalse(mensaje.contains("`read_webpage` \(Agent.maxConsecutiveFailures) veces"),
                       "ni la cuenta pegada a su nombre: \(mensaje)")
        XCTAssertFalse(mensaje.contains("browser_press"),
                       "tampoco se culpa a la otra, que fallo dos veces: \(mensaje)")
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
                                                                       result: FakeOkSearch.resultado))
        // Y los argumentos que el modelo uso no estan en ningun sitio del prompt nuevo.
        XCTAssertFalse(segundo.contains(args), "la llamada volvio al prompt: \(segundo.suffix(300))")
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

    /// EL SEGUNDO HUECO. Una herramienta que NO existe tambien gasta presupuesto. El bucle
    /// contestaba con la cadena `error: no tool named X`, que no es JSON: `esFallo` no le podia
    /// leer el `status`, el resultado caia en la direccion segura (no gasta) y un modelo
    /// empenado en una herramienta inexistente seguia dando vueltas hasta el tope de rondas del
    /// turno — que es justo el caso para el que el presupuesto se escribio.
    ///
    /// Por la via larga: cinco llamadas a una herramienta que no esta en el registro agotan el
    /// presupuesto, y la sexta accion de la ronda ya no se ejecuta.
    func test_insistir_en_una_herramienta_que_no_existe_agota_el_presupuesto() async throws {
        let tope = Agent.maxConsecutiveFailures
        var ronda = (0..<tope).map { (name: "browser_wait", args: "{\"n\":\($0)}") }
        ronda.append((name: "browser_fill", args: #"{"selector":"@e9","text":"hola"}"#))
        let runtime = ScriptedRuntime([ronda, []])
        // `browser_wait` NO esta registrada aqui.
        let registro = registroDeNavegadorFalso()
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(runtime.prompts.count, 1, "el presupuesto se agoto: no hay segunda ronda")
        XCTAssertEqual(FakeBrowserFill.calls, 0, "lo que quedaba de la ronda no se ejecuta")
        XCTAssertEqual(visto.fallados, [], "el turno se cierra con un mensaje, no con un `.failed`")
        XCTAssertEqual(visto.completados.count, 1, "un mensaje, ni dos ni ninguno: \(visto.completados)")
        XCTAssertTrue(visto.completados.first?.contains("browser_wait") ?? false,
                      "el mensaje nombra la herramienta: \(visto.completados)")
    }

    /// EL TERCER HUECO. Los cinco estados de «NO PUDE» que no gastaban presupuesto, y el limite
    /// que sigue sin cruzarse: los estados con los que una herramienta CONTESTA que la respuesta
    /// es no. Un turno en el que el modelo consulta cinco cosas que no existen esta trabajando,
    /// y matarlo seria peor que el defecto. El criterio esta escrito en `estadosDeFallo`.
    func test_los_estados_de_no_pude_gastan_presupuesto_y_los_de_conteste_que_no_siguen_fuera() {
        for estado in ["timeout", "unavailable", "memory_unavailable", "permission_denied", "failed"] {
            XCTAssertTrue(Agent.esFallo(resultado: "{\"status\":\"\(estado)\"}"),
                          "«no pude» y no gasta presupuesto: \(estado)")
        }
        // El limite. Todos son de `ToolLogRow.failureStatuses` —el censo ancho, el que pinta la
        // cruz roja— y ninguno puede matar el turno: la herramienta contesto.
        for estado in ["not_found", "contact_not_found", "place_not_found", "not_in_catalog",
                       "unknown_topic", "unsupported", "unsupported_kind", "limit_reached",
                       "missing_fields", "name_taken", "no_phone_number", "period_in_past",
                       "rejected"] {
            XCTAssertFalse(Agent.esFallo(resultado: "{\"status\":\"\(estado)\"}"),
                           "«conteste que no» y mata el turno del usuario: \(estado)")
        }
    }

    /// El tercer hueco por la via larga, y con un estado de FUERA del contrato del navegador:
    /// cinco `timeout` seguidos de una herramienta cualquiera paran el turno, y la sexta accion
    /// de la ronda no se ejecuta. El presupuesto no es una regla del navegador.
    func test_cinco_timeouts_seguidos_paran_el_turno() async throws {
        let tope = Agent.maxConsecutiveFailures
        var ronda = (0..<tope).map { (name: "current_location", args: "{\"n\":\($0)}") }
        ronda.append((name: "browser_fill", args: #"{"selector":"@e9","text":"hola"}"#))
        let runtime = ScriptedRuntime([ronda, []])
        let registro = registroDeNavegadorFalso()
        FakeTimeoutTool.calls = 0
        registro.register(FakeTimeoutTool())
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeTimeoutTool.calls, tope, "la accion que sobrepasa el presupuesto no se ejecuta")
        XCTAssertEqual(FakeBrowserFill.calls, 0, "lo que quedaba de la ronda no se ejecuta")
        XCTAssertEqual(runtime.prompts.count, 1, "el turno no llega a una segunda ronda")
        XCTAssertEqual(visto.completados.count, 1, "un mensaje: \(visto.completados)")
        XCTAssertTrue(visto.completados.first?.contains("current_location") ?? false,
                      "el mensaje nombra la herramienta que no pudo: \(visto.completados)")
    }

    /// Los dos conjuntos de estados son los del contrato real de las herramientas
    /// (`AgentBrowserToolOutput`) mas los estados de infraestructura de las demas, y son
    /// disjuntos: ningun estado gasta y reinicia a la vez.
    func test_los_estados_de_fallo_y_de_exito_son_el_contrato_real_y_son_disjuntos() {
        for estado in ["error", "refused", "not_available",
                       "timeout", "unavailable", "memory_unavailable", "permission_denied", "failed"] {
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
        func esFalloEnLaFila(_ estado: String, herramienta: String = "browser_click") -> Bool {
            if case .failure = ToolLogRow.summarize(toolName: herramienta,
                                                    resultJSON: "{\"status\":\"\(estado)\"}") { return true }
            return false
        }
        for estado in Agent.estadosDeFallo {
            XCTAssertTrue(esFalloEnLaFila(estado), "gasta presupuesto y la fila no lo pinta como fallo: \(estado)")
        }
        for estado in Agent.estadosDeExito {
            XCTAssertFalse(esFalloEnLaFila(estado), "reinicia el presupuesto y la fila lo pinta como fallo: \(estado)")
        }
        // LA UNICA EXCEPCION DEL INVARIANTE, DECLARADA AQUI PARA QUE NO MIENTA. Un
        // `browser_close` con `refused` sigue gastando presupuesto —el bucle no mira el nombre
        // de la herramienta, y no deberia— pero NO sale con cruz roja, porque para el usuario no
        // es un fallo: es el candado de la app protegiendole la pagina. El coste de la excepcion
        // tambien conviene que este escrito: un modelo que insistiera en cerrar gastaria el
        // presupuesto del turno sin que la fila lo pintase como fallo. No se ha observado (el
        // candado le dice «NO vuelvas a intentarlo» en el `message`) y queda anotado.
        XCTAssertTrue(Agent.esFallo(resultado: #"{"status":"refused"}"#),
                      "la premisa de la excepcion: `refused` gasta presupuesto")
        XCTAssertFalse(esFalloEnLaFila("refused", herramienta: "browser_close"),
                       "un cierre rechazado por el candado no se pinta como fallo")
    }

    // MARK: - El historial del turno es la prosa del modelo, no su JSON

    /// LA PROPIEDAD CENTRAL. El prompt de la ronda N+1 NO lleva el texto literal de la llamada
    /// que el modelo hizo en la ronda N, y sí lleva su resultado.
    ///
    /// Por qué importa, y no es ahorro de tokens: releer sus propias llamadas le enseña a
    /// repetirlas, y en este proyecto eso no es teoría —el modelo llegó a escribir la sintaxis
    /// de llamada como texto visible en la respuesta al usuario y arreglarlo costó una rama
    /// entera (`ToolSyntaxStreamGate`)—. browser-use reconstruye UN solo mensaje por paso y el
    /// modelo nunca ve su propio JSON anterior.
    ///
    /// La ausencia se afirma contra la MISMA constante que conduce al runtime, así que no puede
    /// verdear por una falta de ortografía; y se afirma junto a lo que SÍ tiene que estar
    /// (resultado, nombre de la herramienta, prompt del usuario), porque «no contiene X»
    /// verdearía solo con que la ronda N+1 no se hubiera construido.
    func test_la_llamada_de_la_ronda_anterior_no_vuelve_al_prompt_y_su_resultado_si() async throws {
        let args = #"{"url":"https://a.test/","motivo":"zzlitera-de-la-llamadazz"}"#
        let runtime = ScriptedRuntime([[(name: "browser_open", args: args)], []])
        let registro = registroDeNavegadorFalso()
        for try await _ in Agent(runtime: runtime, registry: registro).run(prompt: "abre la página",
                                                                           options: GenerationOptions()) {}

        XCTAssertEqual(FakeBrowserOpen.calls, 1)
        XCTAssertEqual(runtime.prompts.count, 2, "la ronda N+1 tiene que haberse construido")
        let segundo = try XCTUnwrap(runtime.prompts.dropFirst().first)
        // Lo que NO está: el JSON de la llamada.
        XCTAssertFalse(segundo.contains(args), "la llamada de la ronda anterior volvió al prompt: \(segundo.suffix(400))")
        XCTAssertFalse(segundo.contains("zzlitera-de-la-llamadazz"),
                       "ni un trozo de los argumentos: \(segundo.suffix(400))")
        // Lo que SÍ está: el resultado entero, el nombre de la herramienta y el prompt del usuario.
        XCTAssertTrue(segundo.contains(FakeBrowserOpen.resultado), "falta el resultado: \(segundo.suffix(400))")
        XCTAssertTrue(segundo.contains("browser_open"), "falta el nombre de la herramienta: \(segundo.suffix(400))")
        XCTAssertTrue(segundo.contains("it returned:"), "falta la nota de resultado: \(segundo.suffix(400))")
        XCTAssertTrue(segundo.contains("abre la página"), "el prompt del usuario no se toca: \(segundo.prefix(400))")
    }

    /// EL BORDE que el encargo nombra: si el modelo NARRA en prosa que va a llamar a
    /// `browser_click @e5`, eso es prosa y se conserva, aunque enseñe lo mismo que el JSON. Lo
    /// que se quita es la SINTAXIS de la llamada, no lo que el modelo dice: adivinar
    /// intenciones sería recortarle al modelo su propio razonamiento.
    ///
    /// La prueba es afilada a propósito: el `@e5` aparece en las dos cosas, así que lo único
    /// que distingue «se quitó la sintaxis» de «se quitó el contenido» es que el `@e5` de la
    /// prosa siga ahí mientras el `{"selector":"@e5"}` no está.
    func test_la_prosa_del_modelo_viaja_al_prompt_aunque_narre_la_llamada() async throws {
        let args = #"{"selector":"@e5"}"#
        let narracion = "Ahora voy a llamar a browser_click @e5 para pulsar el enlace."
        let runtime = ScriptedRuntime([[(name: "browser_click", args: args)], []], prosa: [narracion, "listo"])
        let registro = registroDeNavegadorFalso()
        for try await _ in Agent(runtime: runtime, registry: registro).run(prompt: "pulsa el enlace",
                                                                           options: GenerationOptions()) {}

        XCTAssertEqual(FakeBrowserClick.calls, 1)
        let segundo = try XCTUnwrap(runtime.prompts.dropFirst().first, "el bucle no volvió a llamar al modelo")
        XCTAssertTrue(segundo.contains(narracion), "la prosa del modelo tiene que volver: \(segundo.suffix(500))")
        XCTAssertFalse(segundo.contains(args), "la sintaxis de la llamada no: \(segundo.suffix(500))")
        XCTAssertTrue(segundo.contains("@e5"), "y el `@e5` de la prosa sigue ahí, que es la diferencia")
        XCTAssertTrue(segundo.contains(FakeBrowserClick.resultado), "y el resultado también")
    }

    /// El recorte, como función pura. Se recortan las rondas MÁS VIEJAS y nunca la más
    /// reciente, ni aunque sola se pase del tope: una ronda a medias es peor que una ronda de
    /// más, y partir un resultado por el medio es justo lo que la nota de resultado prohíbe.
    func test_recortaElHistorial_tira_lo_mas_viejo_y_jamas_lo_mas_reciente() {
        let diezKB = String(repeating: "a", count: 10_000)
        let rondas = (1...4).map { Agent.RondaDelTurno(texto: "r\($0) " + diezKB) }

        let sobra = Agent.recortaElHistorial(rondas, maxBytes: 100_000)
        XCTAssertEqual(sobra.rondas.map(\.texto), rondas.map(\.texto), "si cabe, no se toca nada")
        XCTAssertNil(sobra.guiaRescatada)

        let recortado = Agent.recortaElHistorial(rondas, maxBytes: 27_000)
        XCTAssertEqual(recortado.rondas.count, 2, "27 KB dan para dos rondas de 10 KB, no para tres")
        XCTAssertTrue(recortado.rondas.first?.texto.hasPrefix("r3 ") ?? false, "cae lo más viejo, en orden")
        XCTAssertTrue(recortado.rondas.last?.texto.hasPrefix("r4 ") ?? false, "la más reciente es la última")

        let unaEnorme = [Agent.RondaDelTurno(texto: String(repeating: "b", count: 60_000))]
        XCTAssertEqual(Agent.recortaElHistorial(unaEnorme, maxBytes: 27_000).rondas.count, 1,
                       "la más reciente se conserva aunque sola se pase del tope")
        XCTAssertEqual(Agent.recortaElHistorial([], maxBytes: 27_000).rondas.count, 0)
    }

    /// La guía oficial NO es una ronda y el recorte no se la puede comer: si la ronda que la
    /// trajo se cae por vieja, la guía se rescata y sigue en el prompt, exactamente una vez.
    func test_el_recorte_rescata_la_guia_de_la_ronda_que_se_cae() throws {
        let gorda = String(repeating: "a", count: 20_000)
        let rondas = [Agent.RondaDelTurno(texto: "r1 " + gorda, guia: "LA-GUIA"),
                      Agent.RondaDelTurno(texto: "r2 " + gorda),
                      Agent.RondaDelTurno(texto: "r3 " + gorda)]
        let recortado = Agent.recortaElHistorial(rondas, maxBytes: 27_000)
        XCTAssertEqual(recortado.rondas.count, 1, "solo cabe la más reciente")
        XCTAssertEqual(recortado.guiaRescatada, "LA-GUIA", "la guía sobrevive a su ronda")

        let prompt = Agent.promptVivo(base: "BASE", guiaRescatada: recortado.guiaRescatada, rondas: recortado.rondas)
        XCTAssertTrue(prompt.hasPrefix("BASE"), "el prompt del usuario va primero y nunca se recorta")
        XCTAssertEqual(prompt.components(separatedBy: "LA-GUIA").count - 1, 1, "una vez, ni dos ni ninguna")
        // Y RESCATADA VIVE COMO CABECERA, delante de las rondas que sobreviven. No es
        // cosmética: con la guía detrás, lo ÚLTIMO que el modelo leería en todas las rondas
        // siguientes serían los 14 KB del manual del CLI —que acaban en «Never echo or paste
        // secrets»— en vez del resultado de lo que acaba de hacer. La propiedad estaba escrita
        // en `recortaElHistorial` («desde ese momento vive como cabecera») y no la guardaba
        // nadie: una mutación que pusiera la guía rescatada detrás de las rondas sobrevivía a
        // la suite entera.
        let iGuiaRescatada = try XCTUnwrap(prompt.range(of: "LA-GUIA")?.lowerBound)
        let iRondaViva = try XCTUnwrap(prompt.range(of: "r3 ")?.lowerBound)
        XCTAssertLessThan(iGuiaRescatada, iRondaViva,
                          "la guía rescatada es cabecera: va delante de las rondas que sobreviven")

        // Y DENTRO DE SU RONDA, LA GUÍA VA DELANTE DEL TEXTO. Lo último que el modelo lee tiene
        // que ser la nota de resultado de la herramienta que acaba de ejecutar —que es lo que
        // `toolResultNote` documenta de sí misma, «gana sobre cualquier instrucción del prompt
        // del sistema»— y no el manual del CLI, que es la pieza que menos conoce este proyecto.
        let intacto = Agent.promptVivo(base: "BASE", guiaRescatada: nil, rondas: [rondas[0]])
        let iNota = try XCTUnwrap(intacto.range(of: "r1 ")?.lowerBound)
        let iGuia = try XCTUnwrap(intacto.range(of: "LA-GUIA")?.lowerBound)
        XCTAssertLessThan(iGuia, iNota,
                          "la guía va DELANTE del texto de su ronda, para que la nota quede última")
    }

    /// Snapshot falso que devuelve una página GRANDE —del tamaño que el propio tope de
    /// `BrowserSnapshotTool` permite— y DISTINTA en cada ronda, para poder decir cuál de las
    /// rondas sobrevivió al recorte y cuál no.
    final class FakeBrowserSnapshotGrande: AgentTool {
        static let name = "browser_snapshot"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        /// Relleno hasta el tope real que la herramienta de verdad aplica a un snapshot.
        static let relleno = String(repeating: "x", count: BrowserSnapshotTool.snapshotLimit - 100)
        static func marca(_ n: Int) -> String { "[[ronda-\(n)]]" }
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return #"{"status":"success","url":"https://a.test/","snapshot":"\#(Self.marca(Self.calls)) \#(Self.relleno)"}"#
        }
    }

    /// Con muchas rondas el prompt vivo NO crece sin límite: hay un tope en bytes y lo que cae
    /// es lo más viejo. Es el caso que hoy no acota nada — ocho rondas de navegador con un
    /// snapshot cada una son ~71 KB de historial, y `maxBrowserIterations` permite diez.
    ///
    /// Lo que sobrevive se afirma por los dos lados (la ronda 8 está, la 1 no), y con ello el
    /// prompt del usuario y la guía, que no son rondas y no se recortan.
    func test_con_muchas_rondas_el_historial_no_crece_sin_limite() async throws {
        let rondas = Array(repeating: [(name: "browser_snapshot", args: "{}")], count: 8) + [[]]
        let runtime = ScriptedRuntime(rondas)
        let registro = ToolRegistry()
        FakeBrowserSnapshotGrande.calls = 0
        registro.register(FakeBrowserSnapshotGrande())
        for try await _ in Agent(runtime: runtime, registry: registro).run(prompt: "mira la página ocho veces",
                                                                           options: GenerationOptions()) {}

        XCTAssertEqual(FakeBrowserSnapshotGrande.calls, 8, "las ocho rondas tienen que haber corrido")
        let ultimo = try XCTUnwrap(runtime.prompts.last)
        // LA PREMISA: sin tope, ocho rondas de este tamaño se pasan de largo.
        XCTAssertGreaterThan(8 * BrowserSnapshotTool.snapshotLimit, Agent.maxHistoryBytes)
        // El tope se respeta: historial acotado + lo que no es historial (base y guía).
        let techo = Agent.maxHistoryBytes + Agent.browserGuideBlock().utf8.count + 4_000
        XCTAssertLessThan(ultimo.utf8.count, techo, "el prompt vivo se pasó del tope: \(ultimo.utf8.count) bytes")
        // Lo más viejo cayó, lo más reciente está, y queda más de una ronda.
        XCTAssertFalse(ultimo.contains(FakeBrowserSnapshotGrande.marca(1)), "la ronda más vieja tenía que caer")
        XCTAssertTrue(ultimo.contains(FakeBrowserSnapshotGrande.marca(8)), "la ronda más reciente no se recorta nunca")
        let vivas = (1...8).filter { ultimo.contains(FakeBrowserSnapshotGrande.marca($0)) }
        XCTAssertGreaterThanOrEqual(vivas.count, 2, "el recorte no puede dejar solo la última: \(vivas)")
        XCTAssertEqual(vivas, Array(vivas.sorted()), "y lo que queda es el tramo más reciente, en orden")
        // Lo que no es historial no se recorta.
        XCTAssertTrue(ultimo.contains("mira la página ocho veces"), "el prompt del usuario se perdió")
        XCTAssertEqual(ultimo.components(separatedBy: BrowserCoreSkill.text).count - 1, 1,
                       "la guía tiene que seguir exactamente una vez")
    }

    /// El tope no es un número a ojo del todo: sale del tamaño que una ronda de navegador puede
    /// alcanzar DE VERDAD, que es el tope que la herramienta de snapshot ya aplica.
    func test_el_tope_del_historial_sale_del_tamano_real_de_una_ronda() {
        XCTAssertEqual(Agent.maxHistoryBytes, 3 * (BrowserSnapshotTool.snapshotLimit + 1_000))
        // Tres rondas gordas caben; cuatro no. Es la ventana útil: las `@eN` de un snapshot
        // anterior a la última navegación ya no valen (es lo que dice el corte de cola).
        let gorda = BrowserSnapshotTool.snapshotLimit + 900
        XCTAssertGreaterThanOrEqual(Agent.maxHistoryBytes, 3 * gorda)
        XCTAssertLessThan(Agent.maxHistoryBytes, 4 * gorda)
        // Y una ronda FLACA (un clic, un fill) pesa unos cientos de bytes, así que un turno de
        // conducción que no vuelque páginas enteras no llega a recortar nunca.
        let flaca = Agent.toolResultNote(toolName: "browser_click",
                                        result: #"{"status":"success","message":"Clic ejecutado en '@e3'."}"#)
        XCTAssertGreaterThan(Agent.maxHistoryBytes / flaca.utf8.count, Agent.maxBrowserIterations)
    }

    // MARK: - Vueltas en vacío: la misma lectura de la página una y otra vez

    /// Marca estable del aviso de vueltas en vacío, DERIVADA del propio aviso: así la prueba no
    /// vuelve a escribir a mano un texto que ya vive en `BrowserRules` (su única fuente).
    private var marcaDeLaVueltaEnVacio: String {
        String(BrowserRules.spinningWheelsNote(herramienta: "browser_snapshot",
                                               veces: Agent.vueltasEnVacioParaAvisar).prefix(40))
    }

    /// Una lectura de la página, que es lo único que la detección mira.
    private func accionDeLectura(_ nombre: String = "browser_snapshot",
                                 _ args: String = "{}") -> Agent.AccionEjecutada {
        Agent.AccionEjecutada(nombre: nombre, argumentos: args)
    }

    /// Una acción sobre la página: lo que rompe la racha de lecturas.
    private func accionSobreLaPagina() -> Agent.AccionEjecutada {
        Agent.AccionEjecutada(nombre: "browser_click", argumentos: #"{"ref":"@e3"}"#)
    }

    /// TRES lecturas idénticas seguidas son una vuelta en vacío; DOS no.
    ///
    /// Las dos mitades viven en la MISMA prueba a propósito: el umbral es parte de lo que se
    /// afirma, así que una función que devolviera `true` para todo moriría en la segunda
    /// aserción y una que devolviera `false` para todo moriría en la primera. Por separado cada
    /// mitad se cumpliría con la característica borrada.
    func test_tres_lecturas_identicas_seguidas_giran_en_vacio_y_dos_no() {
        let tres = Array(repeating: accionDeLectura(), count: 3)
        XCTAssertTrue(Agent.pareceAtascado(historial: tres),
                      "tres lecturas idénticas de una página que nadie tocó no avanzan nada")
        XCTAssertFalse(Agent.pareceAtascado(historial: Array(tres.prefix(2))),
                       "dos lecturas seguidas son normales: la página podía estar todavía pintando")
        XCTAssertFalse(Agent.pareceAtascado(historial: Array(tres.prefix(1))))
        XCTAssertFalse(Agent.pareceAtascado(historial: []), "un turno sin acciones no está atascado")
    }

    /// EL CICLO QUE EL PROMPT ENSEÑA NO ES UNA VUELTA EN VACÍO, y esto es el corazón de la
    /// detección.
    ///
    /// `BrowserRules.text` le enseña al modelo `snapshot` → actuar → `snapshot` porque las
    /// `@eN` caducan con cada acción. Marcar ese ciclo como bucle sería decirle que se equivoca
    /// justo cuando hace lo correcto, o sea peor que no mirar nada.
    func test_el_ciclo_que_el_prompt_ensena_no_gira_en_vacio() {
        XCTAssertFalse(Agent.pareceAtascado(historial: [accionDeLectura(),
                                                        accionSobreLaPagina(),
                                                        accionDeLectura()]),
                       "`snapshot → click → snapshot` es exactamente el ciclo que el prompt enseña")
        // La acción rompe la racha aunque haya lecturas de sobra alrededor.
        XCTAssertFalse(Agent.pareceAtascado(historial: [accionDeLectura(), accionDeLectura(),
                                                        accionSobreLaPagina(), accionDeLectura()]),
                       "la racha se cuenta desde la cola: entre medias pasó algo")
        // Y un turno que acaba de ACTUAR no está mirando en vacío, por muchas lecturas que
        // llevara detrás.
        XCTAssertFalse(Agent.pareceAtascado(historial: [accionDeLectura(), accionDeLectura(),
                                                        accionDeLectura(), accionSobreLaPagina()]),
                       "la última acción no es una lectura")
        // LA MITAD QUE EXIGE EL `true`, y comparte mutación con las tres de arriba: sin ella una
        // función que devolviera `false` para todo pasaría esta prueba entera sin detectar nada.
        XCTAssertTrue(Agent.pareceAtascado(historial: [accionDeLectura(), accionDeLectura(),
                                                       accionDeLectura()]),
                      "quitar la acción de en medio sí deja tres lecturas idénticas seguidas")
    }

    /// Una acción que CAMBIA algo, repetida, no entra por aquí.
    ///
    /// Las siete herramientas de mutación tienen ya su propia negativa (`executedMutations`), y
    /// dos frenos sobre el mismo caso se estorban: el modelo recibiría dos mensajes distintos
    /// sobre el mismo hecho. Y un clic idéntico repetido no es una prueba de nada —puede ser la
    /// tarea: «dale tres veces al +», «pulsa "ver más" hasta que salgan todos»—, así que acusar
    /// ahí sería acusar en falso.
    func test_lo_que_cambia_algo_no_entra_por_la_deteccion_de_vueltas_en_vacio() {
        let evento = Agent.AccionEjecutada(nombre: "create_event", argumentos: #"{"title":"cita"}"#)
        XCTAssertFalse(Agent.pareceAtascado(historial: Array(repeating: evento, count: 5)),
                       "una mutación repetida la para `executedMutations`, no esto")
        XCTAssertFalse(Agent.pareceAtascado(historial: Array(repeating: accionSobreLaPagina(), count: 5)),
                       "cinco clics idénticos pueden ser la tarea, no un bucle")
        // La mitad que exige el `true`: lo mismo cinco veces, pero LEYENDO, sí lo es.
        XCTAssertTrue(Agent.pareceAtascado(historial: Array(repeating: accionDeLectura(), count: 5)),
                      "cinco lecturas idénticas no pueden ser otra cosa que una vuelta en vacío")
        // Y las tres lecturas del contrato son las tres, no solo el snapshot.
        for nombre in Agent.browserReadOnlyToolNames {
            XCTAssertTrue(Agent.pareceAtascado(
                historial: Array(repeating: accionDeLectura(nombre), count: 3)),
                          "`\(nombre)` lee la página: repetirla tres veces es girar en vacío")
        }
    }

    /// LA MISMA llamada quiere decir el mismo nombre Y los mismos argumentos: tres lecturas de
    /// tres cosas distintas son tres preguntas distintas y avanzan.
    func test_argumentos_distintos_son_lecturas_distintas() {
        let h1 = accionDeLectura("browser_get", #"{"selector":"h1"}"#)
        let h2 = accionDeLectura("browser_get", #"{"selector":"h2"}"#)
        let h3 = accionDeLectura("browser_get", #"{"selector":"h3"}"#)
        XCTAssertFalse(Agent.pareceAtascado(historial: [h1, h2, h3]),
                       "tres selectores distintos son tres preguntas distintas")
        XCTAssertTrue(Agent.pareceAtascado(historial: [h1, h1, h1]),
                      "el mismo selector tres veces es la misma pregunta tres veces")
        // El espacio en blanco de los bordes no hace una llamada distinta. Se normaliza eso y
        // nada más: normalizar de menos pierde una detección (no pasa nada), normalizar de más
        // declara iguales dos llamadas que no lo eran y acusa en falso.
        XCTAssertTrue(Agent.pareceAtascado(historial: [accionDeLectura("browser_snapshot", "{}"),
                                                       accionDeLectura("browser_snapshot", "{} "),
                                                       accionDeLectura("browser_snapshot", "\n{}")]),
                      "un salto de línea de sobra no es una llamada distinta")
    }

    /// Y por el BUCLE: la tercera lectura idéntica trae el aviso al prompt vivo, y el aviso
    /// SUGIERE — no le retira las herramientas.
    ///
    /// La retirada ya existe por mutación y por cercanía al tope de rondas; adelantarla aquí le
    /// quitaría el navegador a mitad de una tarea legítima pero lenta, y lenta es lo normal en
    /// un navegador remoto sobre una conexión doméstica.
    func test_la_tercera_lectura_identica_trae_el_aviso_y_no_retira_las_herramientas() async throws {
        let guion: [[(name: String, args: String)]] = [
            [("browser_snapshot", "{}")],
            [("browser_snapshot", "{}")],
            [("browser_snapshot", "{}")],
            []
        ]
        let runtime = ScriptedRuntime(guion)
        for try await _ in Agent(runtime: runtime, registry: registroDeNavegadorFalsoConSnapshot())
            .run(prompt: "mira la página", options: GenerationOptions()) {}
        XCTAssertEqual(FakeBrowserSnapshot.calls, 3, "las tres lecturas tenían que ejecutarse")
        XCTAssertEqual(runtime.prompts.count, 4, "el turno tenía que llegar a la cuarta ronda")
        XCTAssertFalse(runtime.prompts[2].contains(marcaDeLaVueltaEnVacio),
                       "dos lecturas todavía no son un aviso: \(runtime.prompts[2].suffix(300))")
        XCTAssertTrue(runtime.prompts[3].contains(marcaDeLaVueltaEnVacio),
                      "la tercera lectura idéntica tenía que traer el aviso: \(runtime.prompts[3].suffix(400))")
        // El aviso dice QUÉ lleva repitiendo y CUÁNTAS veces.
        XCTAssertTrue(runtime.prompts[3].contains("`browser_snapshot` 3 times in a row"),
                      "el aviso tiene que nombrar la herramienta y las veces: \(runtime.prompts[3].suffix(400))")
        // Y NO se le retiran las herramientas: en la ronda siguiente al aviso siguen todas.
        let deLaRondaDelAviso = try XCTUnwrap(runtime.herramientasPorRonda.dropFirst(3).first)
        XCTAssertTrue(deLaRondaDelAviso.contains("browser_snapshot"),
                      "el aviso no puede quitarle el navegador a mitad de tarea: \(deLaRondaDelAviso)")
        XCTAssertTrue(deLaRondaDelAviso.contains("browser_click"))
    }

    // MARK: - El redactor engancha en el bucle

    /// El valor de un secreto que una herramienta devuelve (p. ej. una página que lo refleja) no
    /// puede llegar al siguiente prompt del modelo. Se afirma por los dos lados: el valor no está y
    /// el marcador sí, para que una herramienta que no devolviera nada no pasara en vacío.
    func test_el_resultado_de_una_herramienta_llega_al_modelo_sin_el_valor_del_secreto() async throws {
        let bóveda = SecretVault(almacen: AlmacenEnMemoria())
        XCTAssertTrue(bóveda.guarda(name: "gmail_pass", value: "hunter2-XYZ", etiqueta: "Gmail", origen: "a.test"))
        let registro = registroDeNavegadorFalsoConSnapshot()
        FakeBrowserSnapshot.resultado = #"{"status":"success","snapshot":"- textbox [ref=e1] value=hunter2-XYZ"}"#
        defer { FakeBrowserSnapshot.resultado =
            #"{"status":"success","url":"https://a.test/","snapshot":"- link \"Más\" [ref=e3]","element_count":1}"# }
        let runtime = ScriptedRuntime([[("browser_snapshot", "{}")], []])
        for try await _ in Agent(runtime: runtime, registry: registro, bóveda: bóveda)
            .run(prompt: "mira la página", options: GenerationOptions()) {}
        XCTAssertEqual(FakeBrowserSnapshot.calls, 1)
        XCTAssertFalse(runtime.prompts[1].contains("hunter2-XYZ"), "el valor llegó al modelo: \(runtime.prompts[1].suffix(300))")
        XCTAssertTrue(runtime.prompts[1].contains("[secreto: gmail_pass]"), "falta el marcador: \(runtime.prompts[1].suffix(300))")
    }

    /// Sin bóveda (el valor por omisión) el resultado pasa tal cual: el redactor es opt-in.
    func test_sin_boveda_el_resultado_no_se_toca() async throws {
        let registro = registroDeNavegadorFalsoConSnapshot()
        FakeBrowserSnapshot.resultado = #"{"status":"success","snapshot":"value=hunter2-XYZ"}"#
        defer { FakeBrowserSnapshot.resultado =
            #"{"status":"success","url":"https://a.test/","snapshot":"- link \"Más\" [ref=e3]","element_count":1}"# }
        let runtime = ScriptedRuntime([[("browser_snapshot", "{}")], []])
        for try await _ in Agent(runtime: runtime, registry: registro)
            .run(prompt: "mira la página", options: GenerationOptions()) {}
        XCTAssertTrue(runtime.prompts[1].contains("hunter2-XYZ"))
    }

    // MARK: - Que el usuario lea lo que la pagina dice, no lo que el modelo cuenta

    /// EL CASO REAL QUE ESTO EVITA: el `press` fallo y el modelo conto que habia puesto el
    /// video. La linea la escribe la APP y viaja en la respuesta del turno, asi que «te he
    /// puesto el video» y «el `press` fallo» no pueden aparecer juntos sin que se note.
    ///
    /// La linea se compara ENTERA y DERIVADA de produccion, no por un prefijo: un ancla de
    /// prefijo deja pasar cualquier mutacion de la cola de la frase. Lo que esta prueba fija es
    /// el CABLEADO —que lo que la funcion produce llega a la respuesta del usuario—; el
    /// CONTENIDO lo fija `test_la_linea_de_estado_nunca_imprime_el_message_de_la_herramienta`,
    /// porque los dos lados de esta igualdad salen de la misma funcion.
    func test_la_ultima_accion_fallida_del_navegador_llega_al_usuario_en_la_respuesta() async throws {
        let runtime = ScriptedRuntime([[(name: "browser_press", args: #"{"key":"Enter"}"#)], []],
                                      prosa: ["", "Ya te he puesto el video."])
        let visto = try await ejecuta(runtime, registroConLaQueFalla())

        XCTAssertEqual(FakeBrowserAlwaysFails.calls, 1,
                       "un solo fallo: el presupuesto no se agota y el turno termina por lo normal")
        let linea = try XCTUnwrap(
            Agent.lineaDeEstadoDelNavegador(herramienta: "browser_press",
                                            resultado: FakeBrowserAlwaysFails.resultado),
            "la accion fallida tiene que producir linea")
        XCTAssertEqual(visto.completados, ["Ya te he puesto el video.\n\n" + linea],
                       "la respuesta del turno tiene que llevar la linea de estado: \(visto.completados)")
        XCTAssertEqual(visto.fallados, [], "nada de esto saca al turno por un `.failed`")
    }

    /// Y CON TODO EN EXITO NO LLEVA NADA: a lo que funciona no se le pone ruido.
    ///
    /// POR QUE ESTA PRUEBA NO ES TRIVIAL, que es el riesgo de toda afirmacion en negativo. Una
    /// implementacion que no anadiera NUNCA la linea la pasaria entera. Dos cosas la sostienen:
    /// va acompanada de la de arriba —que exige que la linea SI este— y aqui mismo se afirma
    /// que la funcion es capaz de producirla. Las tres pruebas de esta seccion comparten
    /// mutacion a proposito.
    func test_un_turno_de_navegador_en_exito_no_lleva_la_linea_de_estado() async throws {
        let runtime = ScriptedRuntime([
            [(name: "browser_open", args: #"{"url":"https://a.test/"}"#)],
            [(name: "browser_click", args: #"{"selector":"@e3"}"#)],
            []
        ], prosa: ["", "", "Listo, ahi lo tienes."])
        let visto = try await ejecuta(runtime, registroDeNavegadorFalso())

        XCTAssertEqual(FakeBrowserOpen.calls, 1)
        XCTAssertEqual(FakeBrowserClick.calls, 1)
        XCTAssertEqual(visto.completados, ["Listo, ahi lo tienes."],
                       "un turno que salio bien no lleva ni un byte de mas: \(visto.completados)")
        XCTAssertNil(Agent.lineaDeEstadoDelNavegador(herramienta: "browser_click",
                                                     resultado: FakeBrowserClick.resultado),
                     "un exito no produce linea")
        // LA MITAD QUE HACE VALER LA DE ARRIBA: un fallo SI la produce. Sin esto, una funcion
        // que devolviera `nil` para todo verdearia esta prueba sin que nada funcionase.
        XCTAssertNotNil(Agent.lineaDeEstadoDelNavegador(herramienta: "browser_click",
                                                        resultado: #"{"status":"error"}"#),
                        "un fallo tiene que producir linea")
    }

    /// UN CIERRE RECHAZADO POR EL CANDADO NO ENSUCIA UN TURNO QUE SALIO BIEN.
    ///
    /// EL CASO MEDIDO, Y ES EL TURNO DE NAVEGADOR MAS COMUN. El usuario pide un video, el turno
    /// lo pone, el modelo llama a `browser_close` —porque la guia oficial del CLI que esta misma
    /// rama le inyecta dice «Run `agent-browser close` when you're done»—, el candado de la app
    /// lo RECHAZA (conducta correcta), y la app le pegaba a la respuesta un «la ultima accion
    /// sobre la pagina, `browser_close`, devolvio `refused` y no se llego a hacer … no te fies
    /// de esa parte». Todo habia salido bien y la app le decia al usuario que desconfiara.
    ///
    /// LAS TRES MITADES COMPARTEN MUTACION, Y POR ESO NINGUNA ES VACUA. Vaciar
    /// `browserToolNamesThatDoNotTouchThePage` resucita el defecto y mata (a) y (c); meter en el
    /// conjunto a todas las herramientas del navegador mata (b). Una implementacion que no
    /// pusiera NUNCA la linea no verdearia esto: (b) la exige entera.
    func test_un_close_rechazado_no_ensucia_el_turno_y_no_tapa_un_fallo_de_verdad() async throws {
        // (a) `open` con exito y `close` rechazado: la respuesta del modelo sale limpia.
        let runtime = ScriptedRuntime([
            [(name: "browser_open", args: #"{"url":"https://a.test/"}"#)],
            [(name: "browser_close", args: "{}")],
            []
        ], prosa: ["", "", "Listo: te he puesto el video y lo tienes en pantalla."])
        let registro = registroDeNavegadorFalso()
        FakeBrowserCloseRefused.calls = 0
        registro.register(FakeBrowserCloseRefused())
        let visto = try await ejecuta(runtime, registro)

        XCTAssertEqual(FakeBrowserCloseRefused.calls, 1, "el cierre se llamo y el candado lo rechazo")
        XCTAssertTrue(Agent.esFallo(resultado: FakeBrowserCloseRefused.resultado),
                      "la premisa: `refused` SI es un fallo a ojos del presupuesto, y aun asi la "
                      + "linea no se escribe. Sin esto la prueba verdearia por el motivo equivocado")
        XCTAssertEqual(visto.completados, ["Listo: te he puesto el video y lo tienes en pantalla."],
                       "un cierre rechazado no es una accion sobre la pagina: \(visto.completados)")

        // (b) LA MITAD QUE LA SOSTIENE: una accion que SI actua sobre la pagina y falla si
        // produce la linea, en el mismo bucle y con el mismo cableado.
        let runtimeFallo = ScriptedRuntime([[(name: "browser_press", args: #"{"key":"Enter"}"#)], []],
                                           prosa: ["", "Ya te lo he puesto."])
        let vistoFallo = try await ejecuta(runtimeFallo, registroConLaQueFalla())
        let linea = try XCTUnwrap(
            Agent.lineaDeEstadoDelNavegador(herramienta: "browser_press",
                                            resultado: FakeBrowserAlwaysFails.resultado))
        XCTAssertEqual(vistoFallo.completados, ["Ya te lo he puesto.\n\n" + linea],
                       "un fallo SOBRE la pagina sigue llegando al usuario: \(vistoFallo.completados)")

        // (c) Y UN CIERRE RECHAZADO NO TAPA EL FALLO ANTERIOR. Es la razon por la que la
        // exclusion vive al APUNTAR la accion y no al redactar la linea: si viviera dentro de
        // `lineaDeEstadoDelNavegador`, el `close` habria sobrescrito la ultima accion del turno
        // y este aviso —que es cierto— se habria perdido.
        let runtimeMixto = ScriptedRuntime([
            [(name: "browser_press", args: #"{"key":"Enter"}"#)],
            [(name: "browser_close", args: "{}")],
            []
        ], prosa: ["", "", "Hecho."])
        let registroMixto = registroConLaQueFalla()
        FakeBrowserCloseRefused.calls = 0
        registroMixto.register(FakeBrowserCloseRefused())
        let vistoMixto = try await ejecuta(runtimeMixto, registroMixto)

        XCTAssertEqual(FakeBrowserCloseRefused.calls, 1)
        XCTAssertEqual(vistoMixto.completados, ["Hecho.\n\n" + linea],
                       "el cierre no puede tapar el `press` que de verdad fallo: \(vistoMixto.completados)")

        // (d) La funcion pura, que es donde la decision esta escrita.
        XCTAssertFalse(Agent.actuaSobreLaPagina("browser_close"), "cerrar no es actuar sobre la pagina")
        XCTAssertTrue(Agent.actuaSobreLaPagina("browser_press"))
        XCTAssertTrue(Agent.actuaSobreLaPagina("browser_click"))
        XCTAssertFalse(Agent.actuaSobreLaPagina("web_search"), "ni siquiera es del navegador")
    }

    /// LA LINEA VIAJA DECLARADA COMO AVISO DE LA APP, NO COMO VOZ DEL ASISTENTE.
    ///
    /// EL DEFECTO QUE CIERRA, Y NADIE LO HABIA DECLARADO. El `text` del `.completed` es
    /// exactamente lo que el arnes persiste en el servicio de memoria como «lo que dijo el
    /// asistente» (`HarnessModel` → `appendTranscript`), asi que la linea de la app —«la ultima
    /// accion sobre la pagina devolvio `refused`»— acababa guardada como una frase del
    /// asistente, pasaba por los resumenes, por la consolidacion y por `reflect`, y podia
    /// terminar convertida en un «insight» sobre el usuario.
    ///
    /// LAS DOS MITADES, EN LA MISMA FUNCION: un turno con un fallo DECLARA el aviso y un turno
    /// en exito NO declara ninguno. Y la ultima afirmacion ata las dos piezas de produccion —la
    /// declaracion del bucle y el filtro del arnes— sobre el mismo dato, que es lo que impide
    /// que esto verdee con un `appNotice` que nadie usa.
    func test_la_linea_de_estado_viaja_declarada_como_aviso_de_la_app() async throws {
        func resultadoDelTurno(_ runtime: ScriptedRuntime,
                               _ registro: ToolRegistry) async throws -> GenerationResult {
            var completados: [GenerationResult] = []
            for try await e in Agent(runtime: runtime, registry: registro).run(prompt: "x",
                                                                              options: GenerationOptions()) {
                if case .completed(let r) = e { completados.append(r) }
            }
            return try XCTUnwrap(completados.first, "el turno no entrego respuesta")
        }

        let conFallo = try await resultadoDelTurno(
            ScriptedRuntime([[(name: "browser_press", args: #"{"key":"Enter"}"#)], []],
                            prosa: ["", "Ya te lo he puesto."]),
            registroConLaQueFalla())
        let linea = try XCTUnwrap(
            Agent.lineaDeEstadoDelNavegador(herramienta: "browser_press",
                                            resultado: FakeBrowserAlwaysFails.resultado))
        XCTAssertEqual(conFallo.appNotice, linea, "la app declara cual es SU sufijo")
        XCTAssertTrue(conFallo.text.hasSuffix(linea),
                      "y esta de verdad al final del texto, que es lo que el arnes comprueba")
        XCTAssertEqual(HarnessModel.sinElAvisoDeLaApp(conFallo.text, aviso: conFallo.appNotice),
                       "Ya te lo he puesto.",
                       "lo que se archiva es la respuesta del modelo, sin el aviso de la app")

        let enExito = try await resultadoDelTurno(
            ScriptedRuntime([[(name: "browser_click", args: #"{"selector":"@e3"}"#)], []],
                            prosa: ["", "Listo."]),
            registroDeNavegadorFalso())
        XCTAssertNil(enExito.appNotice, "un turno que salio bien no declara ningun aviso")
        XCTAssertEqual(enExito.text, "Listo.")
    }

    /// EL CORAZON: la linea NUNCA imprime el `message` de la herramienta.
    ///
    /// Esos textos estan redactados para el MODELO —segunda persona, con instrucciones— y
    /// llevar sus instrucciones a la pantalla del usuario costo su propia rama (ver
    /// `ToolSyntaxStreamGate`). Es la misma regla que ya cumple el resumen de la fila de
    /// herramienta (`ToolLogRow.needsYouText`, y la rama `case nil` de `summarize`).
    ///
    /// SE MIDE POR LOS DOS CANALES A LA VEZ SOBRE EL MISMO DATO, y eso es lo que hace fuerte a
    /// esta prueba. Afirmar solo la ausencia verdearia de tres maneras distintas sin que nada
    /// funcionase: con la linea vacia, con un `message` vacio, o con una respuesta que no se
    /// construyo. Aqui el MISMO motivo tiene que llegar entero al prompt del modelo y NO estar
    /// en la respuesta del usuario, y la respuesta tiene que decir algo mas que la narracion
    /// del modelo.
    func test_la_linea_de_estado_nunca_imprime_el_message_de_la_herramienta() async throws {
        // (a) La funcion pura, con un `message` redactado para el modelo.
        let mensajeParaElModelo = "Pulsa el boton otra vez y dime que paso."
        let linea = try XCTUnwrap(Agent.lineaDeEstadoDelNavegador(
            herramienta: "browser_press",
            resultado: "{\"status\":\"error\",\"message\":\"\(mensajeParaElModelo)\"}"))
        XCTAssertFalse(linea.isEmpty, "una linea vacia cumpliria la ausencia sin decir nada")
        XCTAssertFalse(linea.contains(mensajeParaElModelo), "el `message` no se pinta: \(linea)")
        XCTAssertFalse(linea.contains("Pulsa el boton"), "ni un trozo del `message`: \(linea)")
        XCTAssertTrue(linea.contains("`browser_press`"), "la linea nombra la accion: \(linea)")
        XCTAssertTrue(linea.contains("error"), "y el estado con el que se declaro el fallo: \(linea)")
        // Es para el USUARIO, no para el modelo: en espanol, como el mensaje de presupuesto
        // agotado, y sin una sola de las frases en segunda persona inglesa del prompt vivo.
        XCTAssertFalse(linea.contains("You "), "la linea no es una nota al modelo: \(linea)")

        // (b) Por el bucle: el mismo dato, dos canales.
        let runtime = ScriptedRuntime([[(name: "browser_press", args: #"{"key":"Enter"}"#)], []],
                                      prosa: ["", "Ya te he puesto el video."])
        let visto = try await ejecuta(runtime, registroConLaQueFalla())
        let respuesta = try XCTUnwrap(visto.completados.first, "el turno no entrego respuesta")
        let segundoPrompt = try XCTUnwrap(runtime.prompts.dropFirst().first,
                                          "el bucle no volvio a llamar al modelo")
        XCTAssertTrue(segundoPrompt.contains(FakeBrowserAlwaysFails.motivo),
                      "el motivo entero tiene que seguir llegando al MODELO")
        XCTAssertFalse(respuesta.contains(FakeBrowserAlwaysFails.motivo),
                       "y no tiene que llegar al USUARIO: \(respuesta)")
        XCTAssertTrue(respuesta.contains("`browser_press`"),
                      "pero el usuario si se entera de QUE accion no se hizo: \(respuesta)")
        XCTAssertNotEqual(respuesta, "Ya te he puesto el video.",
                          "la respuesta no puede quedarse en la narracion del modelo: \(respuesta)")
    }
}
