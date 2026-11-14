import Foundation

/// Cancela una alarma o un temporizador que Gemma puso.
///
/// ## Por qué hace falta
///
/// Gemma podía poner alarmas y temporizadores y no podía quitarlos: `ClockService` solo
/// tenía creación y listas. "Pon una alarma a las 6" funcionaba; "quita la alarma de las
/// 6" no tenía respuesta posible, y como las alarmas de AlarmKit tampoco salen en la app
/// Reloj, al usuario le quedaba esperar a que sonara para pararla.
///
/// Resuelve por hora o por título porque eso es lo que dice el usuario: nadie cancela una
/// alarma por su UUID. Cuando hay más de una candidata pregunta en vez de elegir, porque
/// cancelar la alarma equivocada se descubre a la mañana siguiente.
public final class CancelAlarmTool: AgentTool, Sendable {
    public static let name = "cancel_alarm"
    public static let description = """
    Cancela una alarma o un temporizador que Gemma tenga puesto. Sirve para los dos: \
    pásale 'time' con la hora ('06:00') para una alarma, o 'title' con el nombre o la \
    etiqueta ('despertar', 'pasta') para cualquiera de los dos; 'id' si lo sacaste de \
    list_alarms. Con 'all': true cancela todo lo que haya puesto, y eso solo se hace si \
    el usuario lo pide claramente. Lee 'status': 'cancelled' = quitada de verdad, y \
    'kind' dice si era 'alarm' o 'timer'; 'was_not_scheduled' = el sistema ya no la \
    tenía (el usuario la paró antes) y solo se limpió la lista de Gemma, dilo así y no \
    te atribuyas la cancelación; 'ambiguous' = varias encajan, enséñale 'candidates' y \
    pregunta cuál; 'not_found' = no hay ninguna que encaje, no supongas que la \
    cancelaste; 'needs_criteria' = no mandaste ningún criterio, pregúntale cuál quiere \
    quitar; 'failed' = el sistema no pudo, y entonces la alarma SIGUE puesta. Si no \
    sabes qué alarmas hay, llama antes a list_alarms.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "time", type: .string, description: "Hora de la alarma a cancelar, formato 24h ('06:00', '18:30')", required: false),
        AgentToolParam(name: "title", type: .string, description: "Nombre de la alarma o etiqueta del temporizador ('despertar', 'pasta')", required: false),
        AgentToolParam(name: "id", type: .string, description: "Identificador exacto, tal como lo devuelve list_alarms", required: false),
        AgentToolParam(name: "all", type: .boolean, description: "true para cancelar todas las alarmas y temporizadores. Solo si el usuario lo pide explícitamente", required: false)
    ]

    /// Una candidata a cancelar, ya sea alarma o temporizador.
    private struct Candidate {
        let id: UUID
        let kind: String
        let label: String
        /// "06:00" para una alarma; los minutos restantes para un temporizador.
        let detail: String
    }

    private let clockService: ClockService

    public init(clockService: ClockService = ClockService()) {
        self.clockService = clockService
    }

    public func run(argsJSON: String) async -> String {
        let time = CreateNoteTool.parseString(named: "time", from: argsJSON)
        let title = CreateNoteTool.parseString(named: "title", from: argsJSON)
        let idText = CreateNoteTool.parseString(named: "id", from: argsJSON)
        let all = Self.parseBool(named: "all", from: argsJSON) ?? false

        let candidates = Self.candidates(of: clockService)

        if all {
            return await cancelEverything(candidates)
        }

        guard time != nil || title != nil || idText != nil else {
            return ToolJSONOutput.object([
                "status": "needs_criteria",
                "message": "Dime cuál cancelar: la hora ('06:00'), el nombre, o 'all' para todas. No se canceló nada.",
                "current": candidates.map { ["kind": $0.kind, "label": $0.label, "detail": $0.detail] }
            ])
        }

        let matches = Self.matching(candidates, id: idText, time: time, title: title)

        guard !matches.isEmpty else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "requested": idText ?? time ?? title,
                "current": candidates.map { ["kind": $0.kind, "label": $0.label, "detail": $0.detail] },
                "message": candidates.isEmpty
                    ? "Gemma no tiene ninguna alarma ni temporizador puesto."
                    : "No hay ninguna alarma ni temporizador que encaje con eso. En 'current' está lo que sí hay."
            ])
        }
        // Cancelar la alarma equivocada se descubre tarde, así que con duda se pregunta.
        guard matches.count == 1 else {
            return ToolJSONOutput.object([
                "status": "ambiguous",
                "requested": idText ?? time ?? title,
                "candidates": matches.prefix(8).map {
                    ["id": $0.id.uuidString, "kind": $0.kind, "label": $0.label, "detail": $0.detail]
                },
                "message": "Hay varias que encajan. Pregúntale al usuario cuál quiere cancelar; no se canceló ninguna."
            ])
        }

        return await cancel(matches[0])
    }

    private func cancel(_ candidate: Candidate) async -> String {
        do {
            let outcome = candidate.kind == "timer"
                ? try await clockService.cancelTimer(id: candidate.id)
                : try await clockService.cancelAlarm(id: candidate.id)

            switch outcome {
            case .cancelled:
                return ToolJSONOutput.object([
                    "status": "cancelled",
                    "kind": candidate.kind,
                    "label": candidate.label,
                    "detail": candidate.detail,
                    "message": candidate.kind == "timer"
                        ? "Temporizador «\(candidate.label)» cancelado."
                        : "Alarma de las \(candidate.detail) cancelada. Ya no va a sonar."
                ])
            case .wasNotScheduled:
                return ToolJSONOutput.object([
                    "status": "was_not_scheduled",
                    "kind": candidate.kind,
                    "label": candidate.label,
                    "detail": candidate.detail,
                    "message": "El sistema ya no la tenía puesta (el usuario la paró antes), así que no había nada que cancelar. Se quitó de la lista de Gemma."
                ])
            case .notFound:
                return ToolJSONOutput.object([
                    "status": "not_found",
                    "message": "Ya no estaba en la lista de Gemma."
                ])
            }
        } catch {
            return ToolJSONOutput.object([
                "status": "failed",
                "kind": candidate.kind,
                "label": candidate.label,
                "message": "No se pudo cancelar: \(error.localizedDescription). SIGUE puesta; dile al usuario que la pare desde la alarma cuando suene."
            ])
        }
    }

    private func cancelEverything(_ candidates: [Candidate]) async -> String {
        guard !candidates.isEmpty else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "message": "No había ninguna alarma ni temporizador puesto."
            ])
        }
        var cancelled = 0
        var failures: [String] = []
        for candidate in candidates {
            do {
                _ = candidate.kind == "timer"
                    ? try await clockService.cancelTimer(id: candidate.id)
                    : try await clockService.cancelAlarm(id: candidate.id)
                cancelled += 1
            } catch {
                failures.append("\(candidate.label): \(error.localizedDescription)")
            }
        }
        // Un fallo parcial se cuenta como parcial: decir "todas canceladas" cuando una
        // sigue puesta es justo lo que no se puede hacer con una alarma.
        return ToolJSONOutput.object([
            "status": failures.isEmpty ? "cancelled" : "partial",
            "cancelled_count": cancelled,
            "failures": failures.isEmpty ? nil : failures,
            "message": failures.isEmpty
                ? "Canceladas \(cancelled) en total. No queda ninguna puesta."
                : "Se cancelaron \(cancelled), pero \(failures.count) no se pudieron cancelar y SIGUEN puestas."
        ])
    }

    // MARK: - Resolución

    private static func candidates(of service: ClockService) -> [Candidate] {
        let alarms = service.listAlarms().map { alarm in
            Candidate(
                id: alarm.id,
                kind: "alarm",
                label: alarm.title,
                detail: String(format: "%02d:%02d", alarm.hour, alarm.minute)
            )
        }
        let timers = service.listTimers().map { timer in
            Candidate(
                id: timer.id,
                kind: "timer",
                label: timer.label.isEmpty ? "Temporizador" : timer.label,
                detail: "\(max(0, timer.durationSeconds / 60)) min"
            )
        }
        return alarms + timers
    }

    private static func matching(
        _ candidates: [Candidate],
        id: String?,
        time: String?,
        title: String?
    ) -> [Candidate] {
        // El id es exacto: si viene y encaja, no hay nada más que considerar.
        if let id, let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespaces)) {
            return candidates.filter { $0.id == uuid }
        }
        if let time, let normalized = normalizeTime(time) {
            let byTime = candidates.filter { $0.kind == "alarm" && $0.detail == normalized }
            if !byTime.isEmpty { return byTime }
        }
        if let title {
            let needle = fold(title)
            guard !needle.isEmpty else { return [] }
            return candidates.filter { fold($0.label).contains(needle) || needle.contains(fold($0.label)) }
        }
        return []
    }

    /// Acepta "6:00", "06:00", "6" y "0600": un modelo pequeño escribe la hora de varias
    /// formas, y rechazarlas obligaría al usuario a repetirse.
    static func normalizeTime(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        let hour: Int?
        let minute: Int
        if parts.count == 2 {
            hour = Int(parts[0])
            minute = Int(parts[1]) ?? 0
        } else {
            let digits = trimmed.filter(\.isNumber)
            switch digits.count {
            case 1, 2: hour = Int(digits); minute = 0
            case 3: hour = Int(digits.prefix(1)); minute = Int(digits.suffix(2)) ?? 0
            case 4: hour = Int(digits.prefix(2)); minute = Int(digits.suffix(2)) ?? 0
            default: return nil
            }
        }
        guard let hour, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseBool(named name: String, from argsJSON: String) -> Bool? {
        guard let data = argsJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return coerceBool(dict[name])
    }

    /// Convención única para argumentos booleanos: acepta el `true`/`false` nativo y su forma
    /// en cadena. Existe porque el formato `<parameter name="k">v</parameter>` (que el parser
    /// acepta desde 2026-11-08) entrega TODOS los valores como cadena, y una herramienta que
    /// solo mira `as? Bool` lee `"true"` como ausente y toma el valor por defecto en silencio.
    /// Una cadena irreconocible da `nil` (= «no dicho»), nunca un `true` por ser «verdadera».
    static func coerceBool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        // Un modelo pequeño manda "true" entre comillas con la misma facilidad.
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "sí", "si", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// Igual que `coerceBool` para números decimales (coordenadas, radios). Una cadena que no es
    /// un número finito da `nil`: el llamador decide su valor por defecto, no se inventa un 0.
    static func coerceDouble(_ value: Any?) -> Double? {
        if let value = value as? Double { return value.isFinite ? value : nil }
        if let text = value as? String {
            guard let d = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite else { return nil }
            return d
        }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        return nil
    }
}
