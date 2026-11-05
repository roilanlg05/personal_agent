import Foundation

private func mem() async -> MemoryClient? { await MemoryToolbox.shared.memory }
private func obj(_ argsJSON: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
}

struct RoutineHelper: Sendable {
    static func dayNumber(for dayStr: String) -> Int? {
        let s = dayStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("dom") || s.hasPrefix("sun") { return 1 }
        if s.hasPrefix("lun") || s.hasPrefix("mon") { return 2 }
        if s.hasPrefix("mar") || s.hasPrefix("tue") { return 3 }
        if s.hasPrefix("mie") || s.hasPrefix("mié") || s.hasPrefix("wed") { return 4 }
        if s.hasPrefix("jue") || s.hasPrefix("thu") { return 5 }
        if s.hasPrefix("vie") || s.hasPrefix("fri") { return 6 }
        if s.hasPrefix("sab") || s.hasPrefix("sáb") || s.hasPrefix("sat") { return 7 }
        return Int(s)
    }

    static func dayName(for dayNum: Int) -> String {
        switch dayNum {
        case 1: return "Domingo"
        case 2: return "Lunes"
        case 3: return "Martes"
        case 4: return "Miércoles"
        case 5: return "Jueves"
        case 6: return "Viernes"
        case 7: return "Sábado"
        default: return "Día \(dayNum)"
        }
    }

    static func parseDays(_ input: String) -> [Int] {
        let clean = input.lowercased()
        if clean.contains("todos") || clean.contains("diario") || clean.contains("daily") || clean.contains("every") {
            return [1, 2, 3, 4, 5, 6, 7]
        }
        if clean.contains("lunes a viernes") || clean.contains("mon-fri") || clean.contains("semana") {
            var days = [2, 3, 4, 5, 6]
            if clean.contains("excepto miér") || clean.contains("except wed") {
                days.removeAll { $0 == 4 }
            }
            return days
        }
        if clean.contains("miércoles a sábado") || clean.contains("wed-sat") {
            return [4, 5, 6, 7]
        }
        if clean.contains("fin de semana") || clean.contains("weekend") {
            return [1, 7]
        }

        // Comma or space separated
        let parts = clean.components(separatedBy: CharacterSet(charactersIn: ",;/ -"))
        var result: [Int] = []
        for p in parts {
            if let d = dayNumber(for: p), !result.contains(d) {
                result.append(d)
            }
        }
        return result.isEmpty ? [2, 3, 4, 5, 6] : result.sorted()
    }

    static func parseMinutes(_ timeStr: String) -> Int? {
        let s = timeStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPM = s.contains("pm") || s.contains("p. m.")
        let isAM = s.contains("am") || s.contains("a. m.")
        let clean = s.replacingOccurrences(of: "am", with: "")
                     .replacingOccurrences(of: "pm", with: "")
                     .replacingOccurrences(of: "a. m.", with: "")
                     .replacingOccurrences(of: "p. m.", with: "")
                     .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = clean.split(separator: ":").compactMap { Int($0) }
        guard let hour = parts.first else { return nil }
        let minute = parts.count > 1 ? parts[1] : 0
        var h = hour
        if isPM && h < 12 { h += 12 }
        if isAM && h == 12 { h = 0 }
        return h * 60 + minute
    }

    /// Check if a time slot [start, end] conflicts with any recurring routines or work hours.
    static func findRoutineConflicts(startEpoch: Double, endEpoch: Double, nodes: [MemoryClient.Node]) -> [String] {
        var conflicts: [String] = []
        let cal = Calendar.current
        let startDate = Date(timeIntervalSince1970: startEpoch)
        let endDate = Date(timeIntervalSince1970: endEpoch)
        let weekday = cal.component(.weekday, from: startDate)
        let startMins = cal.component(.hour, from: startDate) * 60 + cal.component(.minute, from: startDate)
        let rawEndMins = cal.component(.hour, from: endDate) * 60 + cal.component(.minute, from: endDate)
        let endMins = (rawEndMins <= startMins) ? (startMins + 60) : rawEndMins

        for node in nodes {
            guard node.kind == "routine" || node.kind == "fact" || node.kind == "place" else { continue }

            var rTitle = node.label
            var rDays: [Int] = []
            var rStartMins: Int?
            var rEndMins: Int?
            var rDetail = node.body

            if let extra = node.extra, let data = extra.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let title = obj["title"] as? String { rTitle = title }
                if let days = obj["days"] as? [Int] { rDays = days }
                if let s = obj["startTime"] as? String { rStartMins = parseMinutes(s) }
                if let e = obj["endTime"] as? String { rEndMins = parseMinutes(e) }
                if let sM = obj["startMinutes"] as? Int { rStartMins = sM }
                if let eM = obj["endMinutes"] as? Int { rEndMins = eM }
            }

            // Fallback: parse from text if not in extra
            if rDays.isEmpty {
                let combined = "\(node.label) \(node.body)".lowercased()
                if combined.contains("trabaj") || combined.contains("horario") || combined.contains("amazon") ||
                   combined.contains("rutina") || combined.contains("correr") || combined.contains("dormir") || combined.contains("despertar") {
                    rDays = parseDays(combined)
                    // Extract times like 5:00 a. m. a 4:30 p. m.
                    if combined.contains("5:00") && combined.contains("4:30") {
                        rStartMins = 5 * 60
                        rEndMins = 16 * 60 + 30
                    } else if combined.contains("5:00") && (combined.contains("p. m.") || combined.contains("pm")) {
                        rStartMins = 17 * 60
                        rEndMins = 18 * 60
                    }
                }
            }

            guard rDays.contains(weekday), let rStart = rStartMins, let rEnd = rEndMins else { continue }

            // Check overlap: max(start, rStart) < min(end, rEnd)
            let overlapStart = max(startMins, rStart)
            let overlapEnd = min(endMins, rEnd)
            if overlapStart < overlapEnd {
                let startStr = String(format: "%02d:%02d", rStart / 60, rStart % 60)
                let endStr = String(format: "%02d:%02d", rEnd / 60, rEnd % 60)
                let daysDesc = rDays.map { dayName(for: $0) }.joined(separator: ", ")
                conflicts.append("⚠️ Rutina/Horario habitual: \(rTitle) (\(startStr)–\(endStr), días: \(daysDesc)). Motivo: \(rDetail.isEmpty ? rTitle : rDetail)")
            }
        }
        return conflicts
    }
}

