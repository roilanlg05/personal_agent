import Foundation

public final class CreateReminderTool: AgentTool, Sendable {
    public static let name = "create_reminder"
    public static let description = """
    Crea un recordatorio para una hora concreta y calcula cuándo avisar. Si el usuario \
    tiene que ir a algún sitio, pasa 'place' con el destino ('el trabajo', 'la clínica'): \
    Gemma estima el viaje y avisa a tiempo de salir, diciéndole la hora límite de salida. \
    Sin 'place' avisa una hora antes. El recordatorio se guarda a la vez en la app \
    Recordatorios, en el aviso propio de Gemma y en su memoria. Lee 'status': 'created' = \
    hecho, y entonces 'alert_at' dice cuándo avisará, 'leave_by' la hora de salida si la \
    hay, y 'stored_in' en qué sitios quedó; si 'stored_in' no incluye los tres, \
    menciónale al usuario lo que falta y por qué, que viene en 'warnings'. En \
    'checkpoints' vienen todos los momentos en que Gemma va a hablarle: cuando abre la \
    ventana para prepararse, cuando le pregunta si ya está listo, y cuando tiene que \
    salir; si hay lugar, Gemma recalcula el viaje a partir de una hora antes y mueve \
    esos avisos si el usuario se ha desplazado. \
    'invalid_date' = la fecha no se entendió o ya pasó; mira 'received' para ver qué \
    enviaste. 'needs_time' = la fecha no traía hora: pregúntale al usuario a qué hora es \
    y vuelve a llamar. 'failed' = no se pudo guardar en ningún sitio. Cuéntale siempre a \
    qué hora le vas a avisar.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Qué hay que recordar, por ejemplo 'reunión con el equipo'", required: true),
        AgentToolParam(name: "due_date", type: .string, description: "Fecha y hora del compromiso, ej. 2026-11-06T08:30:00 (hora local del usuario) o 2026-11-06T08:30:00Z. La hora es obligatoria", required: true),
        AgentToolParam(name: "place", type: .string, description: "Destino al que hay que llegar, si hay que desplazarse", required: false),
        AgentToolParam(name: "notes", type: .string, description: "Detalles adicionales", required: false)
    ]

    private let service: HybridReminderService

    public init(service: HybridReminderService = HybridReminderService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        guard let title = CreateNoteTool.parseString(named: "title", from: argsJSON), !title.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'title' con lo que hay que recordar.")
        }
        guard let dueString = CreateNoteTool.parseString(named: "due_date", from: argsJSON) else {
            return ToolJSONOutput.object([
                "status": "invalid_date",
                "message": "Falta 'due_date' con la fecha y hora del compromiso."
            ])
        }
        guard let parsed = ISO8601Dates.parseDetailed(dueString) else {
            return ToolJSONOutput.object([
                "status": "invalid_date",
                // Se dice lo que llegó: sin esto, un fallo de formato es indiagnosticable.
                "received": dueString,
                "message": "No entendí esa fecha. Escríbela como 2026-11-06T08:30:00 (hora local del usuario)."
            ])
        }
        // Una fecha sin hora no se puede usar: el aviso se calcula desde la hora, y
        // poner el recordatorio a medianoche por nuestra cuenta sería inventarla.
        guard parsed.hasTime else {
            return ToolJSONOutput.object([
                "status": "needs_time",
                "received": dueString,
                "message": "Esa fecha no trae hora. Pregúntale al usuario a qué hora es y vuelve a llamar."
            ])
        }
        let due = parsed.date
        let place = CreateNoteTool.parseString(named: "place", from: argsJSON)
        let notes = CreateNoteTool.parseString(named: "notes", from: argsJSON)

        do {
            let created = try await service.create(
                title: title,
                due: due,
                destination: place.map { ReminderDestination(name: $0) },
                notes: notes
            )
            let plan = created.plan
            let storage = created.storage
            let formatter = ISO8601DateFormatter()

            var storedIn: [String] = []
            if storage.inAppleReminders { storedIn.append("apple_reminders") }
            if storage.gemmaAlertScheduled { storedIn.append("gemma_alert") }
            if storage.inGemmaMemory { storedIn.append("gemma_memory") }

            return ToolJSONOutput.object([
                "status": "created",
                "id": created.reminder.id.uuidString,
                "title": title,
                "due": formatter.string(from: plan.due),
                "alert_at": formatter.string(from: plan.alertAt),
                "leave_by": plan.leaveBy.map { formatter.string(from: $0) },
                "travel_minutes": plan.travelTime.map { Int($0 / 60) },
                "basis": plan.basis.rawValue,
                "place": created.reminder.destination?.name,
                "checkpoints": created.checkpoints.map { checkpoint in
                    [
                        "kind": checkpoint.kind.rawValue,
                        "at": formatter.string(from: checkpoint.at),
                        "message": checkpoint.message(title: title)
                    ]
                },
                "stored_in": storedIn,
                "warnings": storage.failures.isEmpty ? nil : storage.failures,
                "already_late": plan.isLate ? true : nil,
                "message": plan.message(title: title)
            ])
        } catch ReminderLeadTimeError.dueDateInThePast {
            return ToolJSONOutput.object([
                "status": "invalid_date",
                "message": "Esa hora ya pasó. Pregúntale al usuario para cuándo lo quiere."
            ])
        } catch let error as ReminderServiceError {
            return ToolJSONOutput.object([
                "status": "failed",
                "message": error.localizedDescription
            ])
        } catch {
            return ToolJSONOutput.error("No se pudo crear el recordatorio: \(error.localizedDescription)")
        }
    }
}
