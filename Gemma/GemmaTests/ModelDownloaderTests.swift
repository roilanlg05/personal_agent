import XCTest
@testable import Gemma

final class ModelDownloaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        MockURLProtocol.reset()
    }

    func test_download_writesFileAndYieldsCompletedEvent() async throws {
        let payload = Data(repeating: 0xAB, count: 1024)
        MockURLProtocol.responseFor = { _ in
            MockURLProtocol.Response(
                statusCode: 200,
                headers: ["Content-Length": "1024"],
                body: payload
            )
        }

        let downloader = ModelDownloader(
            session: makeMockedSession(),
            destinationDir: tempDir
        )
        let url = URL(string: "https://mock/model.bin")!

        var lastProgress: (Int64, Int64) = (0, 0)
        var completedURL: URL?
        for try await event in downloader.download(from: url, filename: "model.bin") {
            switch event {
            case .progress(let downloaded, let total):
                lastProgress = (downloaded, total)
            case .completed(let final):
                completedURL = final
            }
        }
        XCTAssertEqual(lastProgress.0, 1024)
        XCTAssertEqual(lastProgress.1, 1024)
        XCTAssertNotNil(completedURL)
        XCTAssertEqual(try Data(contentsOf: completedURL!), payload)
    }

    func test_download_httpErrorThrowsViaStream() async {
        MockURLProtocol.responseFor = { _ in
            MockURLProtocol.Response(statusCode: 404, headers: [:], body: Data())
        }
        let downloader = ModelDownloader(session: makeMockedSession(), destinationDir: tempDir)
        do {
            for try await _ in downloader.download(from: URL(string: "https://mock/missing")!, filename: "x.bin") {}
            XCTFail("Expected DownloadError.httpError")
        } catch DownloadError.httpError(let code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_download_resumesFromPartialFile() async throws {
        let full = Data(repeating: 0x42, count: 2048)
        let partial = full.prefix(1024)
        // Place existing partial file
        let partialURL = tempDir.appendingPathComponent("resume.bin.partial")
        try partial.write(to: partialURL)

        MockURLProtocol.responseFor = { request in
            // Server must see Range header.
            let range = request.value(forHTTPHeaderField: "Range")
            XCTAssertEqual(range, "bytes=1024-")
            let remainder = full.suffix(1024)
            return MockURLProtocol.Response(
                statusCode: 206,
                headers: [
                    "Content-Length": "1024",
                    "Content-Range": "bytes 1024-2047/2048"
                ],
                body: Data(remainder)
            )
        }

        let downloader = ModelDownloader(session: makeMockedSession(), destinationDir: tempDir)
        var completed: URL?
        for try await event in downloader.download(from: URL(string: "https://mock/resume.bin")!, filename: "resume.bin") {
            if case .completed(let u) = event { completed = u }
        }
        XCTAssertEqual(try Data(contentsOf: completed!), full)
    }

    func test_download_overwritesStalePartialWhenServerIgnoresRangeAndReturns200() async throws {
        // Existing partial, but the server ignores Range and replies 200 with the
        // full body. The download must overwrite the stale partial, not append to
        // it (which would produce an oversized, corrupt file and waste disk).
        let full = Data(repeating: 0x37, count: 2048)
        let stalePartial = Data(repeating: 0xFF, count: 1024)
        let partialURL = tempDir.appendingPathComponent("restart.bin.partial")
        try stalePartial.write(to: partialURL)

        MockURLProtocol.responseFor = { _ in
            MockURLProtocol.Response(
                statusCode: 200,
                headers: ["Content-Length": "2048"],
                body: full
            )
        }
        let downloader = ModelDownloader(session: makeMockedSession(), destinationDir: tempDir)
        var completed: URL?
        var lastTotal: Int64 = -1
        for try await event in downloader.download(from: URL(string: "https://mock/restart.bin")!, filename: "restart.bin") {
            switch event {
            case .completed(let u): completed = u
            case .progress(_, let total): lastTotal = total
            }
        }
        XCTAssertEqual(try Data(contentsOf: completed!), full,
                       "200 (range ignored) must overwrite the stale partial, not append")
        XCTAssertEqual(lastTotal, 2048)
    }

    // MARK: helpers
    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// Minimal URLProtocol mock: tests inject a static response handler.
final class MockURLProtocol: URLProtocol {
    struct Response { let statusCode: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var responseFor: ((URLRequest) -> Response)?
    static func reset() { responseFor = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.responseFor else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = handler(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
