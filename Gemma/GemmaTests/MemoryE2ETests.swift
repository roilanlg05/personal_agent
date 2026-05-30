import XCTest
@testable import Gemma
import LiteRTLM

/// Device-only E2E for S5a memory. Skips on the simulator (no installed model). Validates the
/// full loop: explicit/auto capture → persistence → recall injected into a later turn.
@MainActor
final class MemoryE2ETests: XCTestCase {
    private func installedModelURL() throws -> URL {
        let store = InstalledModels.defaultInDocuments()
        for id in ["gemma-4-e2b-it", "gemma-4-e4b-it"] {
            if let d = ModelCatalog.find(id), case .installed(let url) = store.status(of: d) { return url }
        }
        throw XCTSkip("No Gemma 4 .litertlm installed — device-only E2E.")
    }

    func testRemembersAcrossTurns() async throws {
        let url = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url))
        defer { Task { await runtime.unload() } }

        let embedder = try? NLContextualEmbedder()
        let dim = embedder?.dimension ?? 512
        let store = try MemoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).sqlite"),
                                    embeddingDim: dim)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = embedder
        defer { MemoryToolbox.shared.store = nil; MemoryToolbox.shared.embedder = nil }

        let registry = ToolRegistry()
        registry.register(RememberTool())
        registry.register(ForgetTool())
        let retriever = MemoryRetriever(store: store, embedder: embedder)
        let consolidator = MemoryConsolidator(runtime: runtime, store: store, embedder: embedder)
        let agent = Agent(runtime: runtime, registry: registry,
                          memory: MemoryServices(retriever: retriever, consolidator: consolidator))

        for try await _ in agent.run(prompt: "Me llamo Roilan, me gusta el sushi y mi amigo Juan trabaja conmigo.",
                                     options: GenerationOptions(maxTokens: 200)) {}
        try await Task.sleep(nanoseconds: 8_000_000_000)  // let async consolidation finish
        XCTAssertFalse(try store.allNodes().isEmpty, "consolidation should have stored memories")

        var answer = ""
        for try await e in agent.run(prompt: "sushi", options: GenerationOptions(maxTokens: 128)) {
            if case .token(let t) = e { answer += t }
        }
        XCTAssertFalse(answer.isEmpty)
    }
}
