import Foundation

/// Interpretación de las fechas que escribe el modelo.
///
/// Estaba duplicada (y con una variante rota) en los cuatro tools de calendario.
///
/// ## Por qué es tolerante
///
/// El modelo recibe la hora local en el prompt y escribe la fecha de muchas formas
/// razonables: con zona y sin ella, con segundos y sin ellos, con "T" o con un espacio.
/// Aceptar solo la forma canónica hacía que `create_reminder` contestara "Formato de
/// fecha inválido" ante una fecha perfectamente clara, y el usuario tenía que repetir la
/// petición sin saber por qué.
///
/// Lo que no se hace es adivinar: una fecha **sin hora** se devuelve marcada como tal
/// (`hasTime == false`) para que quien la use pregunte la hora, en vez de poner un
/// recordatorio a medianoche por su cuenta.
enum ISO8601Dates {
    struct Parsed {
        let date: Date
        /// `false` si el texto traía solo la fecha, sin hora.
        let hasTime: Bool
    }

    /// Fecha tal cual, descartando si traía hora o no. Para quien ya sabe que la
    /// medianoche le sirve.
    static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        parseDetailed(text, timeZone: timeZone)?.date
    }

    static func parseDetailed(_ text: String, timeZone: TimeZone = .current) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. ISO8601 con zona explícita (Z o ±hh:mm). Es el único caso en que la zona
        //    del texto manda sobre la del usuario.
        let iso = ISO8601DateFormatter()
        for options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ] as [ISO8601DateFormatter.Options] {
            iso.formatOptions = options
            if let date = iso.date(from: trimmed) {
                return Parsed(date: date, hasTime: true)
            }
        }

        // 2. Sin zona: es la hora de donde está el usuario. El espacio en vez de la "T"
        //    y la falta de segundos son lo que más escribe el modelo.
        let withTime = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm"
        ]
        for format in withTime {
            if let date = fixedFormatter(format, timeZone).date(from: trimmed) {
                return Parsed(date: date, hasTime: true)
            }
        }

        // 3. Solo la fecha: vale, pero se marca para que el llamante pida la hora.
        if let date = fixedFormatter("yyyy-MM-dd", timeZone).date(from: trimmed) {
            return Parsed(date: date, hasTime: false)
        }
        return nil
    }

    private static func fixedFormatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        // Locale fijo: con el del usuario, un calendario no gregoriano (budista, por
        // ejemplo) interpretaría "2026" como otro año.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}

