import Foundation

private func obj(_ argsJSON: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
}

/// Tool for querying available shift opportunities from Amazon A to Z.
struct ListAvailableShiftsTool: AgentTool {
    static let name = "list_available_shifts"
    static let description = "Consulta turnos de Amazon A to Z. Devuelve ID, horario y disponibilidad."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "start_date", type: .string, description: "Inicio local en ISO.", required: true),
        AgentToolParam(name: "end_date", type: .string, description: "Fin local en ISO.", required: true)
    ]

    func run(argsJSON: String) async -> String {
        let args = obj(argsJSON)
        let startStr = (args["start_date"] as? String) ?? ""
        let endStr = (args["end_date"] as? String) ?? ""

        await MainActor.run {
            ToolActivityRelay.shared.started(name: Self.name, args: "\(startStr) a \(endStr)")
        }

        let cal = Calendar.current
        let start = parseDate(startStr) ?? cal.startOfDay(for: Date())
        let end = parseDate(endStr) ?? cal.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86400)

        let result: String = await {
            do {
                return AtoZToolOutput.listJSON(
                    try await AtoZClient.shared.listAvailableShifts(start: start, end: end))
            } catch let failure as AtoZFailure {
                return AtoZToolOutput.listFailureJSON(failure.userMessage)
            } catch {
                return AtoZToolOutput.listFailureJSON(error.localizedDescription)
            }
        }()

        await MainActor.run {
            ToolActivityRelay.shared.finished(name: Self.name, result: result)
        }
        return result
    }

    private func parseDate(_ s: String) -> Date? {
        if let d = ScheduleTime.epoch(fromISO: s, endOfDayIfDateOnly: false) {
            return Date(timeIntervalSince1970: d)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

/// Tool for requesting the acceptance of a specific shift opportunity.
/// Enforces two-step confirmation, authorization checks, and verification.
struct AddShiftTool: AgentTool {
    static let name = "add_shift"
    static let description = "Acepta un turno específico de Amazon A to Z con confirmación explícita de fecha y hora."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "shift_opportunity_id", type: .string, description: "ID de list_available_shifts.", required: true),
        AgentToolParam(name: "confirmed", type: .boolean, description: "True tras confirmación explícita.", required: false)
    ]

    func run(argsJSON: String) async -> String {
        let args = obj(argsJSON)
        let oppId = ((args["shift_opportunity_id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        // Estricto a propósito: solo un booleano nativo `true` confirma. Una confirmación no debe
        // convertirse en `true` porque una cadena sea «verdadera»; con `"true"` falla hacia el
        // lado SEGURO (no acepta ni renuncia al turno y se vuelve a pedir la confirmación).
        let confirmed = (args["confirmed"] as? Bool) ?? false

        guard !oppId.isEmpty else {
            return AtoZToolOutput.missingOpportunityID(action: .add)
        }

        await MainActor.run {
            ToolActivityRelay.shared.started(name: Self.name, args: "ID: \(oppId), confirmed: \(confirmed)")
        }

        let result: String = await {
            do {
                let outcome = try await AtoZClient.shared.requestAddShift(opportunityId: oppId, confirmed: confirmed)
                return AtoZToolOutput.json(Self.normalizado(outcome), action: .add)
            } catch let failure as AtoZFailure {
                return AtoZToolOutput.json(.failed(failure), action: .add)
            } catch {
                return AtoZToolOutput.json(.failed(.unknown(error.localizedDescription)), action: .add)
            }
        }()

        await MainActor.run {
            ToolActivityRelay.shared.finished(name: Self.name, result: result)
        }
        return result
    }

    /// `AtoZAddShiftResult` → la forma normalizada que `AtoZToolOutput` traduce. Es un mapeo
    /// caso por caso y nada más: la decisión de qué `status` le toca a cada uno vive en
    /// `AtoZToolOutput.json`, que es pura y se mide sin red.
    private static func normalizado(_ outcome: AtoZAddShiftResult) -> AtoZToolOutput.Outcome {
        switch outcome {
        case .confirmationRequired(let prompt): return .confirmationRequired(prompt)
        case .dryRun(let desc): return .dryRun(desc)
        case .confirmed(let opp): return .confirmed(AtoZFormat.describe(opp))
        case .unknownOutcome(let opp, let reason): return .unknownOutcome(AtoZFormat.describe(opp), reason)
        case .failed(let failure): return .failed(failure)
        }
    }
}

/// Tool for dropping or giving up a scheduled shift on Amazon A to Z.
struct DropShiftTool: AgentTool {
    static let name = "drop_shift"
    static let description = "Suelta un turno asignado de Amazon A to Z con confirmación explícita de fecha y hora."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "shift_opportunity_id", type: .string, description: "ID de turno obtenido de la consulta o el horario.", required: true),
        AgentToolParam(name: "confirmed", type: .boolean, description: "True tras confirmación explícita.", required: false)
    ]

    func run(argsJSON: String) async -> String {
        let args = obj(argsJSON)
        let oppId = ((args["shift_opportunity_id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        // Estricto a propósito: solo un booleano nativo `true` confirma. Una confirmación no debe
        // convertirse en `true` porque una cadena sea «verdadera»; con `"true"` falla hacia el
        // lado SEGURO (no acepta ni renuncia al turno y se vuelve a pedir la confirmación).
        let confirmed = (args["confirmed"] as? Bool) ?? false

        guard !oppId.isEmpty else {
            return AtoZToolOutput.missingOpportunityID(action: .drop)
        }

        await MainActor.run {
            ToolActivityRelay.shared.started(name: Self.name, args: "ID: \(oppId), confirmed: \(confirmed)")
        }

        let result: String = await {
            do {
                let outcome = try await AtoZClient.shared.requestDropShift(opportunityId: oppId, confirmed: confirmed)
                return AtoZToolOutput.json(Self.normalizado(outcome), action: .drop)
            } catch let failure as AtoZFailure {
                return AtoZToolOutput.json(.failed(failure), action: .drop)
            } catch {
                return AtoZToolOutput.json(.failed(.unknown(error.localizedDescription)), action: .drop)
            }
        }()

        await MainActor.run {
            ToolActivityRelay.shared.finished(name: Self.name, result: result)
        }
        return result
    }

    /// `AtoZDropShiftResult` → la forma normalizada. Ver `AddShiftTool.normalizado`: las dos
    /// enumeraciones de A to Z son la misma escrita dos veces.
    private static func normalizado(_ outcome: AtoZDropShiftResult) -> AtoZToolOutput.Outcome {
        switch outcome {
        case .confirmationRequired(let prompt): return .confirmationRequired(prompt)
        case .dryRun(let desc): return .dryRun(desc)
        case .confirmed(let opp): return .confirmed(AtoZFormat.describe(opp))
        case .unknownOutcome(let opp, let reason): return .unknownOutcome(AtoZFormat.describe(opp), reason)
        case .failed(let failure): return .failed(failure)
        }
    }
}
