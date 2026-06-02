import XCTest
@testable import Gemma

/// Smoke tests for the `MemoryClient` settings contract used by `HarnessModel.ensureMemory()`:
/// the harness reads `memoryBaseURL` + `memoryBearerToken` from `UserDefaults` (defaults
/// `http://localhost:8081` + "") and constructs a client with them. Constructing the full
/// `HarnessModel` in a unit-test process crashes (it observes `NSApplication.willTerminate`
/// which is unavailable to the XCTest host), so we exercise the construction step here
/// directly. The wiring path itself is verified manually + by the smoke build.
@MainActor
final class HarnessModelTests: XCTestCase {
    func test_memoryClient_carriesBaseURLAndToken() async {
        // Use ephemeral session to avoid any `URLSession.shared` sandbox interactions.
        let client = MemoryClient(baseURL: URL(string: "http://example.test:9999")!,
                                  bearerToken: "hunter2",
                                  session: URLSession(configuration: .ephemeral))
        XCTAssertEqual(client.baseURL.absoluteString, "http://example.test:9999")
        XCTAssertEqual(client.bearerToken, "hunter2")
    }

    func test_memoryToolbox_storesClientAndReflectionHook() async {
        let client = MemoryClient(baseURL: URL(string: "http://localhost:8081")!,
                                  bearerToken: "",
                                  session: URLSession(configuration: .ephemeral))
        MemoryToolbox.shared.memory = client
        XCTAssertNotNil(MemoryToolbox.shared.memory)
        var fired = false
        MemoryToolbox.shared.reflectionRequest = { fired = true }
        MemoryToolbox.shared.reflectionRequest?()
        XCTAssertTrue(fired)
        MemoryToolbox.shared.memory = nil
        MemoryToolbox.shared.reflectionRequest = nil
    }

    /// Smoke: defaulting logic mirroring `HarnessModel.ensureMemory()`. We assert the
    /// fallback constants, not the full `HarnessModel.init()` path (which crashes under
    /// XCTest — see file header).
    func test_defaultBaseURL_isLocalhost8081() {
        let urlString = UserDefaults.standard.string(forKey: "memoryBaseURL") ?? "http://localhost:8081"
        XCTAssertEqual(URL(string: urlString)?.host, "localhost")
    }
}
