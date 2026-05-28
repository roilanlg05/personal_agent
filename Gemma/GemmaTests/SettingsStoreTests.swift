import XCTest
@testable import Gemma

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_load_returnsDefaultWhenEmpty() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)
    }

    func test_saveThenLoad_roundTrips() {
        let store = SettingsStore(defaults: defaults)
        let s = GenerationSettings(backend: .cpu, contextLength: 2048, useSpeculativeDecoding: true,
                                   systemPrompt: "hi", temperature: 0.5, topP: 0.8, topK: 20, maxOutputTokens: 99)
        store.save(s)
        XCTAssertEqual(store.load(), s)
    }
}
