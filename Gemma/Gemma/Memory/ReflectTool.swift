import Foundation

/// Lets the model choose to reflect while awake: enqueues a light reflection (associate + insight)
/// in the background and pings the Memory Service. Returns immediately so the turn proceeds.
struct ReflectTool: AgentTool {
    static let name = "reflect"
    static let description = "Reflect on the recent conversation to connect and organize what you just learned about the user. Call this when something is worth noting or linking. It runs in the background; just acknowledge briefly."
    static let parameters: [AgentToolParam] = []
    func run(argsJSON: String) async -> String {
        await MainActor.run { MemoryToolbox.shared.reflectionRequest?() }
        if let mem = await MemoryToolbox.shared.memory {
            _ = try? await mem.reflect()
        }
        // `success` sin ramas, y es la verdad entera: lo único que esta herramienta promete es
        // ENCOLAR la reflexión, y encolarla no puede fallar (el ping al servicio va con `try?` a
        // propósito, para que el turno no dependa de él). Antes devolvía esta misma frase en
        // prosa, y la fila del chat la pintaba con cruz roja.
        return ToolJSONOutput.object([
            "status": "success",
            "message": "Reflexión encolada; corre en segundo plano. Acúsalo de pasada y sigue."
        ])
    }
}
