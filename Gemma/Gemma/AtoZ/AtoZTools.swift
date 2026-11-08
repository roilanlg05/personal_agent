import Foundation

private func obj(_ argsJSON: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
}

/// Tool for querying available shift opportunities from Amazon A to Z.
struct ListAvailableShiftsTool: AgentTool {
    static let name = "list_available_shifts"
    static let description = "Consulta los turnos y oportunidades disponibles en Amazon A to Z. Proporciona start_date y end_date en formato ISO (YYYY-MM-DD o YYYY-MM-DDTHH:mm). Devuelve los turnos con ID, horario y disponibilidad."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "start_date", type: .string, description: "Fecha de inicio del rango (ej. 2026-11-04 o 2026-11-04T00:00).", required: true),
        AgentToolParam(name: "end_date", type: .string, description: "Fecha de fin del rango (ej. 2026-11-07 o 2026-11-07T23:59).", required: true)
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
                let list = try await AtoZClient.shared.listAvailableShifts(start: start, end: end)
                if list.isEmpty {
                    return "No hay turnos disponibles para ese período."
                }
                var lines: [String] = []
                for opp in list {
                    let desc = AtoZFormat.describe(opp)
                    let elig = opp.isEligible ? "Disponible" : "No disponible (\(opp.unclaimableReasonCodes.joined(separator: ", ")))"
                    lines.append("• [ID: \(opp.id)] \(desc) — \(elig)")
                }
                return "Turnos encontrados:\n" + lines.joined(separator: "\n")
            } catch let failure as AtoZFailure {
                return failure.userMessage
            } catch {
                return "Error al consultar turnos: \(error.localizedDescription)"
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
    static let description = "Solicita la aceptación de un turno específico en Amazon A to Z. Requiere confirmación explícita previa del usuario indicando fecha y hora del turno antes de ejecutar."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "shift_opportunity_id", type: .string, description: "ID único de la oportunidad de turno obtenido previamente de list_available_shifts.", required: true),
        AgentToolParam(name: "confirmed", type: .boolean, description: "true solo si el usuario ha confirmado explícitamente la aceptación de este turno en específico tras haberle preguntado.", required: false)
    ]

    func run(argsJSON: String) async -> String {
        let args = obj(argsJSON)
        let oppId = ((args["shift_opportunity_id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        // Estricto a propósito: solo un booleano nativo `true` confirma. Una confirmación no debe
        // convertirse en `true` porque una cadena sea «verdadera»; con `"true"` falla hacia el
        // lado SEGURO (no acepta ni renuncia al turno y se vuelve a pedir la confirmación).
        let confirmed = (args["confirmed"] as? Bool) ?? false

        guard !oppId.isEmpty else {
            return "Se requiere el identificador de la oportunidad (shift_opportunity_id)."
        }

        await MainActor.run {
            ToolActivityRelay.shared.started(name: Self.name, args: "ID: \(oppId), confirmed: \(confirmed)")
        }

        let result: String = await {
            do {
                let outcome = try await AtoZClient.shared.requestAddShift(opportunityId: oppId, confirmed: confirmed)
                switch outcome {
                case .confirmationRequired(let prompt):
                    return prompt
                case .dryRun(let desc):
                    return desc
                case .confirmed(let opp):
                    return "¡Turno aceptado y verificado en tu horario exitosamente! (\(AtoZFormat.describe(opp)))"
                case .unknownOutcome(let opp, let reason):
                    return "Resultado incierto para el turno (\(AtoZFormat.describe(opp))): \(reason). Por seguridad no se reintentará automáticamente; por favor verifica tu aplicación A to Z."
                case .failed(let failure):
                    return failure.userMessage
                }
            } catch let failure as AtoZFailure {
                return failure.userMessage
            } catch {
                return "Error al solicitar turno: \(error.localizedDescription)"
            }
        }()

        await MainActor.run {
            ToolActivityRelay.shared.finished(name: Self.name, result: result)
        }
        return result
    }
}

/// Tool for dropping or giving up a scheduled shift on Amazon A to Z.
struct DropShiftTool: AgentTool {
    static let name = "drop_shift"
    static let description = "Solicita renunciar o soltar (drop off) un turno asignado en Amazon A to Z. Requiere confirmación explícita previa del usuario con fecha y hora antes de ejecutar."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "shift_opportunity_id", type: .string, description: "ID único de la oportunidad de turno u oportunidad de drop obtenido de list_available_shifts o del horario.", required: true),
        AgentToolParam(name: "confirmed", type: .boolean, description: "true solo si el usuario ha confirmado explícitamente renunciar a este turno en específico tras haberle preguntado.", required: false)
    ]

    func run(argsJSON: String) async -> String {
        let args = obj(argsJSON)
        let oppId = ((args["shift_opportunity_id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        // Estricto a propósito: solo un booleano nativo `true` confirma. Una confirmación no debe
        // convertirse en `true` porque una cadena sea «verdadera»; con `"true"` falla hacia el
        // lado SEGURO (no acepta ni renuncia al turno y se vuelve a pedir la confirmación).
        let confirmed = (args["confirmed"] as? Bool) ?? false

        guard !oppId.isEmpty else {
            return "Se requiere el identificador de la oportunidad (shift_opportunity_id)."
        }

        await MainActor.run {
            ToolActivityRelay.shared.started(name: Self.name, args: "ID: \(oppId), confirmed: \(confirmed)")
        }

        let result: String = await {
            do {
                let outcome = try await AtoZClient.shared.requestDropShift(opportunityId: oppId, confirmed: confirmed)
                switch outcome {
                case .confirmationRequired(let prompt):
                    return prompt
                case .dryRun(let desc):
                    return desc
                case .confirmed(let opp):
                    return "¡Turno soltado (drop) y verificado en tu horario exitosamente! (\(AtoZFormat.describe(opp)))"
                case .unknownOutcome(let opp, let reason):
                    return "Resultado incierto al soltar el turno (\(AtoZFormat.describe(opp))): \(reason). Por seguridad no se reintentará automáticamente; por favor verifica tu aplicación A to Z."
                case .failed(let failure):
                    return failure.userMessage
                }
            } catch let failure as AtoZFailure {
                return failure.userMessage
            } catch {
                return "Error al soltar turno: \(error.localizedDescription)"
            }
        }()

        await MainActor.run {
            ToolActivityRelay.shared.finished(name: Self.name, result: result)
        }
        return result
    }
}
