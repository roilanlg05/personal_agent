import XCTest
@testable import Gemma

final class ServerRuntimeStreamingTests: XCTestCase {
    /// Returns a fixed Server-Sent-Events body (OpenAI streaming shape).
    final class SSEStub: URLProtocol {
        nonisolated(unsafe) static var body: String = ""
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: SSEStub.body.data(using: .utf8)!)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SSEStub.self]
        return URLSession(configuration: cfg)
    }

    func test_streaming_yields_incremental_tokens_then_completed() async throws {
        SSEStub.body = """
        data: {"choices":[{"delta":{"content":"Hola"}}]}

        data: {"choices":[{"delta":{"content":" mundo"}}]}

        data: [DONE]

        """
        let rt = ServerRuntime(session: makeSession())
        var tokens: [String] = []
        var completedText: String?
        for try await ev in await rt.generate(prompt: "hi", tools: [], options: GenerationOptions()) {
            switch ev {
            case .token(let t): tokens.append(t)
            case .completed(let r): completedText = r.text
            default: break
            }
        }
        XCTAssertEqual(tokens, ["Hola", " mundo"], "each SSE content delta should arrive as its own token")
        XCTAssertEqual(completedText, "Hola mundo", "final text is the concatenation of the deltas")
    }

    final class StallStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            // never deliver data / never finish → exercises the inactivity timeout
        }
        override func stopLoading() {}
    }

    func test_generation_times_out_when_server_stalls() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StallStub.self]
        let rt = ServerRuntime(session: URLSession(configuration: cfg), generationTimeout: .seconds(1))
        var threw = false
        do { for try await _ in await rt.generate(prompt: "hi", tools: [], options: GenerationOptions()) {} }
        catch { threw = true }
        XCTAssertTrue(threw, "a stalled server must surface as a thrown error, not hang forever")
    }

    func test_streaming_accumulates_tool_call_deltas() async throws {
        SSEStub.body = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"get_current_time","arguments":""}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}

        data: [DONE]

        """
        let rt = ServerRuntime(session: makeSession())
        var calls: [(String, String)] = []
        for try await ev in await rt.generate(prompt: "what time", tools: [], options: GenerationOptions()) {
            if case .toolCallStarted(let n, let a) = ev { calls.append((n, a)) }
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "get_current_time")
        XCTAssertEqual(calls.first?.1, "{}", "fragmented tool-call arguments are accumulated")
    }

    // MARK: sintaxis de herramienta escrita como texto (chat de YouTube, 2026-11-08)

    /// Cuerpo SSE de estilo OpenAI con un `content` por cada trozo.
    private func sse(_ pieces: [String]) -> String {
        pieces.map { p -> String in
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": p]]]])
            return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
        }.joined() + "data: [DONE]\n\n"
    }

    private func run(_ pieces: [String]) async throws -> (tokens: [String], calls: [(String, String)], completed: String?) {
        SSEStub.body = sse(pieces)
        let rt = ServerRuntime(session: makeSession())
        var tokens: [String] = [], calls: [(String, String)] = []
        var completed: String?
        for try await ev in await rt.generate(prompt: "hi", tools: [], options: GenerationOptions()) {
            switch ev {
            case .token(let t): tokens.append(t)
            case .toolCallStarted(let n, let a): calls.append((n, a))
            case .completed(let r): completed = r.text
            default: break
            }
        }
        return (tokens, calls, completed)
    }

    /// El caso exacto del chat: prosa y luego la llamada. Antes, todo token posterior a la
    /// decisión inicial (tomada con la prosa) salía a pantalla, sintaxis incluida.
    func test_la_sintaxis_de_herramienta_tras_prosa_no_llega_a_los_tokens_y_si_se_ejecuta() async throws {
        let r = try await run(["Entendido, dame un momento: ", "voy a abrir el más reciente.", "\n\n",
                               "<func", "tion name=\"browser_click\">", "\n<parameter name=\"selector\">@e816</parameter>\n</function>"])
        let shown = r.tokens.joined()
        XCTAssertEqual(shown, "Entendido, dame un momento: voy a abrir el más reciente.\n\n")
        XCTAssertFalse(shown.contains("browser_click") || shown.contains("@e816") || shown.contains("<"), "sintaxis visible: \(shown)")
        XCTAssertEqual(r.calls.count, 1, "además de ocultarla, el parser la reconoce")
        XCTAssertEqual(r.calls.first?.0, "browser_click")
        XCTAssertEqual(r.calls.first?.1, #"{"selector":"@e816"}"#)
        XCTAssertEqual(r.completed, "Entendido, dame un momento: voy a abrir el más reciente.")
    }

    func test_una_llamada_sin_cerrar_tras_prosa_no_se_muestra_ni_se_ejecuta() async throws {
        let r = try await run(["Voy a abrirlo. ", "<function name=\"browser_click\">", "<parameter name=\"selector\">@e8"])
        XCTAssertEqual(r.tokens.joined(), "Voy a abrirlo. ")
        XCTAssertTrue(r.calls.isEmpty)
        XCTAssertEqual(r.completed, "Voy a abrirlo.")
    }

    func test_la_prosa_normal_sigue_llegando_token_a_token() async throws {
        let r = try await run(["Hoy ", "hará ", "sol, ", "con 5 ", "<", " 8 nubes."])
        XCTAssertEqual(r.tokens.joined(), "Hoy hará sol, con 5 < 8 nubes.")
        XCTAssertEqual(r.tokens.count, 5, "solo el \"<\" dudoso se retiene un token; el resto sale al llegar: \(r.tokens)")
        XCTAssertEqual(r.tokens.first, "Hoy ")
    }

    func test_un_mensaje_que_empieza_por_la_llamada_sigue_oculto() async throws {
        let r = try await run([#"call:web_search{"query":"gatos"}"#])
        XCTAssertTrue(r.tokens.isEmpty)
        XCTAssertEqual(r.calls.first?.0, "web_search")
    }

    /// Un mensaje que termina en `<` no debe perder ese fragmento en la vista en vivo.
    func test_un_mensaje_que_termina_en_menor_que_lo_emite_al_cerrar_el_stream() async throws {
        let r = try await run(["Resultado: x ", "<"])
        XCTAssertEqual(r.tokens.joined(), "Resultado: x <")
    }
    // MARK: llamada de Claude escrita como texto (chat del 2026-11-11, assistant seq 20)

    /// Cuerpo SSE con la forma de la API de Anthropic: un `text_delta` por trozo.
    private func claudeSSE(_ pieces: [String]) -> String {
        var out = "data: {\"type\":\"message_start\"}\n\n"
        out += "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
        for p in pieces {
            let ev: [String: Any] = ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": p]]
            let data = try! JSONSerialization.data(withJSONObject: ev)
            out += "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
        }
        return out + "data: {\"type\":\"message_stop\"}\n\n"
    }

    private func runClaude(_ pieces: [String]) async throws -> (tokens: [String], calls: [(String, String)], completed: String?) {
        SSEStub.body = claudeSSE(pieces)
        let rt = ServerRuntime(provider: ModelProvider(kind: .claude, apiKey: "k"), session: makeSession())
        var tokens: [String] = [], calls: [(String, String)] = []
        var completed: String?
        for try await ev in await rt.generate(prompt: "hi", tools: [], options: GenerationOptions()) {
            switch ev {
            case .token(let t): tokens.append(t)
            case .toolCallStarted(let n, let a): calls.append((n, a))
            case .completed(let r): completed = r.text
            default: break
            }
        }
        return (tokens, calls, completed)
    }

    /// LA MEDIDA DEL SINTOMA. El mensaje guardado fue, byte a byte, la prosa + tres saltos +
    /// ` name="browser_wait">`. Este es el texto de modelo que lo produce: la llamada escrita
    /// como TEXTO con la sintaxis de invocacion (`<function_calls>` / `<invoke name=..>` /
    /// `<parameter name=..>`). `GemmaToolCallParser.strip` no la reconoce como llamada: su
    /// barrido generico de etiquetas (`</?[a-zA-Z0-9_\-|:]+>?`) se come `<function_calls>`,
    /// `<invoke` y `</invoke>` pero deja el atributo ` name="browser_wait">`, y los saltos de
    /// linea que separaban las etiquetas se quedan: de ahi los TRES `\n`. No sale ninguna
    /// llamada, asi que el bucle lo toma por respuesta final.
    func test_la_llamada_escrita_como_invoke_reproduce_el_texto_exacto_guardado() async throws {
        let prosa = "La página sigue en la contraseña y no muestra ningún error, quizá solo está cargando. Espero un par de segundos y vuelvo a mirar."
        let r = try await runClaude([prosa, "\n\n<function_calls>\n<invoke name=\"browser_wait\">\n<parameter name=\"milliseconds\">2000</parameter>\n</invoke>\n</function_calls>"])
        XCTAssertEqual(r.completed, prosa + "\n\n\n name=\"browser_wait\">", "este es el texto exacto de seq 20")
        XCTAssertTrue(r.calls.isEmpty, "no llega como llamada: por eso el turno se para")
    }

    /// La sintaxis de invocacion tampoco debe verse EN VIVO: la compuerta no conocia
    /// `<function_calls>` (el `_` tras `<function` lo hacia pasar por prosa) ni `<invoke`.
    func test_la_sintaxis_invoke_no_llega_a_los_tokens() async throws {
        let r = try await runClaude(["Vuelvo a mirar.", "\n\n<function_", "calls>\n<inv", "oke name=\"browser_wait\">\n</invoke>\n</function_calls>"])
        let shown = r.tokens.joined()
        XCTAssertEqual(shown, "Vuelvo a mirar.\n\n")
        XCTAssertFalse(shown.contains("invoke") || shown.contains("function_calls") || shown.contains("browser_wait"), "sintaxis visible: \(shown)")
    }

    func test_un_invoke_suelto_sin_function_calls_tampoco_llega_a_los_tokens() async throws {
        let r = try await runClaude(["Vuelvo a mirar. ", "<invoke name=\"browser_wait\">"])
        XCTAssertEqual(r.tokens.joined(), "Vuelvo a mirar. ")
    }
}
