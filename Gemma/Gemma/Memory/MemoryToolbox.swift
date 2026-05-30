import Foundation

/// LiteRT-LM reconstructs `Tool` instances via `init()`, so tools can't receive injected
/// dependencies. They read the active store/embedder from this @MainActor singleton (same
/// pattern as `ToolActivityRelay`). HarnessModel sets it before a turn that uses memory.
@MainActor
final class MemoryToolbox {
    static let shared = MemoryToolbox()
    var store: MemoryStore?
    var embedder: Embedder?

    /// The in-flight post-turn consolidation. The next turn awaits this BEFORE driving the
    /// model, so a consolidation pass (a second generation) never collides with a turn on the
    /// engine's single session (the cause of "the chat corrupted / session already exists").
    var consolidationTask: Task<Void, Never>?

    private init() {}
}
