import XCTest
@testable import Gemma

final class ModelProviderTests: XCTestCase {
    func test_presets_haveExpectedBaseURLsAndModels() {
        XCTAssertEqual(ModelProvider.Kind.local.defaultBaseURL.absoluteString, "http://localhost:8080/v1")
        XCTAssertEqual(ModelProvider.Kind.gemini.defaultBaseURL.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(ModelProvider.Kind.cerebras.defaultBaseURL.absoluteString, "https://api.cerebras.ai/v1")
        XCTAssertEqual(ModelProvider.Kind.groq.defaultBaseURL.absoluteString, "https://api.groq.com/openai/v1")
        XCTAssertEqual(ModelProvider.Kind.gemini.defaultModel, "gemini-2.5-flash")
        XCTAssertEqual(ModelProvider.Kind.local.defaultModel, "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit")
    }
    func test_quirks_localOnly() {
        XCTAssertTrue(ModelProvider.Kind.local.isLocalMLX)
        XCTAssertFalse(ModelProvider.Kind.gemini.isLocalMLX)
        XCTAssertFalse(ModelProvider.Kind.groq.isLocalMLX)
    }
}
