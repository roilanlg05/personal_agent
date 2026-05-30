import Foundation

/// Extensible registry of agent tools (CC2). The app builds and holds the instances and
/// passes them to the runtime, which sends their schemas to the model and runs the chosen one.
@MainActor
final class ToolRegistry {
    private(set) var tools: [AgentTool] = []
    init() {}
    // Keep the type @MainActor (it's app/UI-owned state), but let it be torn down off the
    // main actor — its deinit does no main-actor work. Without this, an implicitly
    // MainActor-isolated deinit double-frees under XCTMemoryChecker (macOS 26 XCTest).
    nonisolated deinit {}
    func register(_ tool: AgentTool) { tools.append(tool) }
    func tool(named name: String) -> AgentTool? { tools.first { type(of: $0).name == name } }

    static func withDefaults() -> ToolRegistry {
        let r = ToolRegistry()
        r.register(CurrentTimeTool())
        return r
    }
}
