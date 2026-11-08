import XCTest
@testable import Gemma

/// La guía oficial de `agent-browser` delante del modelo, y nuestras reglas con UNA sola
/// fuente.
///
/// Tres cosas distintas se prueban aquí:
///   1. Que el texto oficial vendorizado (`BrowserCoreSkill.text`) sigue siendo el que dice
///      su cabecera —versión del CLI, fecha, comando y bytes—, para que nadie pueda jurar
///      que es la guía de 0.41.2 sin que se note si alguien la re-capturó de otra versión.
///      Se queda byte a byte como la imprime el CLI: nuestras reglas NO se meten dentro, para
///      poder diffearla contra el original cuando subamos de versión.
///   2. Que la inyección se comporta como se diseñó, medida en el prompt vivo que recibe el
///      modelo: un turno sin navegador no la lleva, un turno con navegador la lleva UNA vez
///      y un turno con varias llamadas de navegador sigue llevándola UNA vez. Se cuentan
///      apariciones, no se pregunta `contains`: el fallo que importa (inyectarla en cada
///      llamada y repetirla diez veces en un turno de conducción) pasa un `contains`.
///   3. Que nuestras reglas (`BrowserRules`) salen de una sola constante y se renderizan en
///      los dos sitios desde ella, para que no puedan DIVERGIR, que es el riesgo real de
///      tenerlas escritas dos veces.
@MainActor
final class BrowserCoreSkillTests: XCTestCase {

    // MARK: - El texto oficial vendorizado

    /// Tamaño exacto, anclado a la cabecera del fichero generado. La cabecera dice
    /// «`agent-browser skills get core`, CLI 0.41.2, 2026-11-08, 14457 bytes»; si alguien
    /// re-genera el fichero desde otra versión del CLI, o lo recorta a mano, este test se
    /// pone rojo y obliga a actualizar la procedencia en lugar de dejarla mintiendo.
    func test_la_guia_vendorizada_mide_exactamente_lo_que_dice_su_cabecera() {
        XCTAssertEqual(BrowserCoreSkill.text.utf8.count, 14457,
                       "la guía vendorizada ya no mide lo que declara la cabecera de BrowserCoreSkill.swift")
        // Principio y fin, para que un recorte que casualmente cuadrase en bytes no pase.
        XCTAssertTrue(BrowserCoreSkill.text.hasPrefix("---\nname: core\n"),
                      "falta el frontmatter con el que empieza la salida del CLI")
        XCTAssertTrue(BrowserCoreSkill.text.hasSuffix("Load `references/trust-boundaries.md` for the full rules.\n"),
                      "la guía no termina donde termina la salida del CLI")
        // El literal es crudo: el markdown entra sin escapes y sin que Swift interprete nada.
        // Si alguien lo pasara a un literal normal, estas tres sobrevivirían solo si escapó a
        // mano todas las comillas y almohadillas.
        XCTAssertTrue(BrowserCoreSkill.text.contains(##"agent-browser snapshot -s "#main""##),
                      "se perdió una comilla o una almohadilla al vendorizar")
        XCTAssertTrue(BrowserCoreSkill.text.contains("agent-browser click @e1"),
                      "falta el bloque de interacción de la guía")
        XCTAssertTrue(BrowserCoreSkill.text.contains("Snapshot refs are the fastest and most reliable option."),
                      "falta la regla de refs de la guía")
    }

    /// El texto oficial se queda intacto: nuestras reglas van DELANTE, no DENTRO. Es lo que
    /// permite diffear esta copia contra la salida del CLI al subir de versión.
    func test_el_texto_oficial_no_lleva_nuestras_reglas_dentro() {
        XCTAssertFalse(BrowserCoreSkill.text.contains(BrowserRules.closeRule),
                       "nuestras reglas se han colado dentro del texto oficial")
        XCTAssertFalse(BrowserCoreSkill.text.contains("An email address is NOT a secret"),
                       "nuestras reglas se han colado dentro del texto oficial")
    }

    // MARK: - Una sola fuente para nuestras reglas

    /// La prueba que de verdad importa del rediseño: el texto de nuestras reglas aparece
    /// LITERAL en las dos renderizaciones, así que las dos salen de la misma constante. Si
    /// alguien forkea una copia a mano en cualquiera de los dos sitios, la copia deja de
    /// coincidir con `BrowserRules.text` y este test se pone rojo.
    func test_nuestras_reglas_salen_de_una_sola_constante() {
        XCTAssertTrue(Agent.systemPromptText.contains(BrowserRules.text),
                      "el prompt del sistema no está renderizando BrowserRules.text")
        XCTAssertTrue(Agent.browserGuideBlock().contains(BrowserRules.text),
                      "la guía inyectada no está renderizando BrowserRules.text")
        // Y la línea del navegador del prompt sigue siendo UNA sola línea: dos tests de
        // `AgentSystemPromptTests` localizan nuestras reglas partiendo el prompt por saltos
        // de línea y buscando la que contiene `browser_open(url)`.
        XCTAssertFalse(BrowserRules.text.contains("\n"),
                       "BrowserRules.text tiene que ser una sola línea de prompt")
        let linea = Agent.systemPromptText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains("browser_open(url)") }
        XCTAssertNotNil(linea, "la línea del navegador desapareció del prompt del sistema")
        XCTAssertTrue(String(linea ?? "").contains(BrowserRules.text),
                      "las reglas tienen que caber enteras en esa única línea")
    }

