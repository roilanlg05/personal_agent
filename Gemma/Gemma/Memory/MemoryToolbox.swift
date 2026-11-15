import BrainContract
import Foundation

/// LiteRT-LM reconstructs `Tool` instances via `init()`, so tools can't receive injected
/// dependencies. They read the active memory client from this @MainActor singleton (same
/// pattern as `ToolActivityRelay`). HarnessModel sets it before a turn that uses memory.
@MainActor
final class MemoryToolbox {
    struct TurnScope {
        @MainActor final class Erasure {
            private(set) var committed = false
            let invalidate: () -> Void

            init(invalidate: @escaping () -> Void) { self.invalidate = invalidate }

            func confirm() {
                committed = true
                invalidate()
            }
        }

        let client: MemoryClient?
        let threadID: String
        /// Nil for a verified legacy server, where stable original IDs do not exist.
        let authorizedOriginalIDs: Set<String>?
        let revision: Int64?
        let authorizedForgetID: String?
        let legacyForgetTarget: String?
        let erasure: Erasure

        var isTyped: Bool { revision != nil }

        func lookup(_ query: String) async -> String {
            let unavailable = ToolJSONOutput.object([
                "status": "memory_unavailable", "message": "No pude consultar la memoria en este turno."
            ])
            guard let client, isTyped, query.utf8.count <= 640 else { return unavailable }
            do {
                let budget = try BrainContextBudget(contextTokens: 3072, outputTokens: 256)
                let request = try BrainContextRequest(clientOperationID: UUID().uuidString, threadID: threadID,
                    query: "Recuerda " + query, budget: budget, quoteEvidenceIDs: [], detailEvidenceIDs: [])
                let context = try await client.brainContext(request, cueOnly: true)
                guard context.sourceUses?.values.contains(where: { $0.contains(.recalledSupport) }) == true,
                      !context.renderedContext.isEmpty else {
                    return ToolJSONOutput.object([
                        "status": "empty", "message": "Esta búsqueda no devolvió recuerdos pertinentes."
                    ])
                }
                return ToolJSONOutput.object(["status": "ok", "context": context.renderedContext])
            } catch { return unavailable }
        }

    }

    @TaskLocal static var turnScope: TurnScope?
    static let shared = MemoryToolbox()
    private var configuredMemory: MemoryClient?
    private var configuredReflectionRequest: (() -> Void)?

    var memory: MemoryClient? {
        get {
            if let scope = Self.turnScope { return scope.client }
            return configuredMemory
        }
        set { configuredMemory = newValue }
    }

    var reflectionRequest: (() -> Void)? {
        get { Self.turnScope == nil ? configuredReflectionRequest : nil }
        set { configuredReflectionRequest = newValue }
    }

    private init() {}
}
