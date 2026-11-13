import BrainContract
import Foundation

/// LiteRT-LM reconstructs `Tool` instances via `init()`, so tools can't receive injected
/// dependencies. They read the active memory client from this @MainActor singleton (same
/// pattern as `ToolActivityRelay`). HarnessModel sets it before a turn that uses memory.
@MainActor
final class MemoryToolbox {
    struct TurnScope {
        let client: MemoryClient?
        let threadID: String
        /// Nil for a verified legacy server, where stable original IDs do not exist.
        let authorizedOriginalIDs: Set<String>?
        let revision: Int64?
        let authorizedForgetID: String?
        let legacyForgetTarget: String?

        var isTyped: Bool { revision != nil }

        func lookup(_ query: String) async -> String {
            guard let client, isTyped, query.utf8.count <= 640 else { return "Scoped memory search unavailable." }
            do {
                let budget = try BrainContextBudget(contextTokens: 2048, outputTokens: 256)
                let request = try BrainContextRequest(clientOperationID: UUID().uuidString, threadID: threadID,
                    query: query, budget: budget, quoteEvidenceIDs: [], detailEvidenceIDs: [])
                let context = try await client.brainContext(request, cueOnly: true)
                guard !context.renderedContext.isEmpty, context.renderedContext.utf8.count <= 1800 else {
                    return "No additional scoped memory was delivered."
                }
                return context.renderedContext
            } catch { return "Scoped memory search unavailable." }
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
