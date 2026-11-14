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
        // DEVOLVÍA LA FECHA A PELO, Y ESO NO ES UN OBJETO JSON. `ToolLogRow.summarize` empieza
        // por parsear el resultado y lo que no parsea cae en la rama de fallo: preguntar la hora
        // —que funciona siempre— salía en el chat con CRUZ ROJA. La fecha no se toca; lo que
        // cambia es que viaja declarada.
        let result = ToolJSONOutput.object([
            "status": "success",
            "local_time": text,
            "message": "Ahora son las \(text) en la hora local del usuario."
        ])
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
