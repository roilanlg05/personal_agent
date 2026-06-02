import Foundation
import Hummingbird
import Logging

public struct AppConfig: Sendable {
    public var bearerToken: String
    public var dbPath: String
    public var embedderURL: String
    public var modelURL: String

    public static func testDefaults() -> AppConfig {
        AppConfig(bearerToken: "test-token", dbPath: ":memory:",
                  embedderURL: "http://embedder:8000",
                  modelURL: "http://host.docker.internal:8080")
    }

    public static func fromEnvironment() -> AppConfig {
        guard let token = ProcessInfo.processInfo.environment["MEMORY_BEARER_TOKEN"] else {
            fatalError("MEMORY_BEARER_TOKEN must be set")
        }
        return AppConfig(
            bearerToken: token,
            dbPath: ProcessInfo.processInfo.environment["MEMORY_DB_PATH"] ?? "/data/memory.sqlite",
            embedderURL: ProcessInfo.processInfo.environment["EMBEDDER_URL"] ?? "http://embedder:8000",
            modelURL: ProcessInfo.processInfo.environment["MODEL_URL"] ?? "http://host.docker.internal:8080"
        )
    }
}

public func buildApp(config: AppConfig) async throws -> some ApplicationProtocol {
    let router = Router()
    router.get("/healthz") { _, _ -> Response in
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: .init(string: #"{"status":"ok"}"#))
        )
    }
    return Application(
        router: router,
        configuration: ApplicationConfiguration(address: .hostname("0.0.0.0", port: 8081)),
        logger: Logger(label: "memory-service")
    )
}
