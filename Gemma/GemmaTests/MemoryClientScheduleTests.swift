import XCTest
@testable import Gemma

@MainActor
final class MemoryClientScheduleTests: XCTestCase {
    // Minimal stub URLProtocol: maps path → (status, jsonBody).
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let path = (request.url?.path ?? "") + (request.url?.query.map { "?\($0)" } ?? "")
            let key = Self.routes.keys.first { path.hasPrefix($0) } ?? path
            let (status, body) = Self.routes[key] ?? (404, "{}")
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> MemoryClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return MemoryClient(baseURL: URL(string: "http://test.local:8081")!, bearerToken: "t",
                            session: URLSession(configuration: cfg))
    }

    func test_createEvent_returnsConflicts_whenNotCreated() async throws {
        StubURLProtocol.routes = ["/v1/schedule/create":
            (200, #"{"created":false,"conflicts":[{"id":"x","title":"Trip","start":1000,"end":2000,"allDay":true,"status":"scheduled"}]}"#)]
        let c = makeClient()
        let r = try await c.createEvent(title: "Meeting", start: 1500, end: 1600, allDay: false, location: nil, force: false)
        XCTAssertFalse(r.created)
        XCTAssertEqual(r.conflicts.first?.title, "Trip")
    }

    func test_scheduleWindow_decodesEvents() async throws {
        StubURLProtocol.routes = ["/v1/schedule/window":
            (200, #"{"events":[{"id":"x","title":"Trip","start":1000,"end":2000,"allDay":true,"location":"Cuba","status":"scheduled"}]}"#)]
        let c = makeClient()
        let evs = try await c.scheduleWindow(from: 0, to: 5000, includeCancelled: false)
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].location, "Cuba")
    }

    func test_cancelEvents_returnsCount() async throws {
        StubURLProtocol.routes = ["/v1/schedule/cancel": (200, #"{"cancelled":2}"#)]
        let c = makeClient()
        let n = try await c.cancelEvents(ids: nil, from: 0, to: 5000)
        XCTAssertEqual(n, 2)
    }

    func test_checkSchedule_returnsConflicts() async throws {
        StubURLProtocol.routes = ["/v1/schedule/check":
            (200, #"{"conflicts":[{"id":"y","title":"Gym","start":1000,"end":2000,"allDay":false,"status":"scheduled"}]}"#)]
        let c = makeClient()
        let conflicts = try await c.checkSchedule(start: 1500, end: 1600)
        XCTAssertEqual(conflicts.first?.title, "Gym")
    }
}
