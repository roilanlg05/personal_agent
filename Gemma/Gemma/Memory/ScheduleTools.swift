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
    let now = Date().timeIntervalSince1970
    let pastSuffix = (e.end <= now && e.status != "cancelled") ? " (ya finalizó / pasado)" : ""
    return "\(e.title): \(ScheduleTime.human(fromEpoch: e.start))–\(ScheduleTime.human(fromEpoch: e.end))\(loc)\(scheduleStatusSuffix(e.status))\(pastSuffix)"
}

/// Las cuatro herramientas de agenda de SP1, migradas al contrato de honestidad.
///
/// SP1 existe para que Gemma no agende al usuario en un sitio mientras está de viaje en
/// otro. Su prueba de extremo a extremo falló el 2026-06-04 y las herramientas no tenían
/// ni una prueba propia. Lo que estaba roto:
///
/// 1. **Se afirmaba «libre» sin haber podido mirar.** La consulta de rutinas iba con
///    `try?`: si el servicio de memoria fallaba en ese paso, el error se tragaba y
///    `check_schedule` contestaba «No conflicts». El modelo le decía al usuario que tenía
///    ese rato libre cuando la verdad era «no pude comprobar tus rutinas». `create_event`
///    hacía lo mismo y además agendaba.
/// 2. **Solo se miraban los 50 nodos más nuevos.** Una rutina más antigua que esos 50
///    nodos era invisible y el conflicto no se detectaba nunca.
/// 3. **`query_schedule` se inventaba el rango.** Con `to <= from` lo reemplazaba en
///    silencio por `from + 24h` y enumeraba una ventana que nadie pidió.
/// 4. **`cancel_events` no entendía «hoy».** Interpretaba `to` sin `endOfDayIfDateOnly`,
///    así que `from: "2026-11-10", to: "2026-11-10"` era la ventana vacía 00:00–00:00: no
///    se cancelaba nada y se contestaba «Cancelled 0 event(s)». `query_schedule` sí lo
///    hacía bien, con lo que las dos no coincidían sobre qué es un día.
/// 5. **Se aceptaban eventos de duración cero.** Con fechas sin hora,
///    `start == end == medianoche`: se creaba un evento de cero minutos a las 00:00 y se
///    informaba como creado.
/// 6. **Nada de esto tenía `status`.** Devolvían prosa en inglés que el modelo tenía que
///    interpretar en vez de leer.
enum ScheduleToolSupport {

    /// Cuando la memoria no responde. Es un fallo de infraestructura, no una agenda
    /// vacía: si esto dijera `empty`, el modelo le contestaría al usuario «no tienes
    /// nada» cuando la verdad es «no lo sé».
    static func memoryUnavailable(_ action: String) -> String {
        ToolJSONOutput.object([
            "status": "memory_unavailable",
            "message": "La memoria de Gemma no está disponible ahora mismo, así que no se pudo \(action). Dile al usuario que NO se pudo consultar su agenda — no que no tenga nada."
        ])
    }

    static func row(_ e: MemoryClient.ScheduleEvent) -> [String: Any] {
        ([
            "id": e.id,
            "title": e.title,
            "start": ScheduleTime.iso(fromEpoch: e.start),
            "end": ScheduleTime.iso(fromEpoch: e.end),
            "all_day": e.allDay,
            "location": (e.location?.isEmpty == false) ? e.location : nil,
            "state": e.status ?? "scheduled",
            "past": e.end <= Date().timeIntervalSince1970
        ] as [String: Any?]).compactMapValues { $0 }
    }

    /// Lo que se pudo averiguar sobre las rutinas del usuario en un hueco.
    ///
    /// `warnings` no está vacío cuando la comprobación quedó a medias. Quien llame tiene
    /// que propagarlo: media comprobación no es una comprobación, y decir «libre» con un
    /// aviso dentro es la mentira que rompió la confianza del usuario.
    struct RoutineScan {
        let conflicts: [String]
        let warnings: [String]
        var isComplete: Bool { warnings.isEmpty }
    }

