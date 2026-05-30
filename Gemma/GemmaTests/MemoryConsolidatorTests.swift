import XCTest
import UIKit
@testable import Gemma

@MainActor
final class MemoryConsolidatorTests: XCTestCase {
    /// Emits a fixed JSON string as tokens through the plain-text generate path.
    final class StubTextRuntime: ModelRuntime {
        nonisolated let identifier = "stub"
        let json: String
        init(json: String) { self.json = json }
        func isLoaded() async -> Bool { true }
        func load(options: ModelLoadOptions) async throws {}
        func unload() async {}
        func currentMetrics() async -> RuntimeMetrics? { nil }
        func generate(prompt: String, image: UIImage?, audioURL: URL?, options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            let j = json
            return AsyncThrowingStream { c in
                c.yield(.token(j))
                c.yield(.completed(GenerationResult(text: j, metrics: RuntimeMetrics(tokensGenerated: 1, elapsedSeconds: 0.01, timeToFirstTokenSeconds: 0.01, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func testConsolidatesMemoriesAndRelations() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let json = """
        noise {"memories":[{"kind":"preference","label":"sushi","body":"likes sushi","confidence":"probable","ttlHours":null},
        {"kind":"person","label":"Juan","body":"friend","confidence":"sure","ttlHours":null}],
        "relations":[{"from":"Juan","relation":"worksWith","to":"sushi"}]} trailing
        """
        let c = MemoryConsolidator(runtime: StubTextRuntime(json: json), store: store, embedder: FakeEmbedder(dimension: 4))
        await c.consolidate(user: "me gusta el sushi y Juan trabaja conmigo", assistant: "ok")
        let labels = Set(try store.allNodes().map { $0.label })
        XCTAssertTrue(labels.contains("sushi"))
        XCTAssertTrue(labels.contains("Juan"))
    }

    func testCleansLabelsDropsJunkAndDedupes() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        // The small model's messy output: a sentence label, a filler label, and a duplicate
        // phrasing of an entity already implied. Cleaning + dedup should yield clean entities.
        let json = """
        {"memories":[
          {"kind":"preference","label":"me gusta el sushi","body":"likes sushi","confidence":"sure","ttlHours":null},
          {"kind":"preference","label":"me gusta","body":"","confidence":"maybe","ttlHours":null},
          {"kind":"preference","label":"Sushi","body":"sushi again","confidence":"sure","ttlHours":null},
          {"kind":"preference","label":"Messi","body":"likes Messi","confidence":"sure","ttlHours":null}
        ],"relations":[]}
        """
        let c = MemoryConsolidator(runtime: StubTextRuntime(json: json), store: store, embedder: FakeEmbedder(dimension: 4))
        await c.consolidate(user: "me gusta el sushi y Messi", assistant: "")
        let nodes = try store.allNodes()
        let labels = Set(nodes.map { $0.label })
        XCTAssertTrue(labels.contains("sushi"), "sentence label should be cleaned to 'sushi'")
        XCTAssertTrue(labels.contains("Messi"))
        XCTAssertFalse(labels.contains("me gusta"), "filler label should be dropped")
        // "me gusta el sushi" and "Sushi" collapse to ONE node (mention reinforced).
        XCTAssertEqual(nodes.filter { MemoryText.dedupKey($0.label) == "sushi" }.count, 1)
        XCTAssertEqual(nodes.count, 2, "only sushi + Messi survive")
    }

    func testInvalidJSONIsNoOp() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let c = MemoryConsolidator(runtime: StubTextRuntime(json: "sorry, no json here"), store: store, embedder: nil)
        await c.consolidate(user: "hi", assistant: "hello")
        XCTAssertTrue(try store.allNodes().isEmpty)
    }

    func testExtractJSON() {
        XCTAssertEqual(MemoryConsolidator.extractJSON("a {\"x\":1} b"), "{\"x\":1}")
        XCTAssertNil(MemoryConsolidator.extractJSON("no braces"))
    }
}
