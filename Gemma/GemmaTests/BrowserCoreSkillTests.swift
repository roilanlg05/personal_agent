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

        init(rounds: [[String]]) { self.rounds = rounds }

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
    private func lastLivePrompt(rounds: [[String]]) async throws -> String {
        let runtime = ScriptedRoundsRuntime(rounds: rounds)
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
        let nota = Agent.toolResultNote(toolName: "browser_open", args: "{}", result: "error: no tool named browser_open")
        let indiceNota = try XCTUnwrap(prompt.range(of: nota)?.lowerBound)
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
        let iFrase = try XCTUnwrap(bloque.range(of: Agent.browserGuidePreamble)?.lowerBound)
        let iGuia = try XCTUnwrap(bloque.range(of: BrowserCoreSkill.text)?.lowerBound)
        XCTAssertLessThan(iReglas, iFrase, "nuestras reglas van primero")
        XCTAssertLessThan(iFrase, iGuia, "la frase de precedencia va entre las reglas y la guía")

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
}
