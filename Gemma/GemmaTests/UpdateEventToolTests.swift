import XCTest
@testable import Gemma

/// NOTA SOBRE LAS CUATRO PRUEBAS DE ESTA CLASE. Afirmaban la prosa INGLESA que `update_event`
/// devolvía («couldn't find», «Updated», «NOT changed», «memory unavailable») con `contains` y
/// `==`. Esa prosa era el defecto: `update_event` se quedó fuera de SP1 —el arreglo que puso
/// `status` a sus cuatro hermanas de `ScheduleTools`— y seguía siendo la única mutación de la
/// agenda que el bucle y la fila del chat no podían leer. Cada prueba se re-apunta al estado que
/// declara lo mismo que su frase decía, y las dos que además protegían un DATO (con qué choca,
/// cómo quedó el evento) lo siguen protegiendo dentro del JSON.
@MainActor
final class UpdateEventToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "la salida tiene que ser un objeto JSON. got: \(out)")
    }

    func test_update_event_tool_reports_not_found() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/schedule/update")
            return (200, #"{"updated":false,"notFound":true}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"ghost"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "not_found", "got: \(out)")
        XCTAssertFalse(Agent.esExito(resultado: out),
                       "no encontrar el evento no puede contar como haberlo cambiado: \(out)")
    }

    func test_update_event_tool_echoes_updated_event() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in
            (200, #"{"updated":true,"event":{"id":"x","title":"meeting","start":9000,"end":9600,"allDay":false,"location":"Miami","status":"scheduled"}}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","location":"Miami"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "success", "got: \(out)")
        // El evento tal como quedó sigue viajando entero: era lo que «Updated: …» protegía.
        let evento = try XCTUnwrap(try json(out)["event"] as? [String: Any], "got: \(out)")
        XCTAssertEqual(evento["location"] as? String, "Miami", "got: \(out)")
        XCTAssertEqual(evento["title"] as? String, "meeting", "got: \(out)")
    }

    func test_update_event_tool_conflict_asks() async throws {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in
            (200, #"{"updated":false,"conflicts":[{"id":"d","title":"dentist","start":3000,"end":3600,"allDay":false,"status":"scheduled"}]}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newStart":"2099-06-09T11:00","newEnd":"2099-06-09T12:00"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "conflict", "got: \(out)")
        // CON QUÉ CHOCA es la mitad que no se puede perder: sin eso el modelo no puede
        // preguntarle al usuario qué hacer, que es justo lo que el estado le pide.
        let choques = try XCTUnwrap(try json(out)["conflicts"] as? [[String: Any]], "got: \(out)")
        XCTAssertEqual(choques.first?["title"] as? String, "dentist", "got: \(out)")
        XCTAssertFalse(Agent.esExito(resultado: out), "un choque no es un cambio: \(out)")
    }

    func test_update_event_tool_no_client_is_safe() async throws {
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00"}"#)
        XCTAssertEqual(try json(out)["status"] as? String, "memory_unavailable", "got: \(out)")
        XCTAssertTrue(Agent.esFallo(resultado: out), "got: \(out)")
    }
}
