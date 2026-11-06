import Foundation

private func mem() async -> MemoryClient? { await MemoryToolbox.shared.memory }
private func obj(_ argsJSON: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
}

/// Las tareas del usuario, guardadas en la memoria de Gemma.
///
/// ## Dos cosas que faltaban
///
/// 1. **No había forma de actualizar una tarea.** "Completar" se implementaba *borrando*
///    el nodo, así que la tarea hecha desaparecía sin dejar rastro y Gemma perdía el
///    historial de lo que el usuario ya había cumplido. Ahora `update_task` la marca como
///    hecha y `delete_task` sigue existiendo para lo que de verdad hay que tirar.
/// 2. **No cumplían el contrato de honestidad.** Devolvían frases sueltas
///    (`"memory unavailable"`, `"Task saved: X"`) que el modelo tenía que interpretar en
///    vez de leer. Ahora devuelven JSON con `status`, como el resto de las herramientas.
enum TaskToolSupport {

    /// Cuando la memoria no está disponible. Es un fallo de infraestructura y no del
    /// usuario, así que se dice tal cual en vez de fingir que no hay tareas.
    static func memoryUnavailable(_ action: String) -> String {
        ToolJSONOutput.object([
            "status": "memory_unavailable",
            "message": "La memoria de Gemma no está disponible ahora mismo, así que no se pudo \(action). Dile al usuario que no se guardó nada y que puede volver a intentarlo."
        ])
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Busca una tarea por texto, tolerando que el usuario no la nombre exacta.
    static func matching(_ nodes: [MemoryClient.Node], query: String) -> [MemoryClient.Node] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        let exact = nodes.filter { fold($0.label) == needle }
        if !exact.isEmpty { return exact }
        return nodes.filter {
            fold($0.label).contains(needle) || needle.contains(fold($0.label)) || fold($0.body).contains(needle)
        }
    }

    /// `status` guardado en el `extra` del nodo: "pending" o "done".
    static func taskStatus(of node: MemoryClient.Node) -> String {
        guard let extra = node.extra, let data = extra.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = parsed["status"] as? String else {
            return "pending"
        }
        return status
    }

    static func row(_ node: MemoryClient.Node) -> [String: Any] {
        ([
            "id": node.id,
            "title": node.label,
            "detail": node.body.isEmpty || node.body == node.label ? nil : node.body,
            "state": taskStatus(of: node)
        ] as [String: Any?]).compactMapValues { $0 }
    }
}

