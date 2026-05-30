import Foundation
import LiteRTLM

/// The model calls this to forget previously remembered facts matching a query.
struct ForgetTool: Tool {
    static let name = "forget"
    static let description = "Forget previously remembered facts that match the given keywords."

    @ToolParam(description: "Keywords describing what to forget.")
    var query: String

    init() {}

    func run() async throws -> Any {
        let query = self.query ?? ""   // @ToolParam exposes Value as optional
        guard !query.isEmpty else { return "nothing to forget" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: query) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store else { return "memory unavailable" }
            do {
                let matches = try store.searchFTS(query: query, limit: 20)
                for m in matches { try store.softDelete(nodeId: m.id) }
                return "Forgot \(matches.count) item(s)."
            } catch {
                return "memory error: \(error)"
            }
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
