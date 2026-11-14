import Foundation

/// Extensible registry of agent tools (CC2). The app builds and holds the instances and
/// passes them to the runtime, which sends their schemas to the model and runs the chosen one.
@MainActor
final class ToolRegistry {
    private(set) var tools: [AgentTool] = []
    private(set) var independentToolNames = Set<String>()
    init() {}
    // Keep the type @MainActor (it's app/UI-owned state), but let it be torn down off the
    // main actor — its deinit does no main-actor work. Without this, an implicitly
    // MainActor-isolated deinit double-frees under XCTMemoryChecker (macOS 26 XCTest).
    nonisolated deinit {}
    func register(_ tool: AgentTool, requiresMemory: Bool = false) {
        tools.append(tool)
        if !requiresMemory { independentToolNames.insert(type(of: tool).name) }
    }
    func tool(named name: String) -> AgentTool? { tools.first { type(of: $0).name == name } }

    static func withDefaults() -> ToolRegistry {
        let r = ToolRegistry()
        r.register(CurrentTimeTool())
        return r
    }

    static func native(memoryAvailable: Bool) -> ToolRegistry {
        let registry = ToolRegistry()
        for tool in [ListAvailableShiftsTool(), AddShiftTool(), DropShiftTool(), CurrentTimeTool()] as [AgentTool] {
            registry.register(tool)
        }
        if memoryAvailable {
            let memoryTools: [AgentTool] = [
                TasteProfileTool(), SearchMemoryTool(), LoadMessagesTool(), ForgetTool(), ReflectTool(),
                SaveMemoryTool(), CheckScheduleTool(), CreateEventTool(), QueryScheduleTool(), CancelEventsTool(),
                UpdateEventTool(), CreateTaskTool(), ListTasksTool(), DeleteTaskTool(), ListTopicsTool(),
                RecallByTopicTool(), WhyTool(), SetRoutineTool(), ListRoutinesTool()
            ]
            for tool in memoryTools { registry.register(tool, requiresMemory: true) }
        }
        return registry
    }

    /// Keep related operations together when a small provider window cannot carry every schema.
    func prioritized(for prompt: String, history: [ChatMessage]) -> [AgentTool] {
        let text = prompt.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        func group(_ text: String) -> [String] {
            func includes(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
            if includes(["alarma", "alarm", "despertador", "despiertame", "despertame", "wake me"]) {
                if includes(["cancela", "borra", "elimina", "cancel", "delete"]) {
                    return [CancelAlarmTool.name, ListAlarmsTool.name]
                }
                if includes(["cambia", "mueve", "update", "move"]) {
                    return [UpdateAlarmTool.name, ListAlarmsTool.name]
                }
                if includes(["creaste", "pusiste", "recuerd", "que alarmas", "what alarms", "tengo una alarma", "tengo alguna alarma", "is there an alarm", "do i have an alarm"]) {
                    return [ListAlarmsTool.name, QueryScheduleTool.name]
                }
                return [CreateAlarmTool.name, ListAlarmsTool.name]
            }
            if includes(["recordatorio", "reminder"]) {
                if includes(["cancela", "borra", "elimina", "cancel", "delete"]) {
                    return [DeleteReminderTool.name, ListRemindersTool.name]
                }
                if includes(["cambia", "mueve", "update", "move"]) {
                    return [UpdateReminderTool.name, ListRemindersTool.name]
                }
                if includes(["creaste", "pusiste", "recuerd", "choca", "choque", "conflict", "que recordatorios", "what reminders"]) {
                    return [ListRemindersTool.name, QueryScheduleTool.name, CheckScheduleTool.name]
                }
                return [CreateReminderTool.name, ListRemindersTool.name]
            }
            if includes(["turno", "shift", "amazon"]) {
                if includes(["soltar", "suelta", "renunci", "drop", "release"]) {
                    return [DropShiftTool.name, ListAvailableShiftsTool.name, AddShiftTool.name]
                }
                if includes(["acept", "coge", "tomar", "add", "take", "claim"]) {
                    return [AddShiftTool.name, ListAvailableShiftsTool.name, DropShiftTool.name]
                }
                return [ListAvailableShiftsTool.name, AddShiftTool.name, DropShiftTool.name]
            }
            if includes(["agenda", "calendario", "calendar", "appointment", "schedule", " cita ", " reunion "]) {
                if includes(["agenda una", "agendame", "programa", "crea ", "book ", "schedule a "]) {
                    return [CheckScheduleTool.name, CreateEventTool.name, QueryScheduleTool.name]
                }
                if includes(["cancela", "cancel "]) { return [CancelEventsTool.name, QueryScheduleTool.name] }
                if includes(["cambia", "mueve", "update ", "move "]) { return [UpdateEventTool.name, QueryScheduleTool.name] }
                return [QueryScheduleTool.name, CheckScheduleTool.name]
            }
            if includes(["musica", "music", "videojuego", "game", "artista", "prefer", "gusto", "playlist"]) {
                return [TasteProfileTool.name, SearchMemoryTool.name]
            }
            if includes(["olvida ", "forget "]) { return [ForgetTool.name, SearchMemoryTool.name] }
            if includes(["recuerd", "remember", "memoria", "memory", "cita exacta", "verbatim"]) {
                return [SearchMemoryTool.name, RecallByTopicTool.name, WhyTool.name, LoadMessagesTool.name]
            }
            return []
        }
        var priorities = group(text)
        let words = text.split(whereSeparator: \.isWhitespace).count
        if priorities.isEmpty, words <= 5 {
            for message in history.suffix(4).reversed() where message.role == .user {
                priorities = group(message.content.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
                if !priorities.isEmpty { break }
            }
        }
        let preferred = priorities.compactMap { tool(named: $0) }
        return preferred + tools.filter { !priorities.contains(type(of: $0).name) }
    }

    static func isShortConfirmation(_ prompt: String) -> Bool {
        let text = prompt.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["si", "si por favor", "dale", "confirmo", "de acuerdo", "hazlo", "yes", "yes please",
                "confirm", "confirmed", "do it", "go ahead"].contains(text)
    }
}
