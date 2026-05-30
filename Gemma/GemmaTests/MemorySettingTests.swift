import XCTest
@testable import Gemma

/// Phase 6 Task 6.1 — `memoryEnabled` is an optional setting (back-compat: old persisted
/// JSON without the key decodes to nil, treated as enabled by callers via `?? true`).
final class MemorySettingTests: XCTestCase {
    func testDefaultIsNil() {
        XCTAssertNil(GenerationSettings.default.memoryEnabled)
    }

    func testRoundTrips() throws {
        var s = GenerationSettings.default
        s.memoryEnabled = false
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(GenerationSettings.self, from: data)
        XCTAssertEqual(decoded.memoryEnabled, false)
    }

    func testBackCompatDecodeWithoutKey() throws {
        // Encode the default, strip the key, decode → nil (no crash on legacy JSON).
        let encoded = try JSONEncoder().encode(GenerationSettings.default)
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "memoryEnabled")
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(GenerationSettings.self, from: data)
        XCTAssertNil(decoded.memoryEnabled)
    }
}
