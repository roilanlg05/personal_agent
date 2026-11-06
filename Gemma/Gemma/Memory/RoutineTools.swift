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
        // Vacío cuando no se entendió nada. Antes se caía a [2,3,4,5,6], así que "cuando
        // pueda" se guardaba en silencio como una rutina de lunes a viernes que el
        // usuario nunca pidió, y luego daba conflictos de agenda inventados. Quien llame
        // tiene que preguntar en vez de suponer.
        return result.sorted()
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

    /// Un tramo de un día natural que un evento ocupa, en minutos desde medianoche.
    struct DayWindow: Sendable, Equatable {
        /// Medianoche de ese día, para poder nombrarlo en el aviso.
        let day: Date
        /// Día de la semana según `Calendar` (1 = domingo), que es como se guardan los
        /// días de una rutina.
        let weekday: Int
        let fromMins: Int
        let toMins: Int
    }

    /// Reparte un evento en los tramos que ocupa de cada día natural.
    ///
    /// Esto existe porque la comprobación de rutinas miraba **solo el día de la semana de
    /// la fecha de inicio**. Un viaje de cinco días se comprobaba contra las rutinas del
    /// día 1 y los días 2 al 5 no se miraban nunca: el usuario podía quedar agendado
    /// encima de su turno de trabajo del jueves y Gemma le decía que estaba libre. Es la
    /// misma clase de fallo que SP1 existe para evitar.
    ///
    /// El primer día va desde la hora de inicio hasta medianoche, los de en medio
    /// completos, y el último desde medianoche hasta la hora de fin.
    static func dayWindows(
        startEpoch: Double,
        endEpoch: Double,
        calendar: Calendar = .current
    ) -> [DayWindow] {
        let start = Date(timeIntervalSince1970: startEpoch)
        // Un fin anterior al inicio es entrada inválida (los tools lo rechazan antes de
        // llegar aquí). Se trata como un instante en vez de inventarle una duración.
        let end = Date(timeIntervalSince1970: max(endEpoch, startEpoch))
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)

        let startMins = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        let endMins = calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end)
        let fullDay = 24 * 60

        let spanDays = calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0
        guard spanDays > 0 else {
            return [DayWindow(day: firstDay,
                              weekday: calendar.component(.weekday, from: firstDay),
                              fromMins: startMins,
                              toMins: endMins)]
        }

        // Una rutina es semanal: en cuanto el evento abarca una semana entera ya se han
        // visto los siete días, y recorrer más no encuentra ningún choque nuevo. El tope
        // evita que un evento mal fechado (o de años) haga iterar miles de días.
        let maxDays = 400
        let effectiveSpan = min(spanDays, maxDays)

        var windows: [DayWindow] = []
        windows.reserveCapacity(effectiveSpan + 1)
        for offset in 0...effectiveSpan {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            let from = offset == 0 ? startMins : 0
            // El último tramo solo se recorta si de verdad es el último del evento. Si se
            // llegó al tope, ese día está ocupado entero por lo que falta por venir.
            let isRealLastDay = (offset == effectiveSpan && spanDays <= maxDays)
            let to = isRealLastDay ? endMins : fullDay
            windows.append(DayWindow(day: day,
                                     weekday: calendar.component(.weekday, from: day),
                                     fromMins: from,
                                     toMins: to))
        }
        return windows
    }

    /// Lo que se pudo entender de un nodo que describe un horario habitual.
    private struct ParsedRoutine {
        let title: String
        let detail: String
        let days: [Int]
        let startMins: Int
        let endMins: Int
    }

    /// ¿Se pisan el tramo del evento y el de la rutina?
    private static func overlaps(from: Int, to: Int, routineStart: Int, routineEnd: Int) -> Bool {
        guard from < to else {
            // Evento sin duración ("llámame a las 10:00"): choca si ese instante cae
            // dentro de la rutina. Antes se le añadía una hora de ocupación, y eso
            // producía choques con rutinas que empezaban más tarde y que el usuario
            // nunca había pedido comprobar así.
            return routineStart <= from && from < routineEnd
        }
        return max(from, routineStart) < min(to, routineEnd)
    }

    /// Lee de un nodo de memoria el horario habitual que describe, si describe alguno.
    private static func parseRoutine(_ node: MemoryClient.Node) -> ParsedRoutine? {
        guard node.kind == "routine" || node.kind == "fact" || node.kind == "place" else { return nil }

        var title = node.label
        var days: [Int] = []
        var startMins: Int?
        var endMins: Int?

        if let extra = node.extra, let data = extra.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let t = obj["title"] as? String { title = t }
            if let d = obj["days"] as? [Int] { days = d }
            if let s = obj["startTime"] as? String { startMins = parseMinutes(s) }
            if let e = obj["endTime"] as? String { endMins = parseMinutes(e) }
            if let sM = obj["startMinutes"] as? Int { startMins = sM }
            if let eM = obj["endMinutes"] as? Int { endMins = eM }
        }

        // Camino de respaldo para los hechos que el usuario contó antes de que existiera
        // `set_routine` y que nunca se convirtieron en rutina.
        if days.isEmpty {
            let combined = "\(node.label) \(node.body)".lowercased()
            let looksLikeSchedule = combined.contains("trabaj") || combined.contains("horario")
                || combined.contains("amazon") || combined.contains("rutina")
                || combined.contains("correr") || combined.contains("dormir")
                || combined.contains("despertar")
            if looksLikeSchedule {
                days = parseDays(combined)
                if combined.contains("5:00") && combined.contains("4:30") {
                    startMins = 5 * 60
                    endMins = 16 * 60 + 30
                } else if combined.contains("5:00") && (combined.contains("p. m.") || combined.contains("pm")) {
                    startMins = 17 * 60
                    endMins = 18 * 60
                }
            }
        }

        // Sin días no se puede comprobar, y suponérselos es la invención que `parseDays`
        // dejó de hacer a propósito.
        guard !days.isEmpty, let s = startMins, let e = endMins, s < e else { return nil }
        return ParsedRoutine(title: title, detail: node.body, days: days, startMins: s, endMins: e)
    }

    private static func describeDay(_ day: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return formatter.string(from: day)
    }

    /// Busca choques entre el hueco [inicio, fin] y el horario habitual del usuario.
    ///
    /// Comprueba **todos** los días naturales que abarca el hueco, no solo el primero, y
    /// nombra el primer día en que cada rutina choca: saber que hay conflicto no basta,
    /// porque la decisión del usuario («muevo el vuelo» o «pido el día libre») depende de
    /// qué día sea.
    static func findRoutineConflicts(
        startEpoch: Double,
        endEpoch: Double,
        nodes: [MemoryClient.Node],
        calendar: Calendar = .current
    ) -> [String] {
        let windows = dayWindows(startEpoch: startEpoch, endEpoch: endEpoch, calendar: calendar)
        var conflicts: [String] = []

        for node in nodes {
            guard let routine = parseRoutine(node) else { continue }

            // Una rutina que choca cuatro días del viaje es un solo aviso: repetirlo no
            // añade información, y se reporta el primer día, que es el que decide.
            guard let hit = windows.first(where: { window in
                routine.days.contains(window.weekday)
                    && overlaps(from: window.fromMins, to: window.toMins,
                                routineStart: routine.startMins, routineEnd: routine.endMins)
            }) else { continue }

            let startStr = String(format: "%02d:%02d", routine.startMins / 60, routine.startMins % 60)
            let endStr = String(format: "%02d:%02d", routine.endMins / 60, routine.endMins % 60)
            let daysDesc = routine.days.map { dayName(for: $0) }.joined(separator: ", ")
            let dayDesc = describeDay(hit.day, calendar: calendar)
            let reason = routine.detail.isEmpty ? routine.title : routine.detail
            conflicts.append(
                "⚠️ Rutina/Horario habitual: \(routine.title) (\(startStr)–\(endStr), días: \(daysDesc)). "
                + "Choca el \(dayDesc). Motivo: \(reason)"
            )
        }
        return conflicts
    }
}
/// Las rutinas semanales del usuario (su turno de trabajo, el gimnasio, la hora de
/// dormir), que Gemma usa para detectar conflictos al agendar.
///
/// ## Lo que faltaba
///
/// 1. **No se podían borrar.** `set_routine` sobrescribía por título, pero una rutina que
///    dejó de existir —un trabajo que se terminó, un gimnasio que se dejó— se quedaba
///    para siempre generando conflictos de agenda falsos. Ahora hay `delete_routine`.
/// 2. **No cumplían el contrato de honestidad.** Devolvían prosa suelta en lugar de un
///    `status` que el modelo pudiera leer, así que un "memory unavailable" se parecía
///    demasiado a un "no tienes rutinas".
enum RoutineToolSupport {

