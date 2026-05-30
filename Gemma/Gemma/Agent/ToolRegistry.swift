import Foundation

/// Extensible registry of agent tools (CC2). The app builds and holds the instances and
/// passes them to the runtime, which sends their schemas to the model and runs the chosen one.
@MainActor
final class ToolRegistry {
    private(set) var tools: [AgentTool] = []
    init() {}
    func register(_ tool: AgentTool) { tools.append(tool) }
    func tool(named name: String) -> AgentTool? { tools.first { type(of: $0).name == name } }

    static func withDefaults() -> ToolRegistry {
        let r = ToolRegistry()
        r.register(CurrentTimeTool())
        return r
    }
}
