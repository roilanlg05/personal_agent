import XCTest
@testable import Gemma

final class GenerationSettingsTests: XCTestCase {
    func test_default_matchesGalleryRecipe() {
        let s = GenerationSettings.default
        XCTAssertEqual(s.backend, .gpu)
        XCTAssertEqual(s.contextLength, 4096)
        XCTAssertFalse(s.useSpeculativeDecoding)
        XCTAssertEqual(s.systemPrompt, "")
        XCTAssertEqual(s.temperature, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.topP, 0.95, accuracy: 0.0001)
        XCTAssertEqual(s.topK, 64)
        XCTAssertEqual(s.maxOutputTokens, 256)
    }

    func test_codable_roundTrip() throws {
        let s = GenerationSettings(backend: .cpu, contextLength: 2048, useSpeculativeDecoding: true,
                                   systemPrompt: "be brief", temperature: 0.7, topP: 0.9, topK: 40, maxOutputTokens: 128)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(GenerationSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func test_engineLevelDiffers_trueForEngineFields() {
        let base = GenerationSettings.default
        XCTAssertTrue(base.engineLevelDiffers(from: GenerationSettings(backend: .cpu)))
        XCTAssertTrue(base.engineLevelDiffers(from: GenerationSettings(contextLength: 2048)))
        XCTAssertTrue(base.engineLevelDiffers(from: GenerationSettings(useSpeculativeDecoding: true)))
    }

    func test_engineLevelDiffers_falseForLiveFields() {
        let base = GenerationSettings.default
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(systemPrompt: "x")))
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(temperature: 0.5)))
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(topP: 0.8)))
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(topK: 10)))
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(maxOutputTokens: 64)))
    }
}
