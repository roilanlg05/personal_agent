import XCTest
@testable import Gemma

/// La llamada a herramienta que llega como TEXTO ROTO (chat del 2026-11-11, proveedor Claude
/// Sonnet 5.5, assistant seq 20). El modelo quiso llamar `browser_wait`, la llamada salió como
/// sintaxis de invocación escrita en el texto, `GemmaToolCallParser.strip` se comió las
/// etiquetas y dejó ` name="browser_wait">`, y el bucle tomó eso por respuesta final: el
/// turno se quedó parado. Ver `ServerRuntimeStreamingTests.test_la_llamada_escrita_como_invoke_reproduce_el_texto_exacto_guardado`
/// para la medida de cómo se produce ese texto exacto.
@MainActor
final class LlamadaRotaTests: XCTestCase {
    /// El texto guardado, byte a byte.
    static let sintoma = "La página sigue en la contraseña y no muestra ningún error, quizá solo está cargando. Espero un par de segundos y vuelvo a mirar.\n\n\n name=\"browser_wait\">"
    static let herramientas: Set<String> = ["browser_wait", "browser_snapshot", "browser_click"]

    // MARK: - Detector

    func test_el_texto_exacto_del_sintoma_es_una_llamada_rota() {
        XCTAssertTrue(BrokenToolCallDetector.esLlamadaRota(Self.sintoma, herramientas: Self.herramientas))
    }

    func test_la_sintaxis_de_invocacion_sin_procesar_es_una_llamada_rota() {
        for roto in ["Voy.\n<invoke name=\"browser_wait\">",
                     "Voy.\n<function_calls>",
                     "Voy. </invoke>",
                     "Voy. antml:invoke",
                     "Voy. <tool_call>{\"name\":\"browser_wait\"",
                     "Voy. <|tool_call>call:browser_wait{",
                     "Voy. <parameter name=\"milliseconds\">2000",
                     "Voy. <function name=\"browser_wait\">"] {
            XCTAssertTrue(BrokenToolCallDetector.esLlamadaRota(roto, herramientas: Self.herramientas), roto)
        }
    }

    func test_la_prosa_normal_no_es_una_llamada_rota() {
        for bueno in ["Listo, ya entré en tu cuenta.",
                      "",
                      "El campo se llama name=\"email\"> en el HTML, no es una herramienta.",
                      "Tu nombre (name) quedó guardado.",
                      "Hoy hará sol, con 5 < 8 nubes.",
                      "Usé browser_wait para esperar a que cargara."] {
            XCTAssertFalse(BrokenToolCallDetector.esLlamadaRota(bueno, herramientas: Self.herramientas), bueno)
        }
    }

    /// El resto ` name="x">` solo cuenta si `x` es una herramienta de verdad: así una
    /// respuesta que hable de HTML no se confunde con una llamada.
    func test_el_resto_de_atributo_solo_cuenta_con_un_nombre_de_herramienta() {
        XCTAssertFalse(BrokenToolCallDetector.esLlamadaRota("Mira.\n\n name=\"email\">", herramientas: Self.herramientas))
        XCTAssertTrue(BrokenToolCallDetector.esLlamadaRota("Mira.\n\n name='browser_click' >", herramientas: Self.herramientas))
    }

    // MARK: - Bucle del agente

    final class FakeWait: AgentTool {
        static let name = "browser_wait"
        static let description = "fake"
        nonisolated(unsafe) static var calls = 0
        func run(argsJSON: String) async -> String {
            Self.calls += 1
            return #"{"status":"success","message":"Espera completada."}"#
        }
    }

    /// Cada ronda: texto (tokens + `.completed`) y, opcionalmente, una llamada real.
    final class Guion: ToolCallingRuntime {
        let rondas: [(texto: String, llamada: String?)]
        var prompts: [String] = []
        private var i = 0
        init(_ rondas: [(texto: String, llamada: String?)]) { self.rondas = rondas }
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            prompts.append(prompt)
            let r = i < rondas.count ? rondas[i] : (texto: "listo", llamada: nil)
            i += 1
            return AsyncThrowingStream { c in
                if !r.texto.isEmpty { c.yield(.token(r.texto)) }
                if let n = r.llamada { c.yield(.toolCallStarted(name: n, args: "{\"milliseconds\":2000}")) }
                c.yield(.completed(GenerationResult(text: r.texto,
                                                    metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    private func ejecuta(_ rt: Guion) async throws -> (completados: [String], fallados: [String]) {
        FakeWait.calls = 0
        let registro = ToolRegistry()
        registro.register(FakeWait())
        var completados: [String] = [], fallados: [String] = []
        for try await e in Agent(runtime: rt, registry: registro).run(prompt: "x", options: GenerationOptions()) {
            if case .completed(let r) = e { completados.append(r.text) }
            if case .failed(let m) = e { fallados.append(m) }
        }
        return (completados, fallados)
    }

    /// El caso del chat: la llamada rota NO cierra el turno. El bucle reintenta una vez con una
    /// nota, el modelo emite la llamada de verdad, se ejecuta y el turno sigue.
    func test_una_llamada_rota_se_reintenta_y_el_turno_sigue() async throws {
        let rt = Guion([(Self.sintoma, nil), ("", "browser_wait"), ("Ya cargó: estás dentro.", nil)])
        let visto = try await ejecuta(rt)

        XCTAssertEqual(rt.prompts.count, 3, "reintento + ronda tras la herramienta")
        XCTAssertTrue(rt.prompts[1].contains(Agent.notaDeLlamadaRota), "el reintento lleva la nota: \(rt.prompts[1])")
        XCTAssertFalse(rt.prompts[1].contains("name=\"browser_wait\">"), "el texto roto no vuelve al prompt")
        XCTAssertEqual(FakeWait.calls, 1)
        XCTAssertEqual(visto.completados, ["Ya cargó: estás dentro."], "el texto roto no se entrega ni se guarda")
        XCTAssertEqual(visto.fallados, [])
    }

    /// Dos veces rota: el turno acaba con un aviso honesto en español, nunca en silencio, y el
    /// texto roto tampoco se guarda.
    func test_dos_llamadas_rotas_acaban_con_un_aviso_honesto() async throws {
        let rt = Guion([(Self.sintoma, nil), ("Vuelvo a mirar.\n\n name=\"browser_wait\">", nil), ("no debería llegar", nil)])
        let visto = try await ejecuta(rt)

        XCTAssertEqual(rt.prompts.count, 2, "un solo reintento")
        XCTAssertEqual(visto.completados, [Agent.avisoDeLlamadaRota])
        XCTAssertTrue(Agent.avisoDeLlamadaRota.contains("dos veces"))
        XCTAssertEqual(visto.fallados, [])
    }

    /// Máximo un reintento POR TURNO, no por ronda.
    func test_el_reintento_es_uno_por_turno() async throws {
        let rt = Guion([(Self.sintoma, nil), ("", "browser_wait"), (Self.sintoma, nil), ("no debería llegar", nil)])
        let visto = try await ejecuta(rt)

        XCTAssertEqual(rt.prompts.count, 3)
        XCTAssertEqual(visto.completados, [Agent.avisoDeLlamadaRota])
    }

    /// Una respuesta normal sigue cerrando el turno a la primera.
    func test_una_respuesta_normal_no_se_reintenta() async throws {
        let rt = Guion([("Hola, ¿en qué te ayudo?", nil)])
        let visto = try await ejecuta(rt)
        XCTAssertEqual(rt.prompts.count, 1)
        XCTAssertEqual(visto.completados, ["Hola, ¿en qué te ayudo?"])
    }
}
