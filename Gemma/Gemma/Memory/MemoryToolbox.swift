import Foundation

/// LiteRT-LM reconstructs `Tool` instances via `init()`, so tools can't receive injected
/// dependencies. They read the active store/embedder from this @MainActor singleton (same
/// pattern as `ToolActivityRelay`). HarnessModel sets it before a turn that uses memory.
@MainActor
final class MemoryToolbox {
    static let shared = MemoryToolbox()
    var store: MemoryStore?
    var embedder: Embedder?
    var reflectionRequest: (() -> Void)?

    private init() {}
}