    /// Los kinds de nodo que pueden describir un horario habitual.
    ///
    /// `routine` es el bueno: lo deja `set_routine` con días y horas en forma de máquina.
    /// `fact` y `place` son el respaldo para lo que el usuario contó antes de que
    /// existiera `set_routine` y nunca se convirtió en rutina.
    static let routineKinds = ["routine", "fact", "place"]

    /// Cuántos nodos se piden de cada kind.
    ///
    /// Antes se pedían 50 nodos **sin filtrar por kind**, que es menos que los recuerdos
    /// de cualquier usuario real: las rutinas viejas no se comprobaban nunca y el
    /// conflicto no se detectaba. Filtrando por kind el presupuesto se gasta donde hace
    /// falta — un usuario con miles de recuerdos tiene un puñado de rutinas — y el aviso
    /// de «esto quedó a medias» solo salta cuando de verdad falta algo por mirar, no en
    /// cada llamada.
    static let routineScanLimit = 400

    static func scanRoutines(_ m: MemoryClient, start: Double, end: Double) async -> RoutineScan {
        // Las tres consultas van en paralelo: tres viajes de red concurrentes tardan lo
        // que el más lento, no la suma.
        async let routineNodes = fetchKind(m, kind: "routine")
        async let factNodes = fetchKind(m, kind: "fact")
        async let placeNodes = fetchKind(m, kind: "place")
        let results = [await routineNodes, await factNodes, await placeNodes]

        var nodes: [MemoryClient.Node] = []
        var seenIDs: Set<String> = []
        var warnings: [String] = []
        for result in results {
            switch result {
            case .success(let listed, let kind):
                // Un nodo tiene un solo kind, así que las tres consultas no deberían
                // devolver el mismo dos veces. Se deduplica igual: si alguna vez se
                // solaparan, el mismo horario se avisaría tres veces al usuario.
                for node in listed.nodes where !seenIDs.contains(node.id) {
                    seenIDs.insert(node.id)
                    nodes.append(node)
                }
                if listed.total > listed.nodes.count {
                    warnings.append(
                        "De los recuerdos de tipo '\(kind)' solo se revisaron \(listed.nodes.count) de \(listed.total), así que puede quedar algún horario sin comprobar."
                    )
                }
            case .failure(let kind, let message):
                // Antes este fallo iba con `try?` y desaparecía: el hueco se declaraba
                // libre sin haber mirado el horario habitual del usuario.
                warnings.append(
                    "No se pudieron leer los recuerdos de tipo '\(kind)' (\(message)), así que este hueco NO se comprobó del todo contra el horario habitual del usuario."
                )
            }
        }

        let conflicts = RoutineHelper.findRoutineConflicts(
            startEpoch: start, endEpoch: end, nodes: nodes
        )
        return RoutineScan(conflicts: conflicts, warnings: warnings)
    }

    private enum KindFetch {
        case success(MemoryClient.ListedNodes, String)
        case failure(String, String)
    }

    private static func fetchKind(_ m: MemoryClient, kind: String) async -> KindFetch {
        do {
            return .success(try await m.nodes(limit: routineScanLimit, offset: 0, kind: kind), kind)
        } catch {
            return .failure(kind, error.localizedDescription)
        }
    }
}

/// Lee un par inicio/fin de los argumentos y dice exactamente qué falló.
///
/// Devuelve el JSON de error ya construido, o el par de epochs. Nunca completa lo que
/// falta: si el modelo manda una fecha ilegible, se le dice con `received` en vez de
/// elegir una hora por él.
private enum ScheduleRange {
    case ok(start: Double, end: Double)
    case problem(String)

