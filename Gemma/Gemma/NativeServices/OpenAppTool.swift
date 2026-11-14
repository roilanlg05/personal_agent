import Foundation

public final class OpenAppTool: AgentTool, Sendable {
    public static let name = "open_app"
    public static let description = "Abre una aplicación instalada en el dispositivo (ej. Spotify, WhatsApp, YouTube, Notas, Fotos, Ajustes, Cámara) usando su esquema URL."
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "app_name", type: .string, description: "Nombre de la aplicación a abrir (ej. 'Spotify', 'WhatsApp', 'YouTube', 'Ajustes', 'Notas')", required: true),
        AgentToolParam(name: "payload", type: .string, description: "Búsqueda o contenido opcional para enviar a la aplicación", required: false)
    ]

    private let launcherService: AppLauncherService

    public init(launcherService: AppLauncherService = AppLauncherService()) {
        self.launcherService = launcherService
    }

    public func run(argsJSON: String) async -> String {
        guard let appName = parseString(named: "app_name", from: argsJSON) else {
            return ToolJSONOutput.error("Se requiere 'app_name'.")
        }

        let payload = parseString(named: "payload", from: argsJSON)

        do {
            let result = try await launcherService.launchApp(name: appName, payload: payload)
            return ToolJSONOutput.object([
                "status": result.opened ? "opened" : "failed",
                "app_name": appName,
                "url": result.url.absoluteString,
                "message": result.opened ? nil : "La app no respondió o no está instalada en el dispositivo."
            ])
        } catch {
            return ToolJSONOutput.error("Error al abrir app: \(error.localizedDescription)")
        }
    }

    private func parseString(named name: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let val = dict[name] as? String, !val.isEmpty else {
            return nil
        }
        return val
    }
}
