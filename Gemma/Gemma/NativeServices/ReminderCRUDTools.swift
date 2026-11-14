import Foundation

/// Las tres operaciones que le faltaban a los recordatorios: verlos, moverlos y borrarlos.
///
/// `create_reminder` era lo único que había. Un recordatorio se escribe en tres sitios
/// (la app Recordatorios de Apple, el aviso propio de Gemma y su memoria), así que
/// borrarlo a mano desde la app de Apple dejaba el aviso de Gemma sonando y la memoria
/// creyendo que el compromiso sigue en pie.
///
/// Las tres comparten la resolución por texto, porque el usuario dice "el del dentista",
/// no un UUID.
enum ReminderResolution {

    /// Una candidata, ya resuelta a partir de lo que escribió el modelo.
    struct Match {
        let stored: StoredReminder
    }

    /// Busca por id exacto, y si no por texto en el título.
    static func matching(
        _ reminders: [StoredReminder],
        id: String?,
        title: String?
    ) -> [StoredReminder] {
        if let id, let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespaces)) {
            return reminders.filter { $0.id == uuid }
        }
        guard let title else { return [] }
        let needle = fold(title)
        guard !needle.isEmpty else { return [] }
        let exact = reminders.filter { fold($0.title) == needle }
        if !exact.isEmpty { return exact }
        return reminders.filter { fold($0.title).contains(needle) || needle.contains(fold($0.title)) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cómo se le enseña un recordatorio al modelo.
    static func row(_ stored: StoredReminder, completedInApple: Bool? = nil) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return ([
            "id": stored.id.uuidString,
            "title": stored.title,
            "due": formatter.string(from: stored.due),
            "alert_at": formatter.string(from: stored.alertAt),
            "leave_by": stored.leaveBy.map { formatter.string(from: $0) },
            "place": stored.destinationName,
            "notes": stored.notes,
            "in_apple_reminders": stored.appleID != nil,
            "completed_in_apple": completedInApple
        ] as [String: Any?]).compactMapValues { $0 }
    }
}

/// list_reminders — qué recordatorios tiene puestos el usuario.
public final class ListRemindersTool: AgentTool, Sendable {
    public static let name = "list_reminders"
    public static let description = """
    Enumera los recordatorios que Gemma tiene puestos, con su hora y cuándo va a avisar. \
    Úsalo cuando el usuario pregunte qué recordatorios tiene, o antes de mover o borrar \
    uno si no sabes su 'id'. Lee 'status': 'ok' = hay recordatorios, 'empty' = no hay \
    ninguno (dilo tal cual, no supongas que se perdieron). En cada uno, 'due' es la hora \
    del compromiso y 'alert_at' cuándo avisa Gemma; 'leave_by' es la hora de salir si \
    hay sitio al que ir. 'completed_in_apple': true significa que el usuario ya lo tachó \
    en la app Recordatorios, así que no le insistas con ese; si no viene, no hay nada \
    que contrastar. 'in_apple_reminders': false significa que solo existe como aviso de \
    Gemma, no en la app de Apple.
    """
    public static let parameters: [AgentToolParam] = []

    private let service: HybridReminderService

    public init(service: HybridReminderService = HybridReminderService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let rows = await service.listWithAppleState()
        let pending = rows.filter { $0.completedInApple != true }

        return ToolJSONOutput.object([
            "status": rows.isEmpty ? "empty" : "ok",
            "reminders": rows.map { ReminderResolution.row($0.stored, completedInApple: $0.completedInApple) },
            "pending_count": pending.count,
            "message": rows.isEmpty
                ? "El usuario no tiene ningún recordatorio puesto con Gemma."
                : "\(pending.count) pendiente(s) de \(rows.count)."
        ])
    }
}

