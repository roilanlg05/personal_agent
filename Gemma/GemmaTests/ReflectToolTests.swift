import XCTest
@testable import Gemma

@MainActor
final class ReflectToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.reflectionRequest = nil
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    /// LAS DOS ASERCIONES `XCTAssertFalse(out.isEmpty)` DE ESTA CLASE SE QUEDARON VACUAS AL
    /// PONERLE `status` A LA HERRAMIENTA, y de hecho ya lo estaban antes: «no está vacío» lo
    /// cumple cualquier cadena, así que no se enteraban ni de que `reflect` contestaba en prosa
    /// —y la fila del chat la pintaba con cruz roja— ni se enterarían de que dejara de hacerlo.
    /// Se cambian por el estado, que es lo que el bucle y la fila leen.
    func test_reflect_tool_requests_light_reflection_locally() async throws {
        var requested = false
        MemoryToolbox.shared.reflectionRequest = { requested = true }
        let out = await ReflectTool().run(argsJSON: "{}")
        XCTAssertTrue(requested)
        XCTAssertEqual(try estado(out), "success", "got: \(out)")
    }

    func test_reflect_tool_hits_remote_reflect_endpoint_when_client_present() async {
        var sawPath: String?
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            sawPath = req.url?.path
            return (200, #"{"cycleId":"c-1"}"#.data(using: .utf8)!)
        }
        _ = await ReflectTool().run(argsJSON: "{}")
        XCTAssertEqual(sawPath, "/v1/consolidation/reflect")
    }

    func test_reflect_tool_no_handler_is_safe() async throws {
        let out = await ReflectTool().run(argsJSON: "{}")
        XCTAssertEqual(try estado(out), "success",
                       "encolar la reflexión no depende de que haya nadie escuchando: \(out)")
        if case .failure = ToolLogRow.summarize(toolName: "reflect", resultJSON: out) {
            XCTFail("`reflect` salía con cruz roja en el chat: \(out)")
        }
    }

    private func estado(_ out: String) throws -> String {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                                 "la salida tiene que ser un objeto JSON. got: \(out)")
        return try XCTUnwrap(json["status"] as? String, "got: \(out)")
    }
}
