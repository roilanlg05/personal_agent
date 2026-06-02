import XCTest
@testable import Gemma

final class HealthWarmMockProtocol: URLProtocol {
    static var capturedBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        Self.capturedBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); let cap = 8192
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap); defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: cap); if n <= 0 { break }; data.append(buf, count: n)
            }
            return data
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HTTPServerHealthTests: XCTestCase {
    private func makeHealth() -> HTTPServerHealth {
        HealthWarmMockProtocol.capturedBody = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HealthWarmMockProtocol.self]
        return HTTPServerHealth(session: URLSession(configuration: cfg))
    }

    private func cfg() -> ServerConfig {
        ServerConfig(pythonBinURL: URL(fileURLWithPath: "/x/python3.12"),
                     launcherScriptURL: URL(fileURLWithPath: "/x/serve.py"),
                     modelId: "some/model", host: "127.0.0.1", port: 8080,
                     wiredLimitBytes: 0)
    }

    func test_warmup_is_representative_systemPrompt_and_multiToken() async throws {
        let health = makeHealth()
        try await health.warm(cfg())
        let body = try XCTUnwrap(HealthWarmMockProtocol.capturedBody, "warm-up should POST a body")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "some/model")
        let maxTokens = try XCTUnwrap(json["max_tokens"] as? Int)
        XCTAssertGreaterThanOrEqual(maxTokens, 8,
            "warm-up must generate enough tokens to JIT the multi-token + MTP decode kernels")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["role"] as? String) == "system" },
            "warm-up must include a system message so the system-prefix prefill kernels compile")
    }
}
