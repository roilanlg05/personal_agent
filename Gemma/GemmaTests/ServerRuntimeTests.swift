import XCTest
@testable import Gemma

final class ServerRuntimeMockProtocol: URLProtocol {
    static var responseBody = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let data = Self.responseBody.data(using: .utf8)!
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ServerRuntimeTests: XCTestCase {
    private func makeRuntime() -> ServerRuntime {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ServerRuntimeMockProtocol.self]
        return ServerRuntime(baseURL: URL(string: "http://localhost:8080")!,
                             session: URLSession(configuration: cfg))
    }

    func testEmitsTokenAndCompleted() async throws {
        ServerRuntimeMockProtocol.responseBody = #"{"choices":[{"message":{"role":"assistant","content":"Hello there"},"finish_reason":"stop"}]}"#
        let rt = makeRuntime()
        var text = ""
        for try await e in await rt.generate(prompt: "hi", options: GenerationOptions()) {
            if case .token(let t) = e { text += t }
            if case .completed(let r) = e { text = r.text }
        }
        XCTAssertEqual(text, "Hello there")
    }

    /// `message.reasoning` (Gemma's thought channel) must NOT be surfaced as the answer.
    func testReasoningIsNotSurfaced() async throws {
        ServerRuntimeMockProtocol.responseBody = #"{"choices":[{"message":{"role":"assistant","reasoning":"secret thought","content":"visible answer"},"finish_reason":"stop"}]}"#
        let rt = makeRuntime()
        var text = ""
        for try await e in await rt.generate(prompt: "hi", options: GenerationOptions()) {
            if case .completed(let r) = e { text = r.text }
        }
        XCTAssertEqual(text, "visible answer")
        XCTAssertFalse(text.contains("secret thought"))
    }

    /// Branch A: tool_calls arrive in message.tool_calls and surface as .toolCallStarted.
    func testEmitsToolCallStarted() async throws {
        ServerRuntimeMockProtocol.responseBody = #"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","reasoning":"thinking","tool_calls":[{"function":{"name":"get_current_time","arguments":"{}"},"type":"function","id":"abc"}]}}]}"#
        let rt = makeRuntime()
        var calls: [(name: String, args: String)] = []
        for try await e in await rt.generate(prompt: "what time?", tools: [CurrentTimeTool()], options: GenerationOptions()) {
            if case .toolCallStarted(let n, let a) = e { calls.append((n, a)) }
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "get_current_time")
        XCTAssertEqual(calls.first?.args, "{}")
    }
}