    static func memoryUnavailable(_ action: String) -> String {
        ToolJSONOutput.object([
            "status": "memory_unavailable",
            "message": "La memoria de Gemma no está disponible ahora mismo, así que no se pudo \(action). Dile al usuario que no se guardó nada."
        ])
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matching(_ nodes: [MemoryClient.Node], query: String) -> [MemoryClient.Node] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        let exact = nodes.filter { fold($0.label) == needle }
        if !exact.isEmpty { return exact }
        return nodes.filter {
            fold($0.label).contains(needle) || needle.contains(fold($0.label)) || fold($0.body).contains(needle)
        }
    }

    /// Lo que el modelo lee de una rutina. Los días y las horas vienen del `extra`, que
    /// es donde `set_routine` los deja en forma de máquina.
    static func row(_ node: MemoryClient.Node) -> [String: Any] {
        var days: [Int] = []
        var start: String? = nil
        var end: String? = nil
        if let extra = node.extra, let data = extra.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            days = parsed["days"] as? [Int] ?? []
            start = parsed["startTime"] as? String
            end = parsed["endTime"] as? String
        }
        return ([
            "id": node.id,
            "title": node.label,
            "detail": node.body.isEmpty || node.body == node.label ? nil : node.body,
            "days_of_week": days.isEmpty ? nil : days,
            "days": days.isEmpty ? nil : days.map { RoutineHelper.dayName(for: $0) }.joined(separator: ", "),
            "start_time": start,
            "end_time": end
        ] as [String: Any?]).compactMapValues { $0 }
    }
}

