import BrainContract
import Foundation

/// Lets the model choose to reflect while awake: enqueues a light reflection (associate + insight)
/// in the background and pings the Memory Service. Returns immediately so the turn proceeds.
struct ReflectTool: AgentTool {
    static let name = "reflect"
    static let description = "Request background reflection to connect and organize memories."
    static let parameters: [AgentToolParam] = []
    func run(argsJSON: String) async -> String {
        if let scope = MemoryToolbox.turnScope, scope.isTyped {
            guard let client = scope.client, let job = try? await client.startBrainReflection(),
                  !job.jobID.isEmpty, job.kind == .reflection, job.state == .running else {
                return "Reflection was not confirmed."
            }
            return "Reflection is running in the background."
        }
        await MainActor.run { MemoryToolbox.shared.reflectionRequest?() }
        if let mem = await MemoryToolbox.shared.memory {
            _ = try? await mem.reflect()
        }
        return "Reflecting in the background."
    }
}
