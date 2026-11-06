import XCTest
@testable import Gemma

/// Tareas y rutinas eran los tools viejos: prosa libre en inglés, sin contrato de
/// `status`, y con dos huecos de CRUD.
///
/// 1. **Las tareas no se podían actualizar.** "Completar" se implementaba *borrando* el
///    nodo, así que la tarea hecha desaparecía y Gemma perdía el historial de lo que el
///    usuario ya había cumplido.
/// 2. **Las rutinas no se podían borrar.** `set_routine` sobrescribía por título, pero
///    una rutina que dejó de existir (un trabajo que se terminó) se quedaba para siempre
///    generando conflictos de agenda falsos.
///
/// Además devolvían frases como `"memory unavailable"` o `"Task saved: X"`, que el modelo
/// tiene que interpretar en vez de leer. Ahora cumplen el mismo contrato que el resto:
/// un `status` legible y un `message` para el usuario.
final class TaskRoutineContractTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    // MARK: - Contrato: salida legible por el modelo

    func test_create_task_devuelve_json_con_status() async throws {
        // Sin memoria configurada el resultado es 'memory_unavailable', pero tiene que
        // ser JSON con 'status': antes era la frase suelta "memory unavailable".
        let result = try json(await CreateTaskTool().run(argsJSON: #"{"title": "comprar flores"}"#))
        XCTAssertNotNil(result["status"], "Salida: \(result)")
    }

    func test_todos_los_tools_de_tareas_y_rutinas_devuelven_json() async throws {
        let outputs = [
            await CreateTaskTool().run(argsJSON: #"{"title": "x"}"#),
            await ListTasksTool().run(argsJSON: "{}"),
            await UpdateTaskTool().run(argsJSON: #"{"title": "x", "done": true}"#),
            await DeleteTaskTool().run(argsJSON: #"{"title": "x"}"#),
            await SetRoutineTool().run(argsJSON: #"{"title": "x", "days": "lunes", "startTime": "05:00", "endTime": "06:00"}"#),
            await ListRoutinesTool().run(argsJSON: "{}"),
            await DeleteRoutineTool().run(argsJSON: #"{"title": "x"}"#)
        ]
        for out in outputs {
            let parsed = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                "No es JSON: \(out)"
            )
            XCTAssertNotNil(parsed["status"], "Sin 'status': \(out)")
        }
    }

    // MARK: - Validación, que no depende de la memoria

    func test_update_task_exige_identificar_la_tarea() async throws {
        let result = try json(await UpdateTaskTool().run(argsJSON: #"{"done": true}"#))
        XCTAssertEqual(result["status"] as? String, "needs_criteria")
    }

    func test_update_task_exige_algo_que_cambiar() async throws {
        let result = try json(await UpdateTaskTool().run(argsJSON: #"{"title": "comprar flores"}"#))
        XCTAssertEqual(result["status"] as? String, "nothing_to_change")
    }

    func test_delete_routine_exige_titulo() async throws {
        let result = try json(await DeleteRoutineTool().run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "needs_criteria")
    }

    func test_set_routine_rechaza_horas_ilegibles_con_status() async throws {
        let result = try json(await SetRoutineTool().run(
            argsJSON: #"{"title": "Trabajo", "days": "lunes a viernes", "startTime": "por la mañana", "endTime": "tarde"}"#
        ))
        XCTAssertEqual(result["status"] as? String, "invalid_time")
        XCTAssertNotNil(result["received"], "Hay que poder diagnosticar qué llegó.")
    }

    func test_set_routine_rechaza_dias_ilegibles() async throws {
        let result = try json(await SetRoutineTool().run(
            argsJSON: #"{"title": "Trabajo", "days": "cuando pueda", "startTime": "05:00", "endTime": "16:30"}"#
        ))
        XCTAssertEqual(result["status"] as? String, "invalid_days")
    }

    func test_set_routine_exige_los_campos() async throws {
        let result = try json(await SetRoutineTool().run(argsJSON: #"{"title": "Trabajo"}"#))
        XCTAssertEqual(result["status"] as? String, "missing_fields")
        XCTAssertNotNil(result["required"], "Dile al modelo qué le falta.")
    }

    // MARK: - Lo que el modelo lee en las descripciones

    func test_update_task_explica_que_completar_no_borra() {
        let description = UpdateTaskTool.description.lowercased()
        XCTAssertTrue(description.contains("done"))
        XCTAssertTrue(
            description.contains("delete_task") || description.contains("borra"),
            "El modelo tiene que saber cuándo usar esto y cuándo delete_task."
        )
    }

    func test_delete_routine_se_distingue_de_set_routine() {
        let description = DeleteRoutineTool.description.lowercased()
        XCTAssertTrue(description.contains("set_routine"))
    }

    func test_list_tasks_describe_el_estado() {
        let description = ListTasksTool.description.lowercased()
        XCTAssertTrue(description.contains("status"), "El contrato se declara en la descripción.")
    }

    // MARK: - Los días, que es lógica pura

    func test_parse_de_dias_en_espanol() {
        XCTAssertEqual(RoutineHelper.parseDays("lunes a viernes"), [2, 3, 4, 5, 6])
        XCTAssertEqual(RoutineHelper.parseDays("todos los días").count, 7)
        XCTAssertTrue(RoutineHelper.parseDays("cuando pueda").isEmpty)
    }
}