/// create_calendar_event — crea un evento en el calendario de Apple del usuario.
///
/// ## Lo que estaba roto
///
/// Usaba `ISO8601Dates.parse`, que descarta el `hasTime` de `parseDetailed`. Con una
/// fecha sin hora («el dentista el 10 de noviembre») se quedaba con la medianoche; como
/// el fin también era medianoche, creaba un evento de **cero minutos a las 00:00** y
/// contestaba `status: "created"`. El usuario acababa con un evento que no se parecía a
/// lo que pidió y Gemma le había dicho que estaba hecho. El comentario de `ISO8601Dates`
/// ya decía que una fecha sin hora se marca «para que quien la use pregunte la hora»:
/// este tool era el que no lo hacía. Tampoco comprobaba que el fin fuera posterior al
/// inicio, y sus errores de argumentos salían como `{"error": ...}`, sin el `status` que
/// su propia descripción le dice al modelo que lea.
public final class CreateCalendarEventTool: AgentTool, Sendable {
    public static let name = "create_calendar_event"
    public static let description = """
    Crea un nuevo evento en el calendario de Apple del usuario. Lee 'status': 'created' = \
    creado, ya se lo puedes confirmar; 'needs_time' = una de las fechas venía sin hora y \
    NO se creó nada — PREGÚNTALE al usuario a qué hora, no la pongas tú; \
    'invalid_range' = el fin no es posterior al inicio, así que el evento duraría cero o \
    menos; 'invalid_datetime' = una fecha no se entiende, mira 'received' y vuelve a \
    llamar; 'missing_fields' = faltan argumentos, mira 'required'; \
    'permission_required' = hay que conceder el acceso al calendario, pídeselo; \
    'error' = otro fallo, no digas que el evento quedó creado.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Título o resumen del evento", required: true),
        AgentToolParam(name: "start_date", type: .string, description: "Fecha y hora de inicio en formato ISO8601 (ej. 2026-11-05T14:00:00Z)", required: true),
        AgentToolParam(name: "end_date", type: .string, description: "Fecha y hora de finalización en formato ISO8601 (ej. 2026-11-05T15:00:00Z)", required: true),
        AgentToolParam(name: "location", type: .string, description: "Ubicación o lugar del evento", required: false),
        AgentToolParam(name: "notes", type: .string, description: "Notas o descripción adicional", required: false)
    ]

    private let service: AppleCalendarService

    public init(service: AppleCalendarService = AppleCalendarService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let dict = (argsJSON.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        } as? [String: Any]) ?? [:]

        let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startStr = (dict["start_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endStr = (dict["end_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Antes este camino devolvía `{"error": ...}`, sin `status`: el modelo recibía una
        // forma que no esperaba justo cuando algo había ido mal.
        var missing: [String] = []
        if title.isEmpty { missing.append("title") }
        if startStr.isEmpty { missing.append("start_date") }
        if endStr.isEmpty { missing.append("end_date") }
        guard missing.isEmpty else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": missing,
                "message": "Faltan estos argumentos: \(missing.joined(separator: ", ")). Pídele al usuario lo que falte; no te lo inventes."
            ])
        }

        guard let parsedStart = ISO8601Dates.parseDetailed(startStr) else {
            return ToolJSONOutput.object([
                "status": "invalid_datetime",
                "field": "start_date",
                "received": startStr,
                "message": "No se entiende «\(startStr)» como fecha y hora. Manda ISO8601, por ejemplo 2026-11-10T14:00."
            ])
        }
        guard let parsedEnd = ISO8601Dates.parseDetailed(endStr) else {
            return ToolJSONOutput.object([
                "status": "invalid_datetime",
                "field": "end_date",
                "received": endStr,
                "message": "No se entiende «\(endStr)» como fecha y hora. Manda ISO8601, por ejemplo 2026-11-10T15:00."
            ])
        }

        // El defecto principal: una fecha sin hora se resolvía a medianoche y el evento se
        // creaba igual. Una hora que el usuario no dijo no se elige por él.
        guard parsedStart.hasTime, parsedEnd.hasTime else {
            let sinHora = [parsedStart.hasTime ? nil : "start_date",
                           parsedEnd.hasTime ? nil : "end_date"].compactMap { $0 }
            return ToolJSONOutput.object([
                "status": "needs_time",
                "fields": sinHora,
                "received": ["start_date": startStr, "end_date": endStr],
                "message": "No se creó nada: \(sinHora.joined(separator: " y ")) llegó sin hora, y poner un evento a medianoche por tu cuenta no es lo que el usuario pidió. PREGÚNTALE a qué hora es y vuelve a llamar."
            ])
        }

        let start = parsedStart.date
        let end = parsedEnd.date
        guard end > start else {
            return ToolJSONOutput.object([
                "status": "invalid_range",
                "received": ["start_date": startStr, "end_date": endStr],
                "message": "No se creó nada: el fin no es posterior al inicio, así que el evento duraría cero minutos o menos. Si el usuario solo dijo cuándo empieza, PREGÚNTALE cuánto dura."
            ])
        }

        let location = dict["location"] as? String
        let notes = dict["notes"] as? String

        do {
            let event = try await service.createEvent(
                title: title,
                startDate: start,
                endDate: end,
                location: location,
                notes: notes
            )
            return ToolJSONOutput.object(["status": "created", "event": event.jsonObject])
        } catch {
            return CalendarToolFailure.json(error)
        }
    }
}
