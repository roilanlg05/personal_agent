import XCTest
@testable import Gemma

final class ServerRuntimeMockProtocol: URLProtocol {
    static var responseBody = ""
    static var statusCode = 200
    /// Captures the outgoing request body so tests can assert what we posted. URLSession often
    /// moves the body into `httpBodyStream`, so fall back to reading the stream if `httpBody` is nil.
    static var capturedBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        Self.capturedBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let data = Self.responseBody.data(using: .utf8)!
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ServerRuntimeTests: XCTestCase {
    private func makeRuntime() -> ServerRuntime {
        ServerRuntimeMockProtocol.statusCode = 200
        ServerRuntimeMockProtocol.capturedBody = nil
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

    /// We disable the model's hidden chain-of-thought via `chat_template_kwargs.enable_thinking == false`.
    func testPostsEnableThinkingFalse() async throws {
        ServerRuntimeMockProtocol.responseBody = #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
        let rt = makeRuntime()
        for try await _ in await rt.generate(prompt: "hi", options: GenerationOptions()) {}
        let body = try XCTUnwrap(ServerRuntimeMockProtocol.capturedBody, "request body should have been captured")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let kwargs = try XCTUnwrap(json["chat_template_kwargs"] as? [String: Any], "body should contain chat_template_kwargs")
        let enableThinking = try XCTUnwrap(kwargs["enable_thinking"] as? Bool)
        XCTAssertFalse(enableThinking, "enable_thinking should be false")
    }

    /// A non-2xx HTTP response must surface as a thrown error, not a silently-empty completion.
    func testNon2xxResponseThrows() async throws {
        ServerRuntimeMockProtocol.responseBody = #"{"error":{"message":"bad request"}}"#
        let rt = makeRuntime()
        ServerRuntimeMockProtocol.statusCode = 400
        do {
            for try await _ in await rt.generate(prompt: "hi", options: GenerationOptions()) {}
            XCTFail("expected the stream to throw on a non-2xx response")
        } catch let RuntimeError.generationFailed(msg) {
            XCTAssertTrue(msg.contains("400"), "error should mention the status code: \(msg)")
            XCTAssertTrue(msg.contains("bad request"), "error should include the server body: \(msg)")
        }
    }
}