    /// El candado de cierre se renderiza en TRES sitios (prompt, guía inyectada y nota de
    /// resultado de cada herramienta de navegador) y los tres salen de `closeRule`. Antes del
    /// rediseño estaba escrito dos veces con palabras distintas, que es la divergencia que
    /// esta constante impide.
    func test_el_candado_de_cierre_sale_de_la_misma_constante_en_los_tres_sitios() {
        XCTAssertTrue(BrowserRules.text.contains(BrowserRules.closeRule),
                      "las reglas ya no incluyen el candado de cierre")
        XCTAssertTrue(Agent.systemPromptText.contains(BrowserRules.closeRule),
                      "el prompt del sistema no renderiza el candado desde la constante")
        XCTAssertTrue(Agent.toolResultNote(toolName: "browser_open", args: "{}", result: "ok")
                        .contains(BrowserRules.closeRule),
                      "la nota de resultado no renderiza el candado desde la constante")
        XCTAssertTrue(Agent.browserGuideBlock().contains(BrowserRules.closeRule),
                      "la guía inyectada no renderiza el candado desde la constante")
    }

    /// El argumento de seguridad del rediseño, medido: las reglas están presentes en la
    /// PRIMERA llamada al modelo, antes de que haya decidido y ejecutado ninguna acción.
    ///
    /// Si vivieran solo en la guía inyectada —que llega con el resultado de la primera
    /// herramienta de navegador— el modelo podría teclear la contraseña del usuario en su
    /// primer movimiento y leer la prohibición después. Por eso hay dos renderizaciones.
    func test_las_reglas_estan_desde_el_primer_token_no_solo_en_la_guia() async throws {
        let rt = CapturingFirstCallRuntime()
        for try await _ in Agent(runtime: rt, registry: ToolRegistry()).run(prompt: "abre gmail", options: GenerationOptions()) {}
        XCTAssertTrue(rt.firstSystemPrompt.contains(BrowserRules.text),
                      "las reglas del navegador tienen que viajar en el prompt del sistema de la PRIMERA llamada")
        XCTAssertTrue(rt.firstSystemPrompt.contains("What you must not type is a password"),
                      "la prohibición de teclear una contraseña llega antes de poder teclearla")
    }