/// set_routine — guarda o cambia una rutina semanal.
struct SetRoutineTool: AgentTool {
    static let name = "set_routine"
    static let description = """
    Guarda o cambia una rutina semanal del usuario: su turno de trabajo, el gimnasio, la \
    hora de correr, de dormir o de despertarse. Llamar con el mismo 'title' sobrescribe \
    la que había, así que sirve también para corregirla; para QUITARLA usa \
    delete_routine. Gemma usa las rutinas para avisar de conflictos cuando le agendas \
    algo encima. Lee 'status': 'saved' = guardada; 'invalid_time' = no entendí las horas, \
    mira 'received' y pídeselas al usuario en formato 24h; 'invalid_days' = no entendí \
    los días ('lunes a viernes', 'todos los días', 'lunes,miércoles'); 'missing_fields' = \
    falta algo, mira 'required'; 'memory_unavailable' o 'failed' = no se pudo guardar, y \
    entonces dile que no quedó guardada.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Nombre de la rutina ('Trabajo Amazon', 'Correr por la tarde', 'Dormir').", required: true),
        AgentToolParam(name: "days", type: .string, description: "Días: 'lunes a viernes', 'todos los días', 'lunes,miércoles,viernes'.", required: true),
        AgentToolParam(name: "startTime", type: .string, description: "Hora de inicio ('05:00', '17:00').", required: true),
        AgentToolParam(name: "endTime", type: .string, description: "Hora de fin ('16:30', '18:00').", required: true),
        AgentToolParam(name: "detail", type: .string, description: "Notas o detalles de la rutina.", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let daysStr = ((o["days"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let startTimeStr = ((o["startTime"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endTimeStr = ((o["endTime"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (o["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var missing: [String] = []
        if title.isEmpty { missing.append("title") }
        if daysStr.isEmpty { missing.append("days") }
        if startTimeStr.isEmpty { missing.append("startTime") }
        if endTimeStr.isEmpty { missing.append("endTime") }
        guard missing.isEmpty else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": missing,
                "message": "Faltan datos de la rutina: \(missing.joined(separator: ", ")). Pregúntaselos al usuario."
            ])
        }

        let days = RoutineHelper.parseDays(daysStr)
        guard !days.isEmpty else {
            return ToolJSONOutput.object([
                "status": "invalid_days",
                "received": daysStr,
                "message": "No entendí los días '\(daysStr)'. Escríbelos como 'lunes a viernes', 'todos los días' o 'lunes,miércoles'."
            ])
        }
        guard let sMins = RoutineHelper.parseMinutes(startTimeStr),
              let eMins = RoutineHelper.parseMinutes(endTimeStr) else {
            return ToolJSONOutput.object([
                "status": "invalid_time",
                "received": ["startTime": startTimeStr, "endTime": endTimeStr],
                "message": "No entendí las horas. Pídeselas al usuario en formato 24h, como '05:00' y '16:30'."
            ])
        }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(title): \(startTimeStr)-\(endTimeStr)") }
        let result: String = await {
            guard let m = await mem() else { return RoutineToolSupport.memoryUnavailable("guardar la rutina") }
            do {
                let extraObj: [String: Any] = [
                    "title": title,
                    "days": days,
                    "startTime": startTimeStr,
                    "endTime": endTimeStr,
                    "startMinutes": sMins,
                    "endMinutes": eMins
                ]
                let bodyText = "\(title): \(daysStr) de \(startTimeStr) a \(endTimeStr). \(detail ?? "")"
                _ = try await m.save(
                    kind: "routine", label: title, body: bodyText,
                    extra: ToolJSONOutput.object(extraObj), sourceRef: nil
                )
                return ToolJSONOutput.object([
                    "status": "saved",
                    "title": title,
                    "days_of_week": days,
                    "start_time": startTimeStr,
                    "end_time": endTimeStr,
                    "message": "Rutina guardada: \(title) (\(daysStr), \(startTimeStr)–\(endTimeStr)). Gemma la tendrá en cuenta al revisar la agenda."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "message": "No se pudo guardar la rutina: \(error.localizedDescription)"
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// list_routines — las rutinas guardadas.
struct ListRoutinesTool: AgentTool {
    static let name = "list_routines"
    static let description = """
    Enumera las rutinas semanales del usuario: su turno de trabajo, el gimnasio, la hora \
    de dormir. Úsalo cuando pregunte por su horario habitual, o antes de cambiar o \
    borrar una rutina si no sabes su nombre exacto. Lee 'status': 'ok' = hay rutinas, \
    'empty' = no hay ninguna guardada (dilo tal cual), 'memory_unavailable' = la memoria \
    no responde y por eso no se sabe, que NO es lo mismo que no tener rutinas. Cada fila \
    trae 'title', 'days', 'start_time', 'end_time' y el 'id'.
    """
    static let parameters: [AgentToolParam] = []

    func run(argsJSON: String) async -> String {
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "all") }
        let result: String = await {
            guard let m = await mem() else { return RoutineToolSupport.memoryUnavailable("consultar las rutinas") }
            do {
                let listed = try await m.nodes(limit: 100, offset: 0, kind: "routine")
                guard listed.nodes.isEmpty else {
                    return ToolJSONOutput.object([
                        "status": "ok",
                        "routines": listed.nodes.map { RoutineToolSupport.row($0) },
                        "message": "\(listed.nodes.count) rutina(s) guardada(s)."
                    ])
                }
                // Puede que el horario se haya guardado como hecho suelto antes de que
                // existieran las rutinas; se ofrece como pista, marcado como lo que es.
                let facts = try await m.nodes(limit: 50, offset: 0, kind: "fact")
                let workFacts = facts.nodes.filter {
                    $0.label.lowercased().contains("trabaj") || $0.body.lowercased().contains("trabaj")
                }
                return ToolJSONOutput.object([
                    "status": "empty",
                    "routines": [],
                    "related_facts": workFacts.isEmpty ? nil : workFacts.prefix(10).map {
                        ["label": $0.label, "body": $0.body]
                    },
                    "message": workFacts.isEmpty
                        ? "El usuario no tiene ninguna rutina guardada."
                        : "No hay rutinas guardadas como tales, pero en 'related_facts' hay horarios que el usuario mencionó. Ofrécele guardarlos como rutina con set_routine."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "message": "No se pudieron consultar las rutinas: \(error.localizedDescription)"
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// delete_routine — quita una rutina que ya no existe.
struct DeleteRoutineTool: AgentTool {
    static let name = "delete_routine"
    static let description = """
    Borra una rutina semanal del usuario, cuando deje de existir: cambió de trabajo, dejó \
    el gimnasio, cambió de turno. Es importante quitarla, porque una rutina vieja sigue \
    generando avisos de conflicto falsos cada vez que le agendas algo a esa hora. Si lo \
    que quiere es CAMBIARLA (otro horario, otros días), usa set_routine con el mismo \
    título, que la sobrescribe. Identifícala con 'title' (parte del nombre). Lee \
    'status': 'deleted' = borrada; 'not_found' = no hay ninguna que encaje, mira \
    'current' y no digas que la borraste; 'ambiguous' = varias encajan, pregunta cuál y \
    no borres ninguna; 'needs_criteria' = no dijiste cuál; 'memory_unavailable' o \
    'failed' = no se pudo.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Nombre o parte del nombre de la rutina a borrar.", required: true)
    ]

    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return ToolJSONOutput.object([
                "status": "needs_criteria",
                "message": "Falta 'title' con la rutina que hay que borrar. Llama a list_routines si no sabes cómo se llama."
            ])
        }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title) }
        let result: String = await {
            guard let m = await mem() else { return RoutineToolSupport.memoryUnavailable("borrar la rutina") }
            do {
                let listed = try await m.nodes(limit: 100, offset: 0, kind: "routine")
                let matches = RoutineToolSupport.matching(listed.nodes, query: title)

                guard !matches.isEmpty else {
                    return ToolJSONOutput.object([
                        "status": "not_found",
                        "requested": title,
                        "current": listed.nodes.map { RoutineToolSupport.row($0) },
                        "message": listed.nodes.isEmpty
                            ? "El usuario no tiene ninguna rutina guardada."
                            : "No hay ninguna rutina que encaje con «\(title)». En 'current' están las que sí hay."
                    ])
                }
                // Borrar la rutina equivocada se nota en forma de conflictos de agenda
                // que ya no se detectan, así que con duda se pregunta.
                guard matches.count == 1 else {
                    return ToolJSONOutput.object([
                        "status": "ambiguous",
                        "requested": title,
                        "candidates": matches.map { RoutineToolSupport.row($0) },
                        "message": "Hay varias rutinas que encajan. Pregúntale al usuario cuál; no se borró ninguna."
                    ])
                }

                let target = matches[0]
                let removed = try await m.forget(label: nil, id: target.id)
                guard removed > 0 else {
                    return ToolJSONOutput.object([
                        "status": "failed",
                        "title": target.label,
                        "message": "La memoria no borró la rutina «\(target.label)». Sigue ahí y seguirá dando conflictos."
                    ])
                }
                return ToolJSONOutput.object([
                    "status": "deleted",
                    "title": target.label,
                    "message": "Rutina «\(target.label)» borrada. Ya no va a dar conflictos de agenda."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "message": "No se pudo borrar la rutina: \(error.localizedDescription)"
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
