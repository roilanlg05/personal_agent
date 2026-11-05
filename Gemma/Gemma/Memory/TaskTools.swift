import Foundation

private func mem() async -> MemoryClient? { await MemoryToolbox.shared.memory }
private func obj(_ argsJSON: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
}

/// create_task — creates a to-do, reminder, or pending task for the user.
struct CreateTaskTool: AgentTool {
    static let name = "create_task"
    static let description = "Save a to-do, task, or reminder for the user (e.g. 'buy flowers for my wife', 'call mom'). Call this when the user asks to remember a task or to-do."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Short title of the task or to-do to remember.", required: true),
        AgentToolParam(name: "detail", type: .string, description: "Optional context, timing, or details (e.g. 'today after work', 'tomorrow at 5pm').", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Title is required for a task." }
        let detail = (o["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title) }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                _ = try await m.save(kind: "task", label: title, body: detail, extra: #"{"status":"pending"}"#, sourceRef: nil)
                if let d = detail, !d.isEmpty {
                    return "Task saved: \(title) (\(d))"
                }
                return "Task saved: \(title)"
            } catch {
                return "error saving task: \(error)"
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// list_tasks — list all active/pending tasks and reminders.
struct ListTasksTool: AgentTool {
    static let name = "list_tasks"
    static let description = "List the user's active tasks, to-dos, and reminders (use this for 'is there any to do?', 'what tasks do I have?')."
    static let parameters: [AgentToolParam] = []

    func run(argsJSON: String) async -> String {
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "all") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let r = try await m.nodes(limit: 100, offset: 0, kind: "task")
                if r.nodes.isEmpty { return "No pending tasks or to-dos found." }
                return "Tasks: " + r.nodes.map { node in
                    if !node.body.isEmpty && node.body != node.label {
                        return "\(node.label) (\(node.body))"
                    }
                    return node.label
                }.joined(separator: "; ")
            } catch {
                return "error listing tasks: \(error)"
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// delete_task — deletes, completes, or removes a task, reminder, or to-do.
struct DeleteTaskTool: AgentTool {
    static let name = "delete_task"
    static let description = "Delete, complete, or remove a task, reminder, or to-do. Call this when the user says they completed, want to remove, or delete a task (e.g. 'borra la tarea...', 'elimina el recordatorio...', 'ya compré las flores')."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Title or keywords of the task to delete/remove.", required: true)
    ]

    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Title or keyword is required to delete a task." }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title) }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let r = try await m.nodes(limit: 100, offset: 0, kind: "task")
                let needle = title.lowercased()
                let matches = r.nodes.filter {
                    $0.label.lowercased().contains(needle) ||
                    needle.contains($0.label.lowercased()) ||
                    (!needle.isEmpty && $0.body.lowercased().contains(needle))
                }

                if matches.isEmpty {
                    let removed = try await m.forget(label: title, id: nil)
                    if removed > 0 {
                        return "Deleted \(removed) task(s) matching '\(title)'."
                    }
                    return "No task found matching '\(title)'."
                }

                var count = 0
                for match in matches {
                    _ = try await m.forget(label: nil, id: match.id)
                    count += 1
                }
                return "Task '\(title)' deleted successfully (\(count) item(s) removed)."
            } catch {
                return "error deleting task: \(error)"
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
