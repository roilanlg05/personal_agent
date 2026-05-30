import Foundation
import NaturalLanguage

/// Produces a fixed-dim sentence embedding. On-device via Apple NLContextualEmbedding in
/// v1; the server "premium" embedder (S5b) will conform to this same protocol so retrieval
/// code is unchanged.
protocol Embedder {
    var dimension: Int { get }
    func embed(_ text: String) throws -> [Float]
}

enum MemoryError: Error { case embedderUnavailable }

/// Apple NaturalLanguage contextual embeddings (iOS 17+), mean-pooled over token vectors.
/// Multilingual (Latin script covers Spanish + English). `init` throws if the model or its
/// assets aren't available — callers then degrade to non-vector retrieval (FTS + graph).
final class NLContextualEmbedder: Embedder {
    private let model: NLContextualEmbedding
    let dimension: Int

    init(language: NLLanguage = .spanish) throws {
        guard let m = NLContextualEmbedding(language: language) else { throw MemoryError.embedderUnavailable }
        self.model = m
        self.dimension = m.dimension
        try m.load()   // throws if assets aren't present on device
    }

    func embed(_ text: String) throws -> [Float] {
        let result = try model.embeddingResult(for: text, language: nil)
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
            for i in 0..<min(dimension, vec.count) { sum[i] += vec[i] }
            count += 1
            return true
        }
        guard count > 0 else { return [Float](repeating: 0, count: dimension) }
        return sum.map { Float($0 / Double(count)) }
    }
}

/// Deterministic fake for Mac/sim tests (no NL assets needed).
final class FakeEmbedder: Embedder {
    let dimension: Int
    init(dimension: Int = 4) { self.dimension = dimension }
    func embed(_ text: String) throws -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for (i, ch) in text.unicodeScalars.enumerated() { v[i % dimension] += Float(ch.value % 17) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
