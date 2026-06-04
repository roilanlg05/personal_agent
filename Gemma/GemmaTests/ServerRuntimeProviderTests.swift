import XCTest
@testable import Gemma

final class ServerRuntimeProviderTests: XCTestCase {
    /// Captures the outgoing request (incl. body via httpBodyStream when URLProtocol strips
    /// `httpBody`) and returns a minimal 200 SSE body so the runtime's stream completes.
    final class CaptureStub: URLProtocol {
        nonisolated(unsafe) static var lastRequest: URLRequest?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            var captured = request
            captured.httpBody = request.httpBody ?? request.httpBodyStream.map { s in
                s.open(); defer { s.close() }
                var data = Data(); let n = 65536; var buf = [UInt8](repeating: 0, count: n)
                while s.hasBytesAvailable { let read = s.read(&buf, maxLength: n); if read <= 0 { break }; data.append(buf, count: read) }
                return data
            }
            CaptureStub.lastRequest = captured
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: "data: [DONE]\n\n".data(using: .utf8)!)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func captureRequest(provider: ModelProvider) async throws -> URLRequest {
        CaptureStub.lastRequest = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CaptureStub.self]
        let session = URLSession(configuration: cfg)
        let rt = ServerRuntime(provider: provider, session: session)
        for try await _ in await rt.generate(prompt: "hi", tools: [], options: GenerationOptions()) {}
        return try XCTUnwrap(CaptureStub.lastRequest)
    }

    private func errorMessage(status: Int, provider: ModelProvider) async -> String {
        ServerRuntime.errorMessage(status: status, provider: provider)
    }

    func test_cloudRequest_hasBearerAuth_andNoThinkingKwargs() async throws {
        let captured = try await captureRequest(provider: ModelProvider(kind: .gemini, apiKey: "KEY123"))
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer KEY123")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(captured.httpBody)) as! [String: Any]
        XCTAssertNil(body["chat_template_kwargs"])
        XCTAssertEqual(body["model"] as? String, "gemini-2.5-flash")
        XCTAssertEqual(captured.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    func test_localRequest_hasThinkingKwargs_andNoAuth() async throws {
        let captured = try await captureRequest(provider: ModelProvider(kind: .local))
        XCTAssertNil(captured.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(captured.httpBody)) as! [String: Any]
        XCTAssertNotNil(body["chat_template_kwargs"])
    }

    func test_localRequest_url_appendsChatCompletions() async throws {
        let captured = try await captureRequest(provider: ModelProvider(kind: .local))
        XCTAssertEqual(captured.url?.absoluteString, "http://localhost:8080/v1/chat/completions")
    }

    func test_http401_mapsToInvalidKeyMessage() async {
        let msg = await errorMessage(status: 401, provider: ModelProvider(kind: .groq, apiKey: "bad"))
        XCTAssertTrue(msg.contains("API key"), msg)
    }
}
