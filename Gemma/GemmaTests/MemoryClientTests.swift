import XCTest
@testable import Gemma

@MainActor
final class MemoryClientTests: XCTestCase {
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var stub: (URLRequest) -> (HTTPURLResponse, Data) = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (res, data) = Self.stub(request)
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }
    private func makeClient() -> MemoryClient {
        MemoryClient(baseURL: URL(string: "http://localhost:8081")!, bearerToken: "test-token",
                     session: makeSession())
    }

    func test_save_sends_bearer_and_decodes_id() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(req.url?.path, "/v1/memory/save")
            let data = #"{"id":"abc"}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, data)
        }
        let result = try await makeClient().save(kind: "preference", label: "sushi", body: "x", extra: nil, sourceRef: nil)
        XCTAssertEqual(result.id, "abc")
        XCTAssertNil(result.mergedInto)
    }

    func test_recall_decodes_core_and_recall_lists() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/recall")
            let payload = #"""
            {"core":[{"kind":"identity","label":"Roilan","body":"el usuario"}],
             "recall":[{"kind":"preference","label":"sushi","body":"al user le gusta","extra":null}]}
            """#.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, payload)
        }
        let bundle = try await makeClient().recall(query: "qué comida", scope: nil, limit: nil)
        XCTAssertEqual(bundle.core.first?.label, "Roilan")
        XCTAssertEqual(bundle.recall.first?.label, "sushi")
    }

    func test_recall_with_503_returns_empty_bundle_for_graceful_degradation() async throws {
        StubProtocol.stub = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let bundle = try await makeClient().recall(query: "x", scope: nil, limit: nil)
        XCTAssertTrue(bundle.core.isEmpty)
        XCTAssertTrue(bundle.recall.isEmpty)
    }

    func test_appendTranscript_posts_expected_body() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.url?.path, "/v1/transcript/append")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "{}".data(using: .utf8)!)
        }
        try await makeClient().appendTranscript(threadId: "T", role: "user", text: "hi", turnIndex: 0)
    }
}
