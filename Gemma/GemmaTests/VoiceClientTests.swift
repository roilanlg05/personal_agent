import XCTest
@testable import Gemma

@MainActor
final class VoiceClientTests: XCTestCase {
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

    private func makeClient() -> VoiceClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return VoiceClient(baseURL: URL(string: "http://localhost:8082")!, bearerToken: "test-token",
                           session: URLSession(configuration: cfg))
    }

    func test_turn_posts_multipart_and_decodes_headers() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/v1/voice/turn")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") ?? false)
            let headers = ["Content-Type": "audio/wav",
                           "X-STT-Text": "%C2%BFQu%C3%A9%20hora%20es%3F",
                           "X-Reply-Text": "Son%20las%203."]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!,
                    Data([0x52, 0x49, 0x46, 0x46]))
        }
        let reply = try await makeClient().turn(wav: Data([1, 2, 3]), threadId: "T", timezone: "America/Havana")
        XCTAssertEqual(reply.sttText, "¿Qué hora es?")
        XCTAssertEqual(reply.replyText, "Son las 3.")
        XCTAssertEqual(reply.audio, Data([0x52, 0x49, 0x46, 0x46]))
    }

    func test_turn_400_throws_silence() async {
        StubProtocol.stub = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await makeClient().turn(wav: Data([1]), threadId: "T", timezone: "tz")
            XCTFail("expected throw")
        } catch let e as VoiceError {
            XCTAssertEqual(e, .silence)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_turn_502_throws_http() async {
        StubProtocol.stub = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 502, httpVersion: nil,
                             headerFields: ["X-Reply-Text": "boom"])!, Data())
        }
        do {
            _ = try await makeClient().turn(wav: Data([1]), threadId: "T", timezone: "tz")
            XCTFail("expected throw")
        } catch let VoiceError.http(status, reply) {
            XCTAssertEqual(status, 502)
            XCTAssertEqual(reply, "boom")
        } catch { XCTFail("wrong error: \(error)") }
    }
}
