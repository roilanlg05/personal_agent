import XCTest
@testable import Gemma

final class ServerRuntimeHistoryTests: XCTestCase {
    final class BodyCapture: URLProtocol {
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            BodyCapture.lastBody = request.httpBody ?? request.httpBodyStream.map { s in
                s.open(); defer { s.close() }
                var data = Data(); let n = 65536; var buf = [UInt8](repeating: 0, count: n)
                while s.hasBytesAvailable { let read = s.read(&buf, maxLength: n); if read <= 0 { break }; data.append(buf, count: read) }
                return data
            }
            let json = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: json)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [BodyCapture.self]
        return URLSession(configuration: cfg)
    }

    func test_history_is_sent_between_system_and_user() async throws {
        BodyCapture.lastBody = nil
        let rt = ServerRuntime(session: makeSession())
        var opts = GenerationOptions()
        opts.systemPrompt = "SYS"
        opts.history = [ChatMessage(role: .user, content: "turn1 user"),
                        ChatMessage(role: .assistant, content: "turn1 reply")]
        let stream = await rt.generate(prompt: "turn2 user", tools: [], options: opts)
        for try await _ in stream {}

        let body = try XCTUnwrap(BodyCapture.lastBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let msgs = try XCTUnwrap(obj["messages"] as? [[String: String]])
        XCTAssertEqual(msgs.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(msgs.map { $0["content"] }, ["SYS", "turn1 user", "turn1 reply", "turn2 user"])
    }
}
