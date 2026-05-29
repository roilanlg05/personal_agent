import Foundation
import LiteRTLM

/// Toy tool whose only purpose is to validate that the E4B reliably calls tools.
/// Emits activity through the shared relay (it can't receive injected context — ToolManager
/// builds the instance via init()).
struct CurrentTimeTool: Tool {
    static let name = "get_current_time"
    static let description = "Returns the user's current local date and time. Call this whenever the user asks what time or date it is."

    init() {}

    func run() async throws -> Any {
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let text = fmt.string(from: now)
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "{}") }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: text) }
        return text
    }
}
