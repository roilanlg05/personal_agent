import Foundation
@testable import Gemma

/// Builds a `MemoryClient` whose URLSession intercepts every request via a closure stub.
/// Each test supplies `(URLRequest) -> (status, body)` and the helper wires up the
/// custom `URLProtocol`. The bearer token is fixed to `test-token`.
@MainActor
func makeStubMemoryClient(_ stub: @escaping (URLRequest) -> (Int, Data)) -> MemoryClient {
    final class P: URLProtocol {
        nonisolated(unsafe) static var stub: (URLRequest) -> (Int, Data) = { _ in (200, Data()) }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (code, data) = Self.stub(request)
            let res = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    P.stub = stub
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [P.self]
    return MemoryClient(baseURL: URL(string: "http://localhost:8081")!, bearerToken: "test-token",
                        session: URLSession(configuration: cfg))
}