/// update_reminder — mueve la hora o cambia el texto de un recordatorio ya puesto.
public final class UpdateReminderTool: AgentTool, Sendable {
    public static let name = "update_reminder"
    public static let description = """
    Cambia un recordatorio ya puesto: la hora, el título, el lugar o las notas. Lo que no \
    pases se queda como estaba. Identifícalo con 'id' (de list_reminders) o con 'title' \
    (parte del nombre). Al mover la hora, Gemma recalcula el aviso y la hora de salida y \
    reprograma todo, así que cuéntale al usuario la hora nueva del aviso. Lee 'status': \
    'updated' = hecho, y entonces 'alert_at' dice cuándo avisará ahora y 'stored_in' en \
    qué sitios quedó; 'invalid_date' = la fecha no se entendió, mira 'received'; \
    'needs_time' = la fecha venía sin hora, pregúntasela; 'not_found' = no hay ninguno \
    que encaje; 'ambiguous' = varios encajan, enséñale 'candidates' y pregunta cuál; \
    'nothing_to_change' = no mandaste ningún campo que cambiar; 'failed' = no se pudo. \
    Para mover solo la hora de un recordatorio, usa esto y NO create_reminder, que \
    dejaría dos.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "id", type: .string, description: "Identificador del recordatorio, tal como lo devuelve list_reminders", required: false),
        AgentToolParam(name: "title", type: .string, description: "Parte del título del recordatorio a cambiar, si no tienes el id", required: false),
        AgentToolParam(name: "due_date", type: .string, description: "Nueva fecha y hora, ej. 2026-11-06T08:30:00 (hora local del usuario)", required: false),
        AgentToolParam(name: "new_title", type: .string, description: "Nuevo título, si hay que cambiarlo", required: false),
        AgentToolParam(name: "place", type: .string, description: "Nuevo destino al que hay que llegar", required: false),
        AgentToolParam(name: "notes", type: .string, description: "Nuevas notas", required: false)
    ]

    private let service: HybridReminderService

    public init(service: HybridReminderService = HybridReminderService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let idText = CreateNoteTool.parseString(named: "id", from: argsJSON)
        let titleQuery = CreateNoteTool.parseString(named: "title", from: argsJSON)
        let dueText = CreateNoteTool.parseString(named: "due_date", from: argsJSON)
        let newTitle = CreateNoteTool.parseString(named: "new_title", from: argsJSON)
        let place = CreateNoteTool.parseString(named: "place", from: argsJSON)
        let notes = CreateNoteTool.parseString(named: "notes", from: argsJSON)

        guard idText != nil || titleQuery != nil else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "message": "Dime cuál cambiar: su 'id' o parte de su 'title'. Llama a list_reminders si no lo sabes."
            ])
        }
        guard dueText != nil || newTitle != nil || place != nil || notes != nil else {
            return ToolJSONOutput.object([
                "status": "nothing_to_change",
                "message": "No mandaste nada que cambiar. Pásale al menos 'due_date', 'new_title', 'place' o 'notes'."
            ])
        }

        // La fecha se valida antes de tocar nada: si es ilegible, no se cambia el resto
        // a medias.
        var newDue: Date? = nil
        if let dueText {
            guard let parsed = ISO8601Dates.parseDetailed(dueText) else {
                return ToolJSONOutput.object([
                    "status": "invalid_date",
                    "received": dueText,
                    "message": "No entendí esa fecha. Escríbela como 2026-11-06T08:30:00 (hora local del usuario)."
                ])
            }
            guard parsed.hasTime else {
                return ToolJSONOutput.object([
                    "status": "needs_time",
                    "received": dueText,
                    "message": "Esa fecha no trae hora. Pregúntale al usuario a qué hora y vuelve a llamar."
                ])
            }
            newDue = parsed.date
        }

        let matches = ReminderResolution.matching(service.list(), id: idText, title: titleQuery)
        guard !matches.isEmpty else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "requested": idText ?? titleQuery,
                "current": service.list().map { ReminderResolution.row($0) },
                "message": "No hay ningún recordatorio que encaje. En 'current' está lo que sí hay."
            ])
        }
        guard matches.count == 1 else {
            return ToolJSONOutput.object([
                "status": "ambiguous",
                "requested": titleQuery ?? idText,
                "candidates": matches.prefix(8).map { ReminderResolution.row($0) },
                "message": "Hay varios que encajan. Pregúntale al usuario cuál; no se cambió ninguno."
            ])
        }

        do {
            let updated = try await service.update(
                id: matches[0].id,
                title: newTitle,
                due: newDue,
                destination: place.map { ReminderDestination(name: $0) },
                notes: notes
            )
            let plan = updated.plan
            let formatter = ISO8601DateFormatter()
            var storedIn: [String] = []
            if updated.storage.inAppleReminders { storedIn.append("apple_reminders") }
            if updated.storage.gemmaAlertScheduled { storedIn.append("gemma_alert") }
            if updated.storage.inGemmaMemory { storedIn.append("gemma_memory") }

            return ToolJSONOutput.object([
                "status": "updated",
                "id": matches[0].id.uuidString,
                "title": updated.reminder.title,
                "due": formatter.string(from: plan.due),
                "alert_at": formatter.string(from: plan.alertAt),
                "leave_by": plan.leaveBy.map { formatter.string(from: $0) },
                "travel_minutes": plan.travelTime.map { Int($0 / 60) },
                "place": updated.reminder.destination?.name,
                "stored_in": storedIn,
                "warnings": updated.storage.failures.isEmpty ? nil : updated.storage.failures,
                "message": plan.message(title: updated.reminder.title)
            ])
        } catch ReminderLeadTimeError.dueDateInThePast {
            return ToolJSONOutput.object([
                "status": "invalid_date",
                "message": "Esa hora ya pasó. Pregúntale al usuario para cuándo lo quiere."
            ])
        } catch {
            return ToolJSONOutput.object([
                "status": "failed",
                "message": "No se pudo cambiar el recordatorio: \(error.localizedDescription)"
            ])
        }
    }
}

/// delete_reminder — lo quita de los tres sitios.
public final class DeleteReminderTool: AgentTool, Sendable {
    public static let name = "delete_reminder"
    public static let description = """
    Borra un recordatorio puesto por Gemma. Identifícalo con 'id' (de list_reminders) o \
    con 'title' (parte del nombre). Lo quita de los tres sitios donde vive: la app \
    Recordatorios de Apple, el aviso de Gemma y su memoria. Lee 'status': 'deleted' = \
    borrado, y 'removed_from' dice de qué sitios; si falta alguno, mira 'warnings' y \
    cuéntaselo al usuario, porque puede que le quede uno en la app de Apple para tachar \
    a mano. 'not_found' = no hay ninguno que encaje, no digas que lo borraste; \
    'ambiguous' = varios encajan, pregunta cuál y no borres ninguno; 'failed' = no se \
    pudo. El aviso de Gemma se retira siempre, incluso si lo demás falla.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "id", type: .string, description: "Identificador del recordatorio, tal como lo devuelve list_reminders", required: false),
        AgentToolParam(name: "title", type: .string, description: "Parte del título del recordatorio a borrar", required: false)
    ]

    private let service: HybridReminderService

    public init(service: HybridReminderService = HybridReminderService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let idText = CreateNoteTool.parseString(named: "id", from: argsJSON)
        let titleQuery = CreateNoteTool.parseString(named: "title", from: argsJSON)

        guard idText != nil || titleQuery != nil else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "message": "Dime cuál borrar: su 'id' o parte de su 'title'. No se borró nada."
            ])
        }

        let matches = ReminderResolution.matching(service.list(), id: idText, title: titleQuery)
        guard !matches.isEmpty else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "requested": idText ?? titleQuery,
                "current": service.list().map { ReminderResolution.row($0) },
                "message": "No hay ningún recordatorio que encaje. En 'current' está lo que sí hay."
            ])
        }
        // Borrar el recordatorio equivocado se descubre cuando no suena el que hacía
        // falta, así que con duda se pregunta.
        guard matches.count == 1 else {
            return ToolJSONOutput.object([
                "status": "ambiguous",
                "requested": titleQuery ?? idText,
                "candidates": matches.prefix(8).map { ReminderResolution.row($0) },
                "message": "Hay varios que encajan. Pregúntale al usuario cuál; no se borró ninguno."
            ])
        }

        let target = matches[0]
        do {
            let outcome = try await service.delete(id: target.id)
            var removedFrom: [String] = []
            if outcome.removedFromAppleReminders { removedFrom.append("apple_reminders") }
            if outcome.alertsCancelled { removedFrom.append("gemma_alert") }
            if outcome.removedFromMemory { removedFrom.append("gemma_memory") }

            return ToolJSONOutput.object([
                "status": "deleted",
                "id": target.id.uuidString,
                "title": target.title,
                "removed_from": removedFrom,
                "warnings": outcome.failures.isEmpty ? nil : outcome.failures,
                "message": outcome.failures.isEmpty
                    ? "Recordatorio «\(target.title)» borrado. Gemma ya no va a avisar."
                    : "Se retiró el aviso de Gemma de «\(target.title)», pero algo quedó sin limpiar: \(outcome.failures.joined(separator: "; "))"
            ])
        } catch {
            return ToolJSONOutput.object([
                "status": "failed",
                "title": target.title,
                "message": "No se pudo borrar: \(error.localizedDescription)"
            ])
        }
    }
}
