import XCTest
@testable import Gemma

/// Verifies `HarnessModel.chatProvider(keyLookup:)` builds a `ModelProvider` from the
/// persisted chat-provider settings (`chatProvider` / `chatModel`). The API key is injected
/// via `keyLookup` so the test doesn't touch the Keychain.
@MainActor
final class HarnessModelProviderTests: XCTestCase {
    func test_chatProvider_readsSettings() {
        UserDefaults.standard.set("gemini", forKey: SettingsKeys.chatProvider)
        UserDefaults.standard.set("gemini-2.0-pro", forKey: SettingsKeys.chatModel)
        let p = HarnessModel.chatProvider(keyLookup: { _ in "K" })
        XCTAssertEqual(p.kind, .gemini)
        XCTAssertEqual(p.model, "gemini-2.0-pro")
        XCTAssertEqual(p.apiKey, "K")
        UserDefaults.standard.removeObject(forKey: SettingsKeys.chatProvider)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.chatModel)
    }
}
