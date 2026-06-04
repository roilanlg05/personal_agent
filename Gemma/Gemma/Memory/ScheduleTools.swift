import Foundation

private func mem() async -> MemoryClient? { await MemoryToolbox.shared.memory }
private func obj(_ argsJSON: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
}
/// Human suffix for a schedule event status. Active ("scheduled"/nil) → "". Shared by the
/// schedule tools and the recall injection block so cancelled events are never shown as active.
func scheduleStatusSuffix(_ status: String?) -> String {
    switch status {
    case "cancelled": return " (cancelado)"
    case "done": return " (hecho)"
    default: return ""
    }
}

private func eventLine(_ e: MemoryClient.ScheduleEvent) -> String {
    let loc = (e.location?.isEmpty == false) ? " @ \(e.location!)" : ""
    return "\(e.title): \(ScheduleTime.human(fromEpoch: e.start))–\(ScheduleTime.human(fromEpoch: e.end))\(loc)\(scheduleStatusSuffix(e.status))"
}

/// check_schedule — read-only: are there conflicts in [start,end)?
struct CheckScheduleTool: AgentTool {
    static let name = "check_schedule"
    static let description = "Check whether a time slot conflicts with existing events. Call BEFORE creating an event. Pass local ISO datetimes like 2026-06-09T08:00."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "start", type: .string, description: "Local ISO datetime, e.g. 2026-06-09T08:00", required: true),
        AgentToolParam(name: "end", type: .string, description: "Local ISO datetime; the end of the slot.", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        guard let s = (o["start"] as? String).flatMap(ScheduleTime.epoch),
              let e = (o["end"] as? String).flatMap(ScheduleTime.epoch) else {
            return "I need a start and end time (e.g. 2026-06-09T08:00)."
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(ScheduleTime.human(fromEpoch: s))–\(ScheduleTime.human(fromEpoch: e))") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let c = try await m.checkSchedule(start: s, end: e)
                return c.isEmpty ? "No conflicts." : "Conflicts: " + c.map(eventLine).joined(separator: "; ")
            } catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// create_event — books an event; refuses on conflict unless force=true.
struct CreateEventTool: AgentTool {
    static let name = "create_event"
    static let description = "Create a calendar event (meeting/appointment/trip). Pass local ISO datetimes. If it conflicts with an existing event, it will NOT be created unless force=true — tell the user about the conflict and ask before forcing."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Short event title, e.g. \"dentist\", \"Miami meeting\".", required: true),
        AgentToolParam(name: "start", type: .string, description: "Local ISO datetime, e.g. 2026-06-09T08:00.", required: true),
        AgentToolParam(name: "end", type: .string, description: "Local ISO datetime end. If the user gave only a start, ASK for the end first.", required: true),
        AgentToolParam(name: "allDay", type: .boolean, description: "true for all-day/multi-day (e.g. trips).", required: false),
        AgentToolParam(name: "location", type: .string, description: "Place only (city/venue), not prose.", required: false),
        AgentToolParam(name: "force", type: .boolean, description: "true to book despite a conflict (only after the user confirms).", required: false),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              let s = (o["start"] as? String).flatMap(ScheduleTime.epoch),
              let e = (o["end"] as? String).flatMap(ScheduleTime.epoch) else {
            return "I need a title, start, and end (e.g. 2026-06-09T08:00). If you only gave a start, what's the end time?"
        }
        let allDay = (o["allDay"] as? Bool) ?? false
        let location = (o["location"] as? String)?.trimmingCharacters(in: .whitespaces)
        let force = (o["force"] as? Bool) ?? false
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title) }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let r = try await m.createEvent(title: title, start: s, end: e, allDay: allDay,
                                                location: (location?.isEmpty == false) ? location : nil, force: force)
                if r.created { return "Scheduled: \(title) (\(ScheduleTime.human(fromEpoch: s)))" }
                return "NOT scheduled — conflicts with: " + r.conflicts.map(eventLine).joined(separator: "; ")
                     + ". Ask the user whether to reschedule, cancel the other event, or book it anyway — if they confirm, call create_event again with force=true."
            } catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// query_schedule — list events in a window.
struct QueryScheduleTool: AgentTool {
    static let name = "query_schedule"
    static let description = "List the user's events between two local ISO datetimes (use this for \"what's on my schedule this week\"). Pass dates like 2026-06-09 or 2026-06-09T00:00."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "from", type: .string, description: "Local ISO datetime/date for the window start.", required: true),
        AgentToolParam(name: "to", type: .string, description: "Local ISO datetime/date for the window end.", required: true),
        AgentToolParam(name: "includeCancelled", type: .boolean, description: "true to also list cancelled/past events (shown marked '(cancelado)'). Default false — the normal agenda excludes them.", required: false),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        guard let f = (o["from"] as? String).flatMap(ScheduleTime.epoch),
              let t = (o["to"] as? String).flatMap(ScheduleTime.epoch) else {
            return "I need a from/to range (e.g. 2026-06-09 to 2026-06-16)."
        }
        let includeCancelled = (o["includeCancelled"] as? Bool) ?? false
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(ScheduleTime.human(fromEpoch: f))–\(ScheduleTime.human(fromEpoch: t))") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let evs = try await m.scheduleWindow(from: f, to: t, includeCancelled: includeCancelled)
                return evs.isEmpty ? "Nothing scheduled in that range." : evs.map(eventLine).joined(separator: "; ")
            } catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// cancel_events — soft-cancel events in a window (kept, not deleted).
struct CancelEventsTool: AgentTool {
    static let name = "cancel_events"
    static let description = "Cancel the user's events in a local ISO datetime range (e.g. \"cancel my appointments this week\"). Events are kept (cancelled), not deleted."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "from", type: .string, description: "Local ISO datetime/date window start.", required: true),
        AgentToolParam(name: "to", type: .string, description: "Local ISO datetime/date window end.", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        guard let f = (o["from"] as? String).flatMap(ScheduleTime.epoch),
              let t = (o["to"] as? String).flatMap(ScheduleTime.epoch) else {
            return "I need a from/to range to cancel."
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do { let n = try await m.cancelEvents(ids: nil, from: f, to: t); return "Cancelled \(n) event(s)." }
            catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