    /// - Parameter endOfDayIfDateOnly: una fecha suelta como fin significa el final de
    ///   ese día. `cancel_events` no lo hacía y por eso «cancela mis citas de hoy» con
    ///   fechas sin hora producía la ventana vacía 00:00–00:00.
    static func parse(_ o: [String: Any], startKey: String, endKey: String,
                      endOfDayIfDateOnly: Bool, requiredExtra: [String] = []) -> ScheduleRange {
        let rawStart = (o[startKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawEnd = (o[endKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var missing: [String] = requiredExtra.filter {
            ((o[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        if rawStart?.isEmpty != false { missing.append(startKey) }
        if rawEnd?.isEmpty != false { missing.append(endKey) }
        if !missing.isEmpty {
            return .problem(ToolJSONOutput.object([
                "status": "missing_fields",
                "required": missing,
                "message": "Faltan estos argumentos: \(missing.joined(separator: ", ")). Pide al usuario lo que falte; no te lo inventes."
            ]))
        }

        guard let start = ScheduleTime.epoch(fromISO: rawStart!, endOfDayIfDateOnly: false) else {
            return .problem(ToolJSONOutput.object([
                "status": "invalid_datetime",
                "field": startKey,
                "received": rawStart!,
                "message": "No se entiende «\(rawStart!)» como fecha y hora. Manda la fecha local en ISO, por ejemplo 2026-11-10T08:00."
            ]))
        }
        guard let end = ScheduleTime.epoch(fromISO: rawEnd!, endOfDayIfDateOnly: endOfDayIfDateOnly) else {
            return .problem(ToolJSONOutput.object([
                "status": "invalid_datetime",
                "field": endKey,
                "received": rawEnd!,
                "message": "No se entiende «\(rawEnd!)» como fecha y hora. Manda la fecha local en ISO, por ejemplo 2026-11-10T09:00."
            ]))
        }
        guard end > start else {
            return .problem(ToolJSONOutput.object([
                "status": "invalid_range",
                "received": ["\(startKey)": rawStart!, "\(endKey)": rawEnd!],
                "resolved": ["\(startKey)": ScheduleTime.iso(fromEpoch: start),
                             "\(endKey)": ScheduleTime.iso(fromEpoch: end)],
                "message": "El fin no es posterior al inicio, así que el rango está vacío. Si el usuario solo dio una hora de inicio, PREGÚNTALE cuándo acaba; no lo rellenes tú."
            ]))
        }
        return .ok(start: start, end: end)
    }
}

/// check_schedule — read-only: are there conflicts in [start,end)?
struct CheckScheduleTool: AgentTool {
    static let name = "check_schedule"
    static let description = """
    Comprueba si un hueco de tiempo choca con algo que el usuario ya tiene: otros eventos \
    de su agenda y también sus rutinas (su horario de trabajo, su hora de dormir). \
    Llámala ANTES de crear un evento. Pasa fechas locales en ISO, como 2026-11-10T08:00. \
    Lee 'status': 'free' = el hueco está libre y se comprobó TODO, puedes decírselo al \
    usuario; 'conflict' = choca, enséñale lo que viene en 'conflicts'; 'partial' = se \
    comprobó solo una parte (mira 'warnings') — NO digas que está libre, di exactamente \
    qué no se pudo comprobar; 'memory_unavailable' = la agenda no se pudo consultar, que \
    NO es lo mismo que estar libre; 'missing_fields', 'invalid_datetime' o 'invalid_range' \
    = arréglalo y vuelve a llamar.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "start", type: .string, description: "Local ISO datetime, e.g. 2026-06-09T08:00", required: true),
        AgentToolParam(name: "end", type: .string, description: "Local ISO datetime; the end of the slot.", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let s: Double, e: Double
        switch ScheduleRange.parse(o, startKey: "start", endKey: "end", endOfDayIfDateOnly: true) {
        case .problem(let json): return json
        case .ok(let start, let end): s = start; e = end
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(ScheduleTime.human(fromEpoch: s))–\(ScheduleTime.human(fromEpoch: e))") }
        let result: String = await {
            guard let m = await mem() else { return ScheduleToolSupport.memoryUnavailable("comprobar ese hueco") }

            var warnings: [String] = []
            var eventConflicts: [MemoryClient.ScheduleEvent] = []
            do {
                eventConflicts = try await m.checkSchedule(start: s, end: e)
            } catch {
                // El choque con otros eventos es la mitad importante de la comprobación.
                // Si esa consulta falla no se puede decir nada sobre el hueco.
                return ToolJSONOutput.object([
                    "status": "failed",
                    "message": "No se pudo comprobar la agenda del usuario: \(error.localizedDescription). NO le digas que tiene el hueco libre."
                ])
            }

            let scan = await ScheduleToolSupport.scanRoutines(m, start: s, end: e)
            warnings.append(contentsOf: scan.warnings)

            let conflicts: [Any] = eventConflicts.map { ScheduleToolSupport.row($0) }
                + scan.conflicts.map { ["kind": "routine", "detail": $0] as [String: Any] }

            if !conflicts.isEmpty {
                return ToolJSONOutput.object([
                    "status": "conflict",
                    "from": ScheduleTime.iso(fromEpoch: s),
                    "to": ScheduleTime.iso(fromEpoch: e),
                    "conflicts": conflicts,
                    "warnings": warnings.isEmpty ? nil : warnings,
                    "message": "Ese hueco choca con \(conflicts.count) cosa(s). Dile al usuario con qué choca y pregúntale qué quiere hacer."
                ])
            }
            if !warnings.isEmpty {
                return ToolJSONOutput.object([
                    "status": "partial",
                    "from": ScheduleTime.iso(fromEpoch: s),
                    "to": ScheduleTime.iso(fromEpoch: e),
                    "conflicts": [],
                    "warnings": warnings,
                    "message": "No se encontró ningún choque en lo que SÍ se pudo comprobar, pero la comprobación quedó a medias. NO le digas al usuario que el hueco está libre: dile qué parte no se pudo comprobar."
                ])
            }
            return ToolJSONOutput.object([
                "status": "free",
                "from": ScheduleTime.iso(fromEpoch: s),
                "to": ScheduleTime.iso(fromEpoch: e),
                "conflicts": [],
                "message": "Ese hueco está libre: no choca con ningún evento ni con ninguna rutina del usuario."
            ])
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// create_event — books an event; refuses on conflict unless force=true.
struct CreateEventTool: AgentTool {
    static let name = "create_event"
    static let description = """
    Crea un evento con fecha en la agenda del usuario (una reunión, una cita, un viaje). \
    Pasa fechas locales en ISO. Si choca con algo que ya existe NO se crea, salvo que \
    mandes force=true: cuéntale el choque al usuario y pregúntale antes de forzar. \
    Lee 'status': 'created' = creado y comprobado, ya se lo puedes confirmar; \
    'created_with_warnings' = creado, pero mira 'warnings' porque parte de la \
    comprobación de choques no se pudo hacer — confirma que lo agendaste y di qué no se \
    pudo comprobar, nunca que no choca con nada; 'conflict' = NO se creó, enséñale \
    'conflicts' y pregunta si reprogramar, cancelar el otro, o agendarlo igual con \
    force=true; 'rejected' = el servidor no lo creó y no dijo con qué chocaba, no digas \
    que quedó agendado; 'missing_fields' = faltan argumentos; 'invalid_datetime' o \
    'invalid_range' = la fecha no se entiende o el rango está vacío (si el usuario solo \
    dio la hora de inicio, PREGÚNTALE cuándo acaba); 'memory_unavailable' o 'failed' = \
    no se guardó nada, dile al usuario que no quedó agendado.
    """
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
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let s: Double, e: Double
        switch ScheduleRange.parse(o, startKey: "start", endKey: "end",
                                   endOfDayIfDateOnly: true, requiredExtra: ["title"]) {
        case .problem(let json): return json
        case .ok(let start, let end): s = start; e = end
        }
        let allDay = CancelAlarmTool.coerceBool(o["allDay"]) ?? false
        let location = (o["location"] as? String)?.trimmingCharacters(in: .whitespaces)
        let force = CancelAlarmTool.coerceBool(o["force"]) ?? false
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title) }
        let result: String = await {
            guard let m = await mem() else { return ScheduleToolSupport.memoryUnavailable("agendar el evento") }

            var warnings: [String] = []
            if !force {
                let scan = await ScheduleToolSupport.scanRoutines(m, start: s, end: e)
                if !scan.conflicts.isEmpty {
                    return ToolJSONOutput.object([
                        "status": "conflict",
                        "title": title,
                        "conflicts": scan.conflicts.map { ["kind": "routine", "detail": $0] as [String: Any] },
                        "message": "NO se agendó: choca con el horario habitual del usuario. Avísale del choque y pregúntale si prefiere otra hora o agendarlo de todos modos por encima de su rutina (force=true)."
                    ])
                }
                // El fallo de la comprobación de rutinas no bloquea el agendado, pero sí
                // viaja con el resultado: el modelo no puede decir que no choca con nada.
                warnings.append(contentsOf: scan.warnings)
            }

            do {
                let r = try await m.createEvent(title: title, start: s, end: e, allDay: allDay,
                                                location: (location?.isEmpty == false) ? location : nil, force: force)
                if r.created {
                    return ToolJSONOutput.object([
                        "status": warnings.isEmpty ? "created" : "created_with_warnings",
                        "id": r.id,
                        "title": title,
                        "start": ScheduleTime.iso(fromEpoch: s),
                        "end": ScheduleTime.iso(fromEpoch: e),
                        "all_day": allDay,
                        "location": (location?.isEmpty == false) ? location : nil,
                        "warnings": warnings.isEmpty ? nil : warnings,
                        "message": warnings.isEmpty
                            ? "Agendado: \(title), \(ScheduleTime.human(fromEpoch: s))."
                            : "Agendado: \(title), \(ScheduleTime.human(fromEpoch: s)). Pero la comprobación de choques quedó a medias: dile qué no se pudo comprobar."
                    ])
                }
                guard !r.conflicts.isEmpty else {
                    // Rechazado sin decir con qué choca: lo único honesto es no afirmar
                    // que quedó agendado.
                    return ToolJSONOutput.object([
                        "status": "rejected",
                        "title": title,
                        "message": "El servidor no creó el evento y no dijo con qué chocaba. NO le digas al usuario que quedó agendado; ofrécele volver a intentarlo."
                    ])
                }
                return ToolJSONOutput.object([
                    "status": "conflict",
                    "title": title,
                    "conflicts": r.conflicts.map { ScheduleToolSupport.row($0) },
                    "message": "NO se agendó: choca con \(r.conflicts.count) evento(s) que ya existen. Pregúntale al usuario si reprogramar, cancelar el otro, o agendarlo igual — si lo confirma, vuelve a llamar con force=true."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "title": title,
                    "message": "No se pudo agendar el evento: \(error.localizedDescription). Dile al usuario que NO quedó agendado."
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// update_event — edit an existing event in place (time/title/location); never cancel+recreate.
struct UpdateEventTool: AgentTool {
    static let name = "update_event"
    static let description = "Edit an EXISTING calendar event in place — change its time, title, or location. Never cancel+recreate to make a change. Identify it by its CURRENT start (the time the user named) plus title when known."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "start", type: .string, description: "The event's CURRENT local ISO start (the time the user referred to), e.g. 2099-06-09T15:00.", required: true),
        AgentToolParam(name: "title", type: .string, description: "The event's current title, to disambiguate if several share that time.", required: false),
        AgentToolParam(name: "newStart", type: .string, description: "New local ISO start, if moving the event.", required: false),
        AgentToolParam(name: "newEnd", type: .string, description: "New local ISO end, if changing the end.", required: false),
        AgentToolParam(name: "newTitle", type: .string, description: "New title, if renaming.", required: false),
        AgentToolParam(name: "location", type: .string, description: "New place (empty string clears it).", required: false),
        AgentToolParam(name: "allDay", type: .boolean, description: "true/false to change all-day.", required: false),
        AgentToolParam(name: "force", type: .boolean, description: "true to apply despite a conflict with a DIFFERENT event (only after the user confirms).", required: false),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        guard let s = (o["start"] as? String).flatMap(ScheduleTime.epoch) else {
            return "Which event? Tell me the time of the event you want to change (e.g. 2099-06-09T15:00)."
        }
        let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespaces)
        let newStart = (o["newStart"] as? String).flatMap(ScheduleTime.epoch)
        let newEnd = (o["newEnd"] as? String).flatMap(ScheduleTime.epoch)
        let newTitle = (o["newTitle"] as? String)?.trimmingCharacters(in: .whitespaces)
        let location = o["location"] as? String
        let allDay = CancelAlarmTool.coerceBool(o["allDay"])
        let force = CancelAlarmTool.coerceBool(o["force"]) ?? false
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title ?? ScheduleTime.human(fromEpoch: s)) }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let r = try await m.updateEvent(start: s, title: (title?.isEmpty == false) ? title : nil,
                                                newStart: newStart, newEnd: newEnd,
                                                newTitle: (newTitle?.isEmpty == false) ? newTitle : nil,
                                                location: location, allDay: allDay, force: force)
                if r.notFound { return "I couldn't find that event — want me to check your schedule?" }
                if !r.ambiguous.isEmpty {
                    return "I found more than one event around then: " + r.ambiguous.map(eventLine).joined(separator: "; ") + ". Which one?"
                }
                if !r.updated {
                    return "NOT changed — the new time conflicts with: " + r.conflicts.map(eventLine).joined(separator: "; ")
                         + ". Ask the user whether to reschedule, cancel the other event, or keep it anyway — if they confirm, call update_event again with force=true."
                }
                if let e = r.event { return "Updated: \(eventLine(e))" }
                return "Updated the event."
            } catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// query_schedule — list events in a window.
struct QueryScheduleTool: AgentTool {
    static let name = "query_schedule"
    static let description = """
    Enumera los eventos del usuario en una ventana de fechas locales en ISO. Para los \
    ratos del día: la mañana es 00:00–12:00, la tarde 12:00–18:00, la noche 18:00–23:59, \
    el día entero 00:00–23:59. Para «lo que me queda hoy», pasa from=<hora actual> y \
    to=23:59. Pasa siempre fechas locales en ISO con la fecha de hoy; una fecha sin hora \
    como 'to' se toma como el final de ese día. Lee 'status': 'ok' = hay eventos, vienen \
    en 'events'; 'empty' = el usuario NO tiene nada agendado en esa ventana, dilo tal \
    cual; 'memory_unavailable' o 'failed' = la agenda no se pudo consultar, que NO es lo \
    mismo que estar vacía — dile que no pudiste mirar, no que no tiene nada; \
    'missing_fields' = falta el rango; 'invalid_datetime' o 'invalid_range' = la fecha no \
    se entiende o el fin no es posterior al inicio, arréglalo y vuelve a llamar.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "from", type: .string, description: "Local ISO datetime window start (e.g. 2026-11-03T00:00 or 2026-11-03T12:00).", required: true),
        AgentToolParam(name: "to", type: .string, description: "Local ISO datetime window end (e.g. 2026-11-03T12:00 or 2026-11-03T23:59). A bare date means the end of that day.", required: true),
        AgentToolParam(name: "includeCancelled", type: .boolean, description: "true to also list cancelled/past events (shown marked '(cancelado)'). Default false — the normal agenda excludes them.", required: false),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        // Antes, con `to <= from`, la ventana se reemplazaba en silencio por `from + 24h`:
        // la herramienta enumeraba un rango que el usuario nunca pidió.
        let f: Double, t: Double
        switch ScheduleRange.parse(o, startKey: "from", endKey: "to", endOfDayIfDateOnly: true) {
        case .problem(let json): return json
        case .ok(let start, let end): f = start; t = end
        }
        let includeCancelled = CancelAlarmTool.coerceBool(o["includeCancelled"]) ?? false
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(ScheduleTime.human(fromEpoch: f))–\(ScheduleTime.human(fromEpoch: t))") }
        let result: String = await {
            guard let m = await mem() else { return ScheduleToolSupport.memoryUnavailable("consultar la agenda") }
            do {
                let evs = try await m.scheduleWindow(from: f, to: t, includeCancelled: includeCancelled)
                return ToolJSONOutput.object([
                    "status": evs.isEmpty ? "empty" : "ok",
                    "from": ScheduleTime.iso(fromEpoch: f),
                    "to": ScheduleTime.iso(fromEpoch: t),
                    "count": evs.count,
                    "events": evs.map { ScheduleToolSupport.row($0) },
                    "message": evs.isEmpty
                        ? "El usuario no tiene nada agendado entre \(ScheduleTime.human(fromEpoch: f)) y \(ScheduleTime.human(fromEpoch: t))."
                        : "\(evs.count) evento(s) en esa ventana."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "from": ScheduleTime.iso(fromEpoch: f),
                    "to": ScheduleTime.iso(fromEpoch: t),
                    "message": "No se pudo consultar la agenda: \(error.localizedDescription). Dile al usuario que no pudiste mirar su agenda; NO le digas que no tiene nada."
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// cancel_events — soft-cancel events in a window (kept, not deleted).
struct CancelEventsTool: AgentTool {
    static let name = "cancel_events"
    static let description = """
    Cancela los eventos del usuario en una ventana de fechas locales en ISO («cancela mis \
    citas de esta semana»). Los eventos se conservan marcados como cancelados, no se \
    borran. Una fecha sin hora como 'to' se toma como el final de ese día, así que \
    from='2026-11-10' y to='2026-11-10' es el día completo. Lee 'status': 'cancelled' = \
    se cancelaron, 'cancelled_count' dice cuántos; 'nothing_to_cancel' = no había ningún \
    evento en esa ventana, así que NO cancelaste nada — dilo tal cual, no digas que \
    cancelaste sus citas; 'missing_fields' = falta el rango; 'invalid_datetime' o \
    'invalid_range' = la fecha no se entiende o el fin no es posterior al inicio; \
    'memory_unavailable' o 'failed' = no se canceló nada, dile que siguen en pie.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "from", type: .string, description: "Local ISO datetime/date window start.", required: true),
        AgentToolParam(name: "to", type: .string, description: "Local ISO datetime/date window end. A bare date means the end of that day.", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        // `endOfDayIfDateOnly: true` es el arreglo: antes `to` se quedaba en las 00:00 del
        // día pedido, la ventana salía vacía y «cancela mis citas de hoy» no cancelaba nada.
        let f: Double, t: Double
        switch ScheduleRange.parse(o, startKey: "from", endKey: "to", endOfDayIfDateOnly: true) {
        case .problem(let json): return json
        case .ok(let start, let end): f = start; t = end
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(ScheduleTime.human(fromEpoch: f))–\(ScheduleTime.human(fromEpoch: t))") }
        let result: String = await {
            guard let m = await mem() else { return ScheduleToolSupport.memoryUnavailable("cancelar los eventos") }
            do {
                let n = try await m.cancelEvents(ids: nil, from: f, to: t)
                return ToolJSONOutput.object([
                    "status": n > 0 ? "cancelled" : "nothing_to_cancel",
                    "cancelled_count": n,
                    "from": ScheduleTime.iso(fromEpoch: f),
                    "to": ScheduleTime.iso(fromEpoch: t),
                    "message": n > 0
                        ? "Cancelado(s) \(n) evento(s) entre \(ScheduleTime.human(fromEpoch: f)) y \(ScheduleTime.human(fromEpoch: t))."
                        : "No había ningún evento entre \(ScheduleTime.human(fromEpoch: f)) y \(ScheduleTime.human(fromEpoch: t)), así que no se canceló nada. Dile al usuario que no tenía nada ahí; no le digas que cancelaste sus citas."
                ])
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "from": ScheduleTime.iso(fromEpoch: f),
                    "to": ScheduleTime.iso(fromEpoch: t),
                    "message": "No se pudo cancelar: \(error.localizedDescription). Los eventos del usuario siguen en pie."
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