/// set_routine — save or update a recurring weekly routine or work schedule.
struct SetRoutineTool: AgentTool {
    static let name = "set_routine"
    static let description = """
    Save or update a weekly recurring routine, work schedule, gym, running, wake-up, or sleep time. \
    Call this when the user mentions their recurring schedule, job hours, or daily habits.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Name of the routine (e.g. 'Trabajo Amazon', 'Correr por la tarde', 'Dormir', 'Hora de despertar').", required: true),
        AgentToolParam(name: "days", type: .string, description: "Days of the week (e.g. 'lunes a viernes', 'miércoles a sábado', 'todos los días', 'mon,wed,fri').", required: true),
        AgentToolParam(name: "startTime", type: .string, description: "Start time (e.g. '05:00', '17:00', '5:00 AM').", required: true),
        AgentToolParam(name: "endTime", type: .string, description: "End time (e.g. '16:30', '18:00', '4:30 PM').", required: true),
        AgentToolParam(name: "detail", type: .string, description: "Optional notes or details about the routine.", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let daysStr = ((o["days"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let startTimeStr = ((o["startTime"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endTimeStr = ((o["endTime"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (o["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, !daysStr.isEmpty, !startTimeStr.isEmpty, !endTimeStr.isEmpty else {
            return "Se requieren título, días, hora de inicio y hora de fin."
        }

        let days = RoutineHelper.parseDays(daysStr)
        guard let sMins = RoutineHelper.parseMinutes(startTimeStr),
              let eMins = RoutineHelper.parseMinutes(endTimeStr) else {
            return "No se pudieron interpretar las horas '\(startTimeStr)' o '\(endTimeStr)'."
        }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(title): \(startTimeStr)-\(endTimeStr)") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let extraObj: [String: Any] = [
                    "title": title,
                    "days": days,
                    "startTime": startTimeStr,
                    "endTime": endTimeStr,
                    "startMinutes": sMins,
                    "endMinutes": eMins
                ]
                let extraData = (try? JSONSerialization.data(withJSONObject: extraObj)) ?? Data()
                let extraJSON = String(data: extraData, encoding: .utf8)

                let bodyText = "\(title): \(daysStr) de \(startTimeStr) a \(endTimeStr). \(detail ?? "")"
                _ = try await m.save(kind: "routine", label: title, body: bodyText, extra: extraJSON, sourceRef: nil)
                return "Rutina guardada con éxito: \(title) (\(daysStr), \(startTimeStr)–\(endTimeStr)). Se tendrá en cuenta automáticamente al verificar tu agenda."
            } catch {
                return "Error al guardar rutina: \(error)"
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// list_routines — list all active weekly recurring routines and work hours.
struct ListRoutinesTool: AgentTool {
    static let name = "list_routines"
    static let description = "List all saved recurring routines, work hours, and daily habits."
    static let parameters: [AgentToolParam] = []

    func run(argsJSON: String) async -> String {
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "all") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let r = try await m.nodes(limit: 100, offset: 0, kind: "routine")
                if r.nodes.isEmpty {
                    // Check facts for any mentioned work schedules
                    let facts = try await m.nodes(limit: 50, offset: 0, kind: "fact")
                    let workFacts = facts.nodes.filter { $0.label.lowercased().contains("trabaj") || $0.body.lowercased().contains("trabaj") }
                    if workFacts.isEmpty {
                        return "No hay rutinas recurrentes guardadas."
                    }
                    return "Horarios de trabajo/rutinas registrados en memoria:\n" + workFacts.map { "- \($0.label): \($0.body)" }.joined(separator: "\n")
                }
                return "Rutinas semanales registradas:\n" + r.nodes.map { "- \($0.label): \($0.body)" }.joined(separator: "\n")
            } catch {
                return "Error al listar rutinas: \(error)"
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
