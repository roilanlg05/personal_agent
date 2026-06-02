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
}
