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

    func test_needsLocalModel_trueIfEitherSideLocal() {
        XCTAssertTrue(HarnessModel.needsLocalModel(chat: "local", consolidation: "gemini"))
        XCTAssertTrue(HarnessModel.needsLocalModel(chat: "groq", consolidation: "local"))
        XCTAssertTrue(HarnessModel.needsLocalModel(chat: "local", consolidation: "local"))
        XCTAssertFalse(HarnessModel.needsLocalModel(chat: "gemini", consolidation: "groq"))
    }

    /// The chat prompt is gated on the LOCAL server only when chat uses the local provider.
    /// Cloud chat (incl. the new default) has no local server to wait on.
    func test_usesLocalServer_defaultsToCloud() {
        XCTAssertTrue(HarnessModel.usesLocalServer("local"))
        XCTAssertFalse(HarnessModel.usesLocalServer("cerebras"))
        XCTAssertFalse(HarnessModel.usesLocalServer("groq"))
        XCTAssertFalse(HarnessModel.usesLocalServer(nil))   // unset → cloud default, no local server
    }

    /// With no provider settings persisted, the default must be cloud so the local 15GB mlx
    /// server does NOT spawn by default (it spawns only when "local" is explicitly chosen).
    func test_defaultProvider_isCloud_soNoLocalSpawnByDefault() {
        let raw = ModelProvider.Kind.defaultKind.rawValue
        XCTAssertFalse(HarnessModel.needsLocalModel(chat: raw, consolidation: raw))
    }
}
