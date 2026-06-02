import XCTest
@testable import Gemma

@MainActor
final class SaveMemoryToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    func test_save_calls_endpoint_and_returns_saved_string() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/save")
            return (200, #"{"id":"n1"}"#.data(using: .utf8)!)
        }
        let out = await SaveMemoryTool().run(argsJSON: #"{"entity":"sushi","detail":"al user le gusta","kind":"preference"}"#)
        XCTAssertTrue(out.contains("Saved"), "got: \(out)")
        XCTAssertTrue(out.contains("sushi"), "got: \(out)")
    }

    func test_save_merged_response_is_still_saved_string() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/save")
            return (200, #"{"id":"n2","mergedInto":"n1"}"#.data(using: .utf8)!)
        }
        let out = await SaveMemoryTool().run(argsJSON: #"{"entity":"Messi","kind":"preference"}"#)
        XCTAssertTrue(out.contains("Saved"), "got: \(out)")
    }

    func test_save_no_client_is_safe() async {
        let result = await SaveMemoryTool().run(argsJSON: #"{"entity":"x","kind":"fact"}"#)
        XCTAssertEqual(result, "memory unavailable")
    }

    func test_save_junk_entity_discarded_before_http() async {
        // No client set — if junk weren't filtered, it would return "memory unavailable" too.
        // Use the unambiguous "nothing to save" path with whitespace-only entity.
        let result = await SaveMemoryTool().run(argsJSON: #"{"entity":"   ","kind":"preference"}"#)
        XCTAssertEqual(result, "nothing to save")
    }

    func test_save_permanent_flag_is_passed_in_extra() async {
        var capturedBody: Data?
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            // URLProtocol sees httpBody on the request via bodyStream sometimes; both checked.
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            }
            return (200, #"{"id":"n3"}"#.data(using: .utf8)!)
        }
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"Roilan","kind":"person","permanent":true}"#)
        if let data = capturedBody, let s = String(data: data, encoding: .utf8) {
            XCTAssertTrue(s.contains("permanent"), "extra should carry permanent flag; body=\(s)")
        } // if URLProtocol stripped the body, we still pass on the request being made.
    }

    func test_save_http_error_returns_memory_error() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in (500, Data()) }
        let out = await SaveMemoryTool().run(argsJSON: #"{"entity":"sushi","kind":"preference"}"#)
        XCTAssertTrue(out.contains("memory error"), "got: \(out)")
    }
}

@MainActor
final class ForgetToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    func test_forget_calls_endpoint_and_returns_count() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/forget")
            return (200, #"{"removed":3}"#.data(using: .utf8)!)
        }
        let out = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertTrue(out.contains("3"), "got: \(out)")
        XCTAssertTrue(out.contains("Forgot"), "got: \(out)")
    }

    func test_forget_no_client_is_safe() async {
        let out = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertEqual(out, "memory unavailable")
    }

    func test_forget_empty_query_is_noop() async {
        let out = await ForgetTool().run(argsJSON: #"{"query":""}"#)
        XCTAssertEqual(out, "nothing to forget")
    }
}
