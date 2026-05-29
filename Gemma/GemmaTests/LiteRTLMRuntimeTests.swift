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
            audioURL: nil,
            options: GenerationOptions(maxTokens: 32)
        )
        var text = ""
        var got: GenerationResult?
        for try await event in stream {
            switch event {
            case .token(let t): text += t
            case .completed(let r): got = r
            case .toolCallStarted, .toolCallFinished: break
            }
        }
        await runtime.unload()
        XCTAssertNotNil(got)
        XCTAssertFalse(text.isEmpty || got!.text.isEmpty)
        XCTAssertGreaterThan(got!.metrics.tokensGenerated, 0)
    }

    func test_generate_image_producesNonEmptyOutput() async throws {
        let (desc, url) = try installedModelURL()
        try XCTSkipUnless(desc.supportsImage, "Model does not declare image support.")
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url, supportsImage: true))
        // The cascade must have actually brought up the vision executor; otherwise
        // streamGeneration would silently drop the image and this test would pass
        // for the wrong reason (text-only output still yields tokens).
        let mm = await runtime.multimodal
        XCTAssertTrue(mm.image, "Vision executor must have loaded for an image-capable model.")
        let img = UIImage(named: "bench-image-1")!
        let stream = await runtime.generate(
            prompt: "Describe this image briefly.",
            image: img,
            audioURL: nil,
            options: GenerationOptions(maxTokens: 64)
        )
        var got: GenerationResult?
        for try await event in stream { if case .completed(let r) = event { got = r } }
        await runtime.unload()
        XCTAssertNotNil(got)
        XCTAssertGreaterThan(got!.metrics.tokensGenerated, 0)
    }

    func test_load_textOnlyRequest_doesNotEnableMultimodal() async throws {
        let (_, url) = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        // Explicitly request no modalities → cascade goes straight to text-only.
        try await runtime.load(options: ModelLoadOptions(
            modelPath: url, supportsImage: false, supportsAudio: false
        ))
        let loaded = await runtime.isLoaded()
        let mm = await runtime.multimodal
        await runtime.unload()
        XCTAssertTrue(loaded)
        XCTAssertFalse(mm.image)
        XCTAssertFalse(mm.audio)
    }

    func test_generate_audio_producesNonEmptyOutput() async throws {
        let (desc, url) = try installedModelURL()
        try XCTSkipUnless(desc.supportsAudio, "Model does not declare audio support.")
        guard let audioURL = Bundle(for: type(of: self)).url(forResource: "bench-audio-1", withExtension: "m4a") else {
            throw XCTSkip("No bench-audio-1.m4a bundled. Add a short (<=5s) clip to run this test.")
        }
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url, supportsAudio: true))
        let stream = await runtime.generate(
            prompt: "Transcribe or describe this audio briefly.",
            image: nil,
            audioURL: audioURL,
            options: GenerationOptions(maxTokens: 64)
        )
        var got: GenerationResult?
        for try await event in stream { if case .completed(let r) = event { got = r } }
        await runtime.unload()
        XCTAssertNotNil(got)
        XCTAssertGreaterThan(got!.metrics.tokensGenerated, 0)
    }
}