    /// Captura el prompt del sistema de la primera llamada y no pide herramientas.
    final class CapturingFirstCallRuntime: ToolCallingRuntime {
        var firstSystemPrompt = ""
        private var calls = 0
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            if calls == 0 { firstSystemPrompt = options.systemPrompt ?? "" }
            calls += 1
            return AsyncThrowingStream { c in
                c.yield(.completed(GenerationResult(text: "ok", metrics: RuntimeMetrics(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    // MARK: - Runtime guionizado

    /// Runtime que, ronda a ronda, pide las herramientas que le diga el guion y nunca las
    /// ejecuta (el `isFinal` del bucle de `Agent` depende de que nadie emita
    /// `toolCallFinished`). Cuando el guion se agota deja de pedir herramientas, con lo que
    /// el turno termina solo.
    ///
    /// Guarda cada prompt que le llega: el prompt vivo es acumulativo, así que el ÚLTIMO es
    /// el que contiene todo lo que el turno fue añadiendo y es donde se cuenta la guía.
    final class ScriptedRoundsRuntime: ToolCallingRuntime {
        private let rounds: [[String]]
        private var round = 0
        var prompts: [String] = []
        /// Ventana declarada por este runtime. `nil` (por omisión) = no la declara, como los
        /// runtimes de servidor.
        let contextTokenBudget: Int?

        init(rounds: [[String]], contextTokenBudget: Int? = nil) {
            self.rounds = rounds
            self.contextTokenBudget = contextTokenBudget
        }

        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            prompts.append(prompt)
            let calls = round < rounds.count ? rounds[round] : []
            round += 1
            return AsyncThrowingStream { c in
                for name in calls { c.yield(.toolCallStarted(name: name, args: "{}")) }
                c.yield(.completed(GenerationResult(text: "listo", metrics: RuntimeMetrics(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    /// Corre un turno con ese guion y devuelve el último prompt vivo que vio el modelo.
    private func lastLivePrompt(rounds: [[String]], contextTokenBudget: Int? = nil) async throws -> String {
        let runtime = ScriptedRoundsRuntime(rounds: rounds, contextTokenBudget: contextTokenBudget)
        // Registro vacío a propósito: ninguna herramienta real corre, pero el bucle construye
        // igual la nota de resultado, que es lo que se está midiendo.
        for try await _ in Agent(runtime: runtime, registry: ToolRegistry()).run(prompt: "haz la tarea", options: GenerationOptions()) {}
        return try XCTUnwrap(runtime.prompts.last, "el bucle no llamó ni una vez al modelo")
    }

    private func veces(_ aguja: String, en pajar: String) -> Int {
        guard !aguja.isEmpty else { return 0 }
        return pajar.components(separatedBy: aguja).count - 1
    }

    // MARK: - La inyección, medida por conducta

    /// (i) Un turno que no toca el navegador no paga la guía. Es la mitad del motivo de que
    /// la guía NO viva en el prompt del sistema: la mayoría de los turnos son preguntas.
    func test_un_turno_sin_navegador_nunca_lleva_la_guia() async throws {
        let prompt = try await lastLivePrompt(rounds: [["web_search"], ["get_current_time"]])
        XCTAssertEqual(veces(BrowserCoreSkill.text, en: prompt), 0,
                       "un turno sin navegador no debe cargar con los 14 KB de la guía")
        XCTAssertEqual(veces(Agent.browserGuidePreamble, en: prompt), 0,
                       "ni con su frase de precedencia")
        XCTAssertEqual(veces(BrowserRules.text, en: prompt), 0,
                       "ni con la copia de nuestras reglas que acompaña a la guía")
    }

    /// (ii) El primer navegador del turno la trae, y una sola vez.
    func test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez() async throws {
        let prompt = try await lastLivePrompt(rounds: [["browser_open"]])
        XCTAssertEqual(veces(BrowserCoreSkill.text, en: prompt), 1,
                       "la guía tiene que llegar exactamente una vez")
        XCTAssertEqual(veces(BrowserRules.text, en: prompt), 1,
                       "nuestras reglas la acompañan exactamente una vez")
        // Y llega pegada a la nota de ESA herramienta, que es el sitio donde sirve: lo último
        // que el modelo lee antes de decidir el paso siguiente sobre la página.
        //
        // La nota se localiza por su CABECERA, y el resultado se comprueba por su motivo. El
        // resultado entero no se puede buscar: el bucle contesta a una herramienta que no está
        // en el registro —el caso de `lastLivePrompt`, con su registro vacío— con el JSON de
        // `Agent.resultadoDeHerramientaInexistente`, y `ToolJSONOutput.object` serializa un
        // diccionario sin pedir `.sortedKeys`, así que **el orden de las claves no es estable
        // entre dos llamadas del mismo proceso**: está medido, el mismo proceso produjo
        // `{"status":…,"message":…}` para la nota esperada y `{"message":…,"status":…}` para la
        // del prompt, y la prueba se puso roja 1 de cada 3 veces. Las dos piezas de aquí sí son
        // estables, y las dos se DERIVAN de producción en vez de escribirse a mano.
        let notaConSenal = Agent.toolResultNote(toolName: "browser_open", args: "{}", result: "\u{1}R\u{1}")
        let finDeLaCabecera = try XCTUnwrap(notaConSenal.range(of: "\u{1}R\u{1}")?.lowerBound)
        let cabeceraDeLaNota = String(notaConSenal[..<finDeLaCabecera])
        let motivo = try XCTUnwrap(
            Agent.motivoDelResultado(Agent.resultadoDeHerramientaInexistente(nombre: "browser_open")))
        XCTAssertTrue(prompt.contains(motivo),
                      "el resultado de la herramienta tiene que viajar en la nota: \(prompt.suffix(300))")
        let indiceNota = try XCTUnwrap(prompt.range(of: cabeceraDeLaNota)?.lowerBound,
                                       "la cabecera de la nota no esta en el prompt vivo: \(cabeceraDeLaNota)")
        let indiceGuia = try XCTUnwrap(prompt.range(of: BrowserCoreSkill.text)?.lowerBound)
        XCTAssertLessThan(indiceNota, indiceGuia, "la guía va DETRÁS de la nota de la herramienta que la trae")
    }

    /// (iii) Tres llamadas de navegador en la MISMA ronda: una sola guía.
    func test_tres_llamadas_de_navegador_en_una_ronda_siguen_llevando_la_guia_una_vez() async throws {
        let prompt = try await lastLivePrompt(rounds: [["browser_open", "browser_snapshot", "browser_click"]])
        XCTAssertEqual(veces(Agent.browserGuidePreamble, en: prompt), 1,
                       "tres herramientas de navegador en una ronda siguen siendo UNA guía")
        XCTAssertEqual(veces(BrowserCoreSkill.text, en: prompt), 1)
        XCTAssertEqual(veces(BrowserRules.text, en: prompt), 1)
        // Las tres notas sí están: lo que no se repite es la guía.
        XCTAssertEqual(veces("You MAY keep calling browser tools", en: prompt), 3,
                       "las tres notas de resultado se siguen añadiendo")
    }

    /// (iii bis) Tres RONDAS de navegador, que es la forma real de conducir una página. El
    /// prompt vivo es acumulativo, así que una guía por llamada se vería aquí como tres.
    func test_tres_rondas_de_navegador_siguen_llevando_la_guia_una_vez() async throws {
        let prompt = try await lastLivePrompt(rounds: [["browser_open"], ["browser_snapshot"], ["browser_click"]])
        XCTAssertEqual(veces(Agent.browserGuidePreamble, en: prompt), 1,
                       "tres rondas de navegador siguen siendo UNA guía")
        XCTAssertEqual(veces(BrowserCoreSkill.text, en: prompt), 1)
        XCTAssertEqual(veces(BrowserRules.text, en: prompt), 1)
    }

    /// (iv) Un turno que empieza sin navegador y lo toca después la recibe en ese momento,
    /// no al principio: la primera herramienta de navegador es el disparador, no la ronda 0.
    func test_la_guia_llega_cuando_aparece_el_navegador_aunque_el_turno_empiece_sin_el() async throws {
        let runtime = ScriptedRoundsRuntime(rounds: [["web_search"], ["browser_open"]])
        for try await _ in Agent(runtime: runtime, registry: ToolRegistry()).run(prompt: "busca y abre", options: GenerationOptions()) {}
        XCTAssertGreaterThanOrEqual(runtime.prompts.count, 3, "el turno tenía que llegar a la tercera ronda")
        XCTAssertEqual(veces(Agent.browserGuidePreamble, en: runtime.prompts[1]), 0,
                       "tras la ronda de `web_search` la guía todavía no se ha pagado")
        XCTAssertEqual(veces(Agent.browserGuidePreamble, en: runtime.prompts[2]), 1,
                       "tras el primer `browser_open` la guía ya está, una vez")
    }

    /// (v) En el bloque inyectado el orden es: NUESTRAS reglas → frase de precedencia → texto
    /// oficial. La frase no es decorativa: la guía oficial manda `agent-browser close` «when
    /// you're done», que choca de frente con el candado de cierre de la app.
    func test_nuestras_reglas_van_delante_del_texto_oficial_con_la_frase_de_precedencia() async throws {
        // La contradicción existe de verdad: si la guía dejara de decir esto, esta prueba ya
        // no estaría protegiendo nada y conviene saberlo.
        XCTAssertTrue(BrowserCoreSkill.text.contains("agent-browser close"),
                      "la guía ya no manda cerrar; revisa si la frase de precedencia sigue hablando de algo")

        let bloque = Agent.browserGuideBlock()
        let iReglas = try XCTUnwrap(bloque.range(of: BrowserRules.text)?.lowerBound)
        let iInventario = try XCTUnwrap(bloque.range(of: BrowserRules.toolInventoryNote)?.lowerBound)
        let iFrase = try XCTUnwrap(bloque.range(of: Agent.browserGuidePreamble)?.lowerBound)
        let iGuia = try XCTUnwrap(bloque.range(of: BrowserCoreSkill.text)?.lowerBound)
        XCTAssertLessThan(iReglas, iInventario, "nuestras reglas van primero")
        XCTAssertLessThan(iInventario, iFrase, "el inventario de herramientas va antes de la frase")
        XCTAssertLessThan(iFrase, iGuia, "la frase de precedencia va entre el inventario y la guía")

        let p = Agent.browserGuidePreamble.lowercased()
        XCTAssertTrue(p.contains("the rules above win"), "falta quién gana: \(Agent.browserGuidePreamble)")
        XCTAssertTrue(p.contains("you do not close the browser"),
                      "la frase debe desactivar el `agent-browser close` de la guía")

        // Y el bloque entero llega al prompt vivo, no solo existe como constante.
        let prompt = try await lastLivePrompt(rounds: [["browser_open"]])
        XCTAssertTrue(prompt.contains(bloque), "el bloque completo tiene que llegar al prompt vivo")
    }

    /// El prompt del sistema NO carga con la guía OFICIAL: ése es el diseño que estos tests
    /// fijan. Los ~14 KB se pagan solo en los turnos que abren una página. Nuestras reglas sí
    /// están ahí, y a propósito: son ~2 KB y gobiernan la decisión de actuar.
    func test_el_prompt_del_sistema_no_carga_con_la_guia_oficial() {
        XCTAssertFalse(Agent.systemPromptText.contains(BrowserCoreSkill.text))
        XCTAssertFalse(Agent.systemPromptText.contains(Agent.browserGuidePreamble))
        // Ancla fina, para que un pegado parcial tampoco pase: el frontmatter de la guía es
        // inconfundible y no tiene por qué aparecer nunca en el prompt del sistema.
        XCTAssertFalse(Agent.systemPromptText.contains("allowed-tools: Bash(agent-browser"),
                       "el prompt del sistema se ha tragado (parte de) la guía")
    }

    /// Nuestras reglas específicas del proyecto siguen presentes: la guía oficial se AÑADE, no
    /// las reemplaza.
    func test_nuestras_reglas_siguen_en_el_prompt_del_sistema() {
        let p = Agent.systemPromptText
        XCTAssertTrue(p.contains("You do NOT close the browser"), "se borró nuestra regla de cierre")
        XCTAssertTrue(p.contains("refused"), "se borró que el `refused` es correcto")
        XCTAssertTrue(p.contains("`browser_snapshot`"), "se borró el bucle de conducción")
        XCTAssertTrue(p.contains("An email address is NOT a secret"), "se borró la regla del correo")
        XCTAssertTrue(p.contains("What you must not type is a password"), "se borró la regla de la contraseña")
    }

    // MARK: - Resolución 12: la guía documenta un CLI más grande que nuestro agente

    /// La línea que avisa de eso nombra las herramientas que de verdad tenemos, y las nombra
    /// DERIVADAS de `Agent.browserToolNames`, no escritas a mano.
    ///
    /// Es el defecto de browser-use que no queremos importar: su prompt le promete al modelo
    /// cajas numeradas sobre la captura que por defecto no existen. Una lista a mano que se
    /// queda vieja es cómo se llega a prometer lo que no hay, así que el test exige que el
    /// conjunto nombrado sea EXACTAMENTE el conjunto real: si mañana aparece un
    /// `browser_find`, la línea tiene que seguirlo sola o ponerse roja.
    func test_el_inventario_de_herramientas_sale_de_browserToolNames() {
        let nota = BrowserRules.toolInventoryNote
        for name in Agent.browserToolNames {
            XCTAssertTrue(nota.contains("`\(name)`"), "la línea no nombra \(name): \(nota)")
        }
        XCTAssertTrue(nota.contains("exactly \(Agent.browserToolNames.count) browser tools"),
                      "la cuenta tiene que salir del conjunto, no de un número a mano: \(nota)")
        // Y no nombra como nuestra ninguna que no esté en el conjunto. Se extraen los trozos
        // entre acentos graves y se filtran los que parecen una herramienta nuestra.
        let entreComillas = nota.components(separatedBy: "`").enumerated()
            .filter { $0.offset % 2 == 1 }.map { $0.element }
        let nombradas = Set(entreComillas.filter { $0.hasPrefix("browser_") })
        XCTAssertEqual(nombradas, Agent.browserToolNames,
                       "el conjunto nombrado tiene que ser el conjunto real")
        // Dice lo que importa: que el documento es más grande que lo que puede llamar.
        XCTAssertTrue(nota.contains("does not exist for you"),
                      "falta que lo demás no existe para él: \(nota)")
        XCTAssertTrue(nota.contains("instead of pretending to run it"),
                      "falta qué hacer cuando le falta un comando: \(nota)")
        // Y el aviso llega al prompt vivo con la guía.
        XCTAssertTrue(Agent.browserGuideBlock().contains(nota))
    }

    /// El texto oficial NO se poda para quitar las secciones de comandos que no tenemos: se
    /// deja byte a byte y se dice la verdad delante. Si se podara, la copia dejaría de ser
    /// diffeable contra la salida del CLI y la siguiente actualización sería a ciegas.
    func test_el_texto_oficial_conserva_los_comandos_que_no_tenemos() {
        for comando in ["find role button click", "wait --text", "eval --stdin",
                        "screenshot --annotate", "agent-browser tab", "agent-browser doctor"] {
            XCTAssertTrue(BrowserCoreSkill.text.contains(comando),
                          "el texto oficial se ha podado: falta \(comando)")
        }
    }

    // MARK: - Resolución 13: la guía no se inyecta si no cabe

    /// Con una ventana pequeña el bloque NO se inyecta.
    ///
    /// No se recorta: se deja de inyectar. `LlamaContext` no falla cuando el prompt no cabe —
    /// desliza la ventana y se come el medio en silencio, y lo que se cae por ese agujero
    /// puede ser el prompt del sistema, que es donde viven la prohibición de teclear
    /// contraseñas y el candado de cierre. Media guía que además desaloja esa prohibición es
    /// peor que no tener guía.
    func test_la_guia_no_se_inyecta_si_no_cabe_en_la_ventana() async throws {
        // 4096 es la ventana por defecto del camino on-device (`GenerationSettings`).
        let prompt = try await lastLivePrompt(rounds: [["browser_open"]], contextTokenBudget: 4096)
        XCTAssertEqual(veces(BrowserCoreSkill.text, en: prompt), 0,
                       "con 4096 tokens de ventana el bloque no cabe y no se inyecta")
        XCTAssertEqual(veces(Agent.browserGuidePreamble, en: prompt), 0)
        // La nota de resultado sí sigue llegando: lo que se cae es la guía, no el bucle.
        XCTAssertTrue(prompt.contains("You MAY keep calling browser tools"),
                      "la nota de la herramienta no se toca")
    }

    /// Con una ventana holgada se inyecta, una vez.
    func test_la_guia_se_inyecta_una_vez_con_una_ventana_holgada() async throws {
        let prompt = try await lastLivePrompt(rounds: [["browser_open"]], contextTokenBudget: 32768)
        XCTAssertEqual(veces(BrowserCoreSkill.text, en: prompt), 1,
                       "con 32768 tokens de ventana cabe de sobra")
    }

    /// El cálculo, directamente, para que los dos lados de la decisión queden fijados sin
    /// pasar por el bucle.
    func test_el_calculo_de_si_cabe() {
        // Un runtime que no declara ventana (los de servidor) siempre cabe.
        XCTAssertTrue(Agent.browserGuideFits(systemPrompt: Agent.systemPromptText, livePrompt: "x", budgetTokens: nil))
        XCTAssertFalse(Agent.browserGuideFits(systemPrompt: Agent.systemPromptText, livePrompt: "x", budgetTokens: 4096))
        XCTAssertTrue(Agent.browserGuideFits(systemPrompt: Agent.systemPromptText, livePrompt: "x", budgetTokens: 32768))
        // El margen de respuesta sale de `LlamaContext` (`nCtx - 512`), no de un número a ojo.
        XCTAssertEqual(Agent.generationHeadroomTokens, 512)
        // La estimación SOBREestima los tokens a propósito: redondea al lado barato.
        XCTAssertLessThanOrEqual(Agent.estimateBytesPerToken, 4)
        XCTAssertEqual(Agent.estimatedTokens(String(repeating: "a", count: 300)), 100)
    }

    /// Las dos ventanas reales del camino on-device, medidas, para que el umbral tenga
    /// procedencia y no sea un número a ojo.
    ///
    /// Medido el 2026-11-08: prompt del sistema 17471 B (5824 tokens estimados), bloque de la
    /// guía 18002 B (6001 tokens estimados). Presupuesto de prompt con ventana de 4096 =
    /// 4096 - 512 = 3584 tokens; con 8192 = 7680.
    ///
    /// Sale un hallazgo de aquí que NO es de esta tarea: con la ventana de 4096 el prompt del
    /// sistema SOLO ya se pasa del presupuesto (5824 > 3584), sin guía ninguna. Esto no lo
    /// introduce la guía y no se arregla aquí, pero queda afirmado para que se vea.
    func test_las_ventanas_reales_del_camino_on_device() {
        let presupuesto4096 = max(512, 4096 - Agent.generationHeadroomTokens)
        XCTAssertGreaterThan(Agent.estimatedTokens(Agent.systemPromptText), presupuesto4096,
                             "con 4096 el prompt del sistema solo ya no cabe; si esto cambia, revisa el informe")
        // Las dos ventanas con las que se carga el camino on-device: 4096 (por omisión de
        // `GenerationSettings`) y 8192 (la que usa `LlamaCppRuntime.ensureLoaded`).
        XCTAssertFalse(Agent.browserGuideFits(systemPrompt: Agent.systemPromptText, livePrompt: "", budgetTokens: 4096))
        XCTAssertFalse(Agent.browserGuideFits(systemPrompt: Agent.systemPromptText, livePrompt: "", budgetTokens: 8192))
        // Y una holgada, de las que declara un modelo de servidor si algún día las declarase.
        XCTAssertTrue(Agent.browserGuideFits(systemPrompt: Agent.systemPromptText, livePrompt: "", budgetTokens: 32768))
    }

    /// EL CAMINO ON-DEVICE TIENE QUE DECLARAR SU VENTANA.
    ///
    /// Es el único sitio donde la guarda de contexto hace falta, así que si `LlamaCppRuntime`
    /// devolviera `nil` la guarda no protegería nada: `nil` se interpreta como «cabe». Este
    /// test existe porque una mutación que ponía ese `nil` SOBREVIVIÓ a la primera tanda — no
    /// había nada que la detectara.
    ///
    /// Se comprueba sin cargar modelo (en los tests no hay `.gguf`): el runtime declara la
    /// ventana con la que `ensureLoaded` lo cargaría. Que tras un `load` real declare la
    /// ventana de ese `load` no es testeable aquí y queda dicho en el comentario del runtime.
    func test_el_camino_on_device_declara_su_ventana() {
        let rt = LlamaCppRuntime()
        XCTAssertNotNil(rt.contextTokenBudget,
                        "el camino on-device TIENE que declarar ventana; con `nil` la guarda no protege nada")
        XCTAssertEqual(rt.contextTokenBudget, LlamaCppRuntime.fallbackContextTokens)
        // Procedencia del número: la ventana con la que `ensureLoaded` carga el modelo.
        XCTAssertEqual(LlamaCppRuntime.fallbackContextTokens, 8192)
        // Y con esa ventana la guía NO cabe, o sea que la guarda hace algo real ahí.
        XCTAssertFalse(Agent.browserGuideFits(systemPrompt: Agent.systemPromptText,
                                              livePrompt: "",
                                              budgetTokens: rt.contextTokenBudget),
                       "con la ventana del camino on-device el bloque no cabe")
    }

    /// EL CAMINO QUE CORRE HOY. `RuntimeFactory` devuelve `ServerRuntime` para cualquier
    /// proveedor que no sea `.onDevice`, y `ServerRuntime` no declara ventana (se queda con el
    /// `nil` por omisión del protocolo, porque la ventana la fija el modelo remoto). La guarda
    /// de contexto NO puede bloquear la guía ahí: sería arreglar un problema teórico y romper
    /// el único camino que funciona.
    func test_en_el_camino_de_servidor_la_guia_sigue_llegando() async throws {
        // Igual que `ServerRuntime`: conforma el protocolo sin declarar ventana.
        let prompt = try await lastLivePrompt(rounds: [["browser_open"]], contextTokenBudget: nil)
        XCTAssertEqual(veces(BrowserCoreSkill.text, en: prompt), 1,
                       "sin ventana declarada la guía TIENE que llegar")
        XCTAssertEqual(veces(BrowserRules.toolInventoryNote, en: prompt), 1)
        XCTAssertEqual(veces(Agent.browserGuidePreamble, en: prompt), 1)
        // Y el cálculo, por si alguien cambia la guarda: `nil` es «cabe», no «no sé, mejor no».
        XCTAssertTrue(Agent.browserGuideFits(systemPrompt: Agent.systemPromptText,
                                             livePrompt: String(repeating: "x", count: 500_000),
                                             budgetTokens: nil),
                      "`nil` significa que no hay ventana declarada: cabe siempre")
    }

    /// Un runtime que no declara ventana es el caso por omisión del protocolo, y por eso los
    /// demás tests de este fichero (y los dobles de test de todo el proyecto) siguen viendo la
    /// guía sin tener que saber nada de contextos.
    func test_por_omision_un_runtime_no_declara_ventana() {
        XCTAssertNil(ScriptedRoundsRuntime(rounds: []).contextTokenBudget)
    }
}
