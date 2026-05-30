import Foundation

/// Returns the user's current local date and time.
struct CurrentTimeTool: AgentTool {
    static let name = "get_current_time"
    static let description = "Returns the user's current local date and time. Call this whenever the user asks what time or date it is."
    static let parameters: [AgentToolParam] = []

    func run(argsJSON: String) async -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let text = fmt.string(from: Date())
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "{}") }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: text) }
        return text
    }
}