/// create_task — guarda una tarea o pendiente del usuario.
struct CreateTaskTool: AgentTool {
    static let name = "create_task"
    static let description = """
    Guarda una tarea o pendiente del usuario ('comprar flores', 'llamar a mamá'). Úsalo \
    cuando pida recordar algo que tiene que hacer sin una hora concreta; si hay hora y \
    hay que avisarle, usa create_reminder. Lee 'status': 'created' = guardada; \
    'memory_unavailable' = no se pudo guardar porque la memoria no responde, dile al \
    usuario que no quedó guardada; 'failed' = otro fallo.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Qué hay que hacer, en pocas palabras.", required: true),
        AgentToolParam(name: "detail", type: .string, description: "Contexto o detalles ('hoy después del trabajo', 'las blancas').", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": ["title"],
                "message": "Falta 'title' con lo que hay que hacer."
            ])
        }
        let detail = (o["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title) }
        let result: String = await {
            guard let m = await mem() else { return TaskToolSupport.memoryUnavailable("guardar la tarea") }
            do {
                _ = try await m.save(
                    kind: "task", label: title, body: detail,
                    extra: #"{"status":"pending"}"#, sourceRef: nil
                )
                return ToolJSONOutput.object([
                    "status": "created",
                    "title": title,
                    "detail": detail,
                    "message": detail.map { "Tarea guardada: \(title) (\($0))." } ?? "Tarea guardada: \(title)."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "message": "No se pudo guardar la tarea: \(error.localizedDescription)"
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// list_tasks — las tareas del usuario, pendientes y hechas.
struct ListTasksTool: AgentTool {
    static let name = "list_tasks"
    static let description = """
    Enumera las tareas y pendientes del usuario ('¿tengo algo que hacer?', '¿qué tareas \
    tengo?'). Por omisión solo las pendientes; pasa 'include_done': true para ver también \
    las hechas. Lee 'status': 'ok' = hay tareas, 'empty' = no hay ninguna (dilo tal cual, \
    no supongas que se perdieron), 'memory_unavailable' = la memoria no responde y por \
    eso no se sabe, que NO es lo mismo que no tener tareas. Cada fila trae 'title', \
    'detail', 'state' ('pending' o 'done') y el 'id' que necesitas para update_task.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "include_done", type: .boolean, description: "true para incluir las tareas ya completadas.", required: false)
    ]

    func run(argsJSON: String) async -> String {
        let includeDone = CancelAlarmTool.parseBool(named: "include_done", from: argsJSON) ?? false

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "all") }
        let result: String = await {
            guard let m = await mem() else { return TaskToolSupport.memoryUnavailable("consultar las tareas") }
            do {
                let listed = try await m.nodes(limit: 100, offset: 0, kind: "task")
                let all = listed.nodes
                let shown = includeDone ? all : all.filter { TaskToolSupport.taskStatus(of: $0) != "done" }
                let pending = all.filter { TaskToolSupport.taskStatus(of: $0) != "done" }.count

                return ToolJSONOutput.object([
                    "status": shown.isEmpty ? "empty" : "ok",
                    "tasks": shown.map { TaskToolSupport.row($0) },
                    "pending_count": pending,
                    "done_count": all.count - pending,
                    "message": shown.isEmpty
                        ? (includeDone ? "El usuario no tiene ninguna tarea guardada." : "El usuario no tiene ninguna tarea pendiente.")
                        : "\(pending) pendiente(s)."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "message": "No se pudieron consultar las tareas: \(error.localizedDescription)"
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// update_task — marca una tarea como hecha, o cambia su texto.
struct UpdateTaskTool: AgentTool {
    static let name = "update_task"
    static let description = """
    Cambia una tarea que ya existe: márcala como hecha con 'done': true, o cambia su \
    texto con 'new_title' o 'detail'. Identifícala con 'title' (parte del nombre) o 'id' \
    (de list_tasks). IMPORTANTE: cuando el usuario diga que ya hizo algo ('ya compré las \
    flores'), usa esto con 'done': true y NO delete_task: la tarea queda marcada como \
    hecha y Gemma conserva el historial de lo que cumplió. delete_task es solo para \
    tirar una tarea que nunca debió existir. Lee 'status': 'updated' = cambiada, y \
    'state' dice cómo quedó; 'not_found' = no hay ninguna que encaje, no digas que la \
    marcaste; 'ambiguous' = varias encajan, enséñale 'candidates' y pregunta cuál; \
    'needs_criteria' = no dijiste cuál; 'nothing_to_change' = no mandaste nada nuevo; \
    'memory_unavailable' o 'failed' = no se pudo.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Parte del nombre de la tarea a cambiar.", required: false),
        AgentToolParam(name: "id", type: .string, description: "Identificador exacto, tal como lo devuelve list_tasks.", required: false),
        AgentToolParam(name: "done", type: .boolean, description: "true para marcarla como hecha, false para devolverla a pendiente.", required: false),
        AgentToolParam(name: "new_title", type: .string, description: "Texto nuevo de la tarea.", required: false),
        AgentToolParam(name: "detail", type: .string, description: "Detalle nuevo.", required: false)
    ]

    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let titleQuery = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let idText = (o["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = CancelAlarmTool.parseBool(named: "done", from: argsJSON)
        let newTitle = (o["new_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (o["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (titleQuery?.isEmpty == false) || (idText?.isEmpty == false) else {
            return ToolJSONOutput.object([
                "status": "needs_criteria",
                "message": "Dime cuál cambiar: parte de su 'title' o su 'id'. Llama a list_tasks si no lo sabes."
            ])
        }
        guard done != nil || newTitle?.isEmpty == false || detail?.isEmpty == false else {
            return ToolJSONOutput.object([
                "status": "nothing_to_change",
                "message": "No mandaste nada que cambiar. Pásale 'done', 'new_title' o 'detail'."
            ])
        }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: titleQuery ?? idText ?? "") }
        let result: String = await {
            guard let m = await mem() else { return TaskToolSupport.memoryUnavailable("cambiar la tarea") }
            do {
                let listed = try await m.nodes(limit: 100, offset: 0, kind: "task")
                let matches: [MemoryClient.Node]
                if let idText, !idText.isEmpty {
                    matches = listed.nodes.filter { $0.id == idText }
                } else {
                    matches = TaskToolSupport.matching(listed.nodes, query: titleQuery ?? "")
                }

                guard !matches.isEmpty else {
                    return ToolJSONOutput.object([
                        "status": "not_found",
                        "requested": titleQuery ?? idText,
                        "current": listed.nodes.prefix(20).map { TaskToolSupport.row($0) },
                        "message": "No hay ninguna tarea que encaje. En 'current' está lo que sí hay."
                    ])
                }
                guard matches.count == 1 else {
                    return ToolJSONOutput.object([
                        "status": "ambiguous",
                        "requested": titleQuery ?? idText,
                        "candidates": matches.prefix(8).map { TaskToolSupport.row($0) },
                        "message": "Hay varias tareas que encajan. Pregúntale al usuario cuál; no se cambió ninguna."
                    ])
                }

                let target = matches[0]
                let finalTitle = (newTitle?.isEmpty == false ? newTitle! : target.label)
                let finalDetail = (detail?.isEmpty == false ? detail : (target.body.isEmpty ? nil : target.body))
                let finalState = done.map { $0 ? "done" : "pending" } ?? TaskToolSupport.taskStatus(of: target)

                // Se guarda la versión nueva ANTES de borrar la vieja: al revés, un fallo
                // en medio dejaría al usuario sin la tarea.
                var extra: [String: Any] = ["status": finalState]
                if finalState == "done" {
                    extra["completed_at"] = ISO8601DateFormatter().string(from: Date())
                }
                _ = try await m.save(
                    kind: "task", label: finalTitle, body: finalDetail,
                    extra: ToolJSONOutput.object(extra), sourceRef: nil
                )
                var warnings: [String] = []
                // Si el título no cambió, el servidor ya habrá reemplazado el nodo por
                // etiqueta; borrar entonces tiraría justo lo que se acaba de guardar.
                if finalTitle != target.label {
                    let removed = try await m.forget(label: nil, id: target.id)
                    if removed == 0 { warnings.append("La versión anterior de la tarea no se pudo retirar, puede que aparezca repetida.") }
                }

                return ToolJSONOutput.object([
                    "status": "updated",
                    "title": finalTitle,
                    "detail": finalDetail,
                    "state": finalState,
                    "warnings": warnings.isEmpty ? nil : warnings,
                    "message": finalState == "done"
                        ? "Tarea «\(finalTitle)» marcada como hecha. Sigue guardada en el historial, no se borró."
                        : "Tarea actualizada: \(finalTitle)."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "message": "No se pudo cambiar la tarea: \(error.localizedDescription)"
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// delete_task — tira una tarea del todo.
struct DeleteTaskTool: AgentTool {
    static let name = "delete_task"
    static let description = """
    Borra una tarea del todo. Úsalo solo cuando el usuario quiera QUITARLA ('borra la \
    tarea de...', 'eso ya no hace falta'). Si lo que dice es que YA LA HIZO ('ya compré \
    las flores'), usa update_task con 'done': true, que la marca como hecha y conserva \
    el historial, en vez de hacerla desaparecer. Lee 'status': 'deleted' = borrada, y \
    'deleted_count' dice cuántas; 'not_found' = no había ninguna que encajara, no digas \
    que la borraste; 'ambiguous' = varias encajan, pregunta cuál y no borres ninguna; \
    'memory_unavailable' o 'failed' = no se pudo.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Nombre o parte del nombre de la tarea a borrar.", required: true)
    ]

    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return ToolJSONOutput.object([
                "status": "needs_criteria",
                "message": "Falta 'title' con la tarea que hay que borrar."
            ])
        }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title) }
        let result: String = await {
            guard let m = await mem() else { return TaskToolSupport.memoryUnavailable("borrar la tarea") }
            do {
                let listed = try await m.nodes(limit: 100, offset: 0, kind: "task")
                let matches = TaskToolSupport.matching(listed.nodes, query: title)

                guard !matches.isEmpty else {
                    // Puede que exista con otro `kind`; se intenta por etiqueta antes de
                    // decir que no hay nada.
                    let removed = try await m.forget(label: title, id: nil)
                    if removed > 0 {
                        return ToolJSONOutput.object([
                            "status": "deleted",
                            "deleted_count": removed,
                            "title": title,
                            "message": "Borrado \(removed) elemento(s) que encajaban con «\(title)»."
                        ])
                    }
                    return ToolJSONOutput.object([
                        "status": "not_found",
                        "requested": title,
                        "current": listed.nodes.prefix(20).map { TaskToolSupport.row($0) },
                        "message": "No hay ninguna tarea que encaje con «\(title)». En 'current' está lo que sí hay."
                    ])
                }
                // Borrar la tarea equivocada no se deshace, así que con duda se pregunta.
                guard matches.count == 1 else {
                    return ToolJSONOutput.object([
                        "status": "ambiguous",
                        "requested": title,
                        "candidates": matches.prefix(8).map { TaskToolSupport.row($0) },
                        "message": "Hay varias tareas que encajan. Pregúntale al usuario cuál; no se borró ninguna."
                    ])
                }

                let removed = try await m.forget(label: nil, id: matches[0].id)
                guard removed > 0 else {
                    return ToolJSONOutput.object([
                        "status": "failed",
                        "title": matches[0].label,
                        "message": "La memoria no borró la tarea «\(matches[0].label)». Sigue ahí."
                    ])
                }
                return ToolJSONOutput.object([
                    "status": "deleted",
                    "deleted_count": removed,
                    "title": matches[0].label,
                    "message": "Tarea «\(matches[0].label)» borrada."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "message": "No se pudo borrar la tarea: \(error.localizedDescription)"
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
