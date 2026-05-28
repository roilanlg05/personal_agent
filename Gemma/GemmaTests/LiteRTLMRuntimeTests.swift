import XCTest
import UIKit
@testable import Gemma

@MainActor
final class LiteRTLMRuntimeTests: XCTestCase {

    /// Returns the path of an installed Gemma 4 .litertlm, or throws XCTSkip if not present.
    private func installedModelURL() throws -> (descriptor: ModelDescriptor, url: URL) {
        let store = InstalledModels.defaultInDocuments()
        if let desc = ModelCatalog.find("gemma-4-e2b-it"),
           case .installed(let url) = store.status(of: desc) {
            return (desc, url)
        }
        if let desc = ModelCatalog.find("gemma-4-e4b-it"),
           case .installed(let url) = store.status(of: desc) {
            return (desc, url)
        }
        throw XCTSkip("No Gemma 4 .litertlm installed in Documents/Models/. Sideload one to run this test.")
    }

    func test_load_and_isLoaded_returnsTrue() async throws {
        let (_, url) = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url))
        let loaded = await runtime.isLoaded()
        XCTAssertTrue(loaded)
        await runtime.unload()
    }

    func test_generate_textOnly_producesNonEmptyOutput() async throws {
        let (_, url) = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url, useSpeculativeDecoding: false))
        let stream = await runtime.generate(
            prompt: "Say hi in three words.",
            image: nil,
            options: GenerationOptions(maxTokens: 32)
        )
        var text = ""
        var got: GenerationResult?
        for try await event in stream {
            switch event {
            case .token(let t): text += t
            case .completed(let r): got = r
            }
        }
        await runtime.unload()
        XCTAssertNotNil(got)
        XCTAssertFalse(text.isEmpty || got!.text.isEmpty)
        XCTAssertGreaterThan(got!.metrics.tokensGenerated, 0)
    }

    func test_generate_image_producesNonEmptyOutput() async throws {
        let (_, url) = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url))
        let img = UIImage(named: "bench-image-1")!
        let stream = await runtime.generate(
            prompt: "Describe this image briefly.",
            image: img,
            options: GenerationOptions(maxTokens: 64)
        )
        var got: GenerationResult?
        for try await event in stream {
            if case .completed(let r) = event { got = r }
        }
        await runtime.unload()
        XCTAssertNotNil(got)
        XCTAssertGreaterThan(got!.metrics.tokensGenerated, 0)
    }
}
