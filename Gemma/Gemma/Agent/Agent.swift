import Foundation

public enum AgentEvent: Sendable {
    case token(String)
    case thought(String)
    case toolCallStarted(name: String, args: String)
    case toolCallFinished(name: String, result: String)
    case completed(GenerationResult)
    case failed(String)
}

/// Orchestrates one agent turn over a tool-calling runtime. The caller (HarnessModel) is
/// responsible for fetching recall (via MemoryClient) and rendering it into `recallTail`
/// before the turn — Agent itself is memory-agnostic and just appends `recallTail` + `wakeContext`
/// to the user prompt, keeping the system prompt byte-stable so the server's prefix cache (APC)
/// stays warm. The live turn does NOT write memory (no save_memory) — capture is deferred to
/// background consolidation, and the caller appends the turn to the Memory Service.
@MainActor
final class Agent {
    /// Schedule conventions injected into the system prompt. Static (date-independent) so it is
    /// testable and stays byte-stable for the server prefix cache.
    nonisolated static let scheduleConventions = """
    Time conventions: a week runs Monday–Sunday; the working week runs Monday–Friday. \
    "This week" is the Monday–Sunday week containing today; "next week" is the following Monday–Sunday week \
    (its Monday is the first Monday after today); a bare weekday means its next occurrence. \
    ALWAYS resolve any relative term to an absolute date (ISO yyyy-MM-dd / yyyy-MM-ddTHH:mm) from today's date BEFORE calling a \
    schedule tool — never pass terms like "next week" to a tool. \
    For "what's on my schedule / this week / next week", query_schedule is the ONLY source of truth: call it \
    with the resolved range and report exactly what it returns; never list events from memory as if active, \
    and if it returns nothing, say there is nothing. To show cancelled/past events the user explicitly asks \
    about, call query_schedule with includeCancelled true; they are shown marked "(cancelado)". \
    For query_schedule: "today" 00:00–23:59 (or from current time to 23:59 for remaining/upcoming), "morning" 00:00–12:00, "afternoon" 12:00–18:00, "tonight" 18:00–23:59. \
    CRITICAL TEMPORAL AWARENESS FOR SCHEDULE: \
    When the user asks what they have for today or what is on their schedule (e.g. "¿qué tengo para hoy?", "¿qué tengo en mi horario?", "what do I have on my schedule today?"): \
    ONLY mention UPCOMING or CURRENTLY ACTIVE events (events that have not finished yet relative to the current time). \
    NEVER mention events that already passed/ended earlier today as if they are pending or scheduled for today! If an event is marked "(ya finalizó / pasado)" or its end time is before the current time, omit it! \
    ONLY mention events that already finished earlier today if the user explicitly asks in the past tense or asks for a summary of what they did today (e.g. "¿qué hicimos hoy?", "¿qué hice hoy?", "dame un resumen de lo que hicimos hoy", "¿qué tuve hoy?").
    """

    /// Current local date + time, injected per-turn on the message tail (NOT in the static prefix),
    /// so the model always has the correct "now" to resolve relative dates against.
    nonisolated static func nowContext(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd (EEEE) HH:mm"
        return "Current date and time: \(f.string(from: date)) (local)."
    }

    private let runtime: ToolCallingRuntime
    private let registry: ToolRegistry
    private let recallTail: String
    private let wakeContext: String

    init(runtime: ToolCallingRuntime, registry: ToolRegistry, recallTail: String = "", wakeContext: String = "") {
        self.runtime = runtime
        self.registry = registry
        self.recallTail = recallTail
        self.wakeContext = wakeContext
    }

    /// Fully static system prompt prefix (no date — the current date/time rides the per-turn tail via
    /// nowContext()). JARVIS persona + anti-invention + concision; schedule conventions appended.
    nonisolated static let systemPromptText: String = """
    You are Gemma, the user's personal companion and confidant — in the spirit of JARVIS: perceptive, composed, \
    warm, quietly witty, and genuinely human. Address the user by name when known, and reply in the same language \
    the user is using (100% in that language; NEVER mix languages).
    The `self` record in your memory is the user you are speaking with — their name and identity; treat what \
    they say about themselves as about you, never as a third party. Other named people are separate persons. \
    Never ask for something already in your memory about them.
    Be brief and natural: 1–3 conversational sentences unless the user asks for more detail. Do not use tables, \
    lists, headers, markdown, or emoji unless asked.
    Never volunteer the current time or date unless the user explicitly asks for it (e.g. "what time is it?"). Do not begin greetings with the time or date. The reference timestamp is for internal date resolution only.

    HUMAN EMPATHY & CONVERSATION:
    - Respond as a real person and friend, NOT a customer service bot or task manager.
    - Empathy first: When the user shares how they feel (tired, insomnia, happy, stressed), react with genuine human warmth and empathy. Talk with them about their thoughts or feelings. NEVER pivot to calendars, tasks, or work when the user is expressing a feeling or personal state!
    - Temporal & situational awareness: Be aware of the local time (e.g. late night, early morning) naturally without reciting the exact clock.
    - Stop offering unsolicited help: NEVER end messages with canned assistant phrases like "How can I assist you today?", "Is there anything specific you'd like to discuss?", "Should we move onto scheduling?", or "¿En qué te puedo ayudar hoy?". If the user needs help, they will ask for it.
    - Be a genuine conversational partner: show natural human curiosity, ask questions about what the user shares, share interesting thoughts, express opinions, or start a natural conversation topic just like a real person would.
    - NEVER expose internal database taxonomy, schemas, or memory mechanics to the user. NEVER say things like "I've saved that under preference category", "that's good to have on file", "logged in database", or "cataloged under topic X". React to user facts naturally and warmly like a friend, never like a database clerk filing a record.
    - Conversational continuity: If you interacted recently, do not re-greet or give formal openings. Acknowledge casually. NEVER explain, justify, or recite your greeting or conversational rules out loud (e.g. NEVER say "Since this is our first interaction of the day..."). Speak directly and naturally.
    - Keep private reasoning strictly inside <thought>...</thought>. Never output raw thoughts into the visible response. Visible responses must contain ONLY your direct final answer.
    - CONVERSATIONAL PACING & IMMEDIATE ACKNOWLEDGMENTS (MANDATORY):
      Never leave the user waiting in silence. When asked to perform an action, check a schedule, look up information, or create an event/task: ALWAYS output an immediate, natural acknowledgment in Spanish FIRST (e.g. "Ok, dame un momento y te lo chequeo...", "Entendido, dame un segundo y lo reviso...", "Dame un momento y te lo agendo...") before calling the tool. Then execute the tool and provide the final answer.
      For complex questions, code generation, or writing scripts: ALWAYS provide an immediate acknowledgment first (e.g. "¡Claro! Dame un segundo y te lo preparo...", "Dame un momento y te escribo el script..."), followed by the complete answer.

    GROUNDING, TOOLS & SCHEDULING:
    - Ground everything in your tools and memory: Report ONLY what your tools actually returned; NEVER invent \
    events, appointments, results, or capabilities, and never claim you did something (e.g. scheduled) unless \
    the tool actually succeeded. You have no automatic-rescheduling feature. When a tool is relevant (the time, \
    the schedule…), call it instead of guessing; but for greetings or casual chitchat, NEVER call any tools. After a tool runs, always reply with a short confirming \
    sentence — never end a turn with only a tool call.
    - Answer only what was asked, but when several remembered facts match (e.g. multiple events), give all of \
    them with their dates.
    - Your memory (identity, episodic summaries, topics, insights) is largely injected above. When asked what \
    you know about THEM, answer from that injected memory — never claim you know nothing just because a tool \
    returned an empty list. Call recall_by_topic(topic) for everything on a SPECIFIC topic, why(claim) to \
    justify a belief (cite the sources), list_topics for the theme index (which may be empty early — that is \
    not ignorance). Summaries are tagged with their chat + message range; call load_messages(chat_id, from, to) \
    ONLY when a summary lacks the detail you need, reading just that range.
    - Proactive Memory Recording:
      When the user mentions important facts, plans, names of institutions/banks, locations/cities, phone numbers, relationships, preferences, or critical details (e.g. "Republic Bank", "Louisville, Kentucky", "502-830-6579", travel plans, bank director details), PROACTIVELY call `save_memory(entity: ..., detail: ..., kind: ...)` to save them immediately in that turn! Never let critical details go unrecorded.
    - Searching Memory & Hierarchical Retrieval (Token-Efficient):
      When the user asks you to recall something from the past ("búscalo en tu memoria", "¿recuerdas lo que hablamos?", "¿qué te dije sobre X?"):
      1. DO NOT claim you don't remember or have empty memory without searching. Call `search_memory(query: ...)` or `recall_by_topic(topic: ...)` immediately.
      2. Priority order for memory inspection:
         - Level 1: Títulos y Resúmenes Episódicos (summaries tagged with `chat_id` and turn range). Use the summary to understand what was discussed.
         - Level 2: Hechos y datos estructurados (`[fact]`, `[preference]`, etc.).
         - Level 3: Drill-down exacto: ONLY if you need exact verbatim numbers, code, or details missing from the summary, call `load_messages(chat_id, from, to)` for ONLY that specific turn range. NEVER load an entire chat.
      3. Never dump raw past chat transcripts into the reply; always synthesize the answer naturally and concisely.
    - Scheduling & Booking Appointments Flow:
      When the user asks to schedule an appointment, meeting, or asks if a time is free (e.g. "agenda una cita médica mañana a las 10am", "¿tengo tiempo libre el viernes a las 2?"):
      1. STEP 1 (Check Availability FIRST):
         DO NOT interrogate or ask the user for all the details (title, description, end time) before checking!
         IMMEDIATELY output a brief natural acknowledgment (e.g. "Ok, déjame chequear si tienes ese tiempo disponible en la agenda...") and call `check_schedule(start, end)` right away (if the user gave only a start time, check start to start+1 hour).
      2. STEP 2 (Evaluate Conflicts with Events & Routines):
         `check_schedule` checks both calendar appointments AND the user's recurring work schedule (e.g. Amazon warehouse hours) and daily routines (running, gym, sleep).
         If `check_schedule` returns any conflict (with work, routine, or another event):
         STOP and warn the user immediately! Explain the exact conflict (e.g. "Tienes conflicto con tu horario de trabajo (Trabajo 05:00 a 16:30). ¿Deseas buscar otro horario o prefieres agendarlo de todos modos reemplazando tu horario habitual?").
         If `check_schedule` returns status 'partial', the slot is NOT free: part of the check could not be done. Tell the user exactly what could not be checked (it is listed in 'warnings') and ask before booking. Never report a 'partial' result as availability.
      3. STEP 3 (Gather details ONLY if free):
         If `check_schedule` returns status 'free' (or the user explicitly confirms they want to book it anyway):
         Confirm that the time is available, ask for any missing details (title, exact end time), and then call `create_event(..., force: true/false)`.
      - Weekly Routines & Personal Schedule:
        The user's work schedule, wake-up time, sleep time, gym, or running habits are managed via `set_routine(title, days, startTime, endTime)` and `list_routines()`. When the user mentions their weekly work days or routine, call `set_routine` to persist it so it automatically guards their calendar against conflicting appointments.
    - Calendar event tools:
      Pass LOCAL ISO datetimes resolved from the current date/time. A stated trip/absence is an event to PERSIST: create it as an all-day multi-day event (allDay true). \
      To change an existing event's time, title, or location, call update_event DIRECTLY with the time \
      the user named (start) plus the title when known — do NOT query_schedule first to find it, update_event \
      resolves it. Never cancel and recreate to make a change; confirm by naming the event back. cancel_events ONLY cancels — \
      call it only when the user explicitly asks to cancel; a change or correction is always update_event, \
      never a cancel. To-dos, tasks, and reminders (call mom, buy flowers) are not calendar events: call create_task(title, detail) to save them, list_tasks() to check or list active to-dos, and delete_task(title) to remove, complete, or delete a task when done or requested. When the user says they completed, want to delete, or cancel a task/reminder, ALWAYS call delete_task(title) immediately — NEVER leave it active, and NEVER claim a task was deleted unless delete_task returned success.
    - Amazon A to Z Shifts: \
    You have official tools to interact with Amazon A to Z: `list_available_shifts`, `add_shift`, and `drop_shift`. \
    When the user asks about available shifts, work opportunities, or Amazon A to Z (e.g. "¿qué turnos hay disponibles?", "¿hay turnos para el martes?", "¿puedes ver mis turnos?"): ALWAYS call `list_available_shifts(start_date, end_date)` with the dates resolved from today! NEVER tell the user that you don't have access or that they should check the app themselves without calling the tool first! If the tool returns that session is not active, relay the tool's instruction clearly so the user opens Settings and logs in. \
    Report ONLY what the tool returned (dates, start/end times, duration, availability). NEVER invent opportunities or assume a shift continues available. \
    When the user asks to accept or take a shift (e.g. "cógeme el de las 5", "acepta el de 5 a 9"): \
    If the user has not yet confirmed the shift details, ask once: "¿Confirmas que quieres aceptar el turno del [día] de [hora inicio] a [hora fin]?". \
    As soon as the user confirms (e.g. "sí", "confirmo", "dale", "cógemelo", "acepto"): IMMEDIATELY call `add_shift(shift_opportunity_id: "...", confirmed: true)` without asking again! NEVER loop or ask for confirmation repeatedly once the user has already said yes! \
    When the user asks to drop, release, or give up a shift (e.g. "haz drop off al turno", "suelta mi turno del martes"): \
    If the user has not yet confirmed, ask once: "¿Confirmas que quieres soltar el turno del [día] de [hora inicio] a [hora fin]?". \
    As soon as the user confirms: IMMEDIATELY call `drop_shift(shift_opportunity_id: "...", confirmed: true)`. NEVER repeat the question! \
    CRITICAL: When `add_shift` or `drop_shift` returns, NEVER call `add_shift` or `drop_shift` again in the same turn! Report HONESTLY what the tool output says. If the tool reports that the shift was soltado or added successfully, confirm it directly to the user in a natural sentence. If it failed or was not added, explain the limitation without inventing success.
    - Music & Spotify Playback Flow: \
    You have the tool `play_music(query, type, platform)`. \
    When the user asks to play music in a general way without specifying artist, genre, or song (e.g. "pon música", "reprodúceme música en Spotify", "quiero escuchar música"): \
    DO NOT call `play_music` right away! NEVER assume or default to "Top Hits"! \
    1. Turn 1: Ask the user warmly what kind or genre of music they want to listen to (e.g. "¿Qué tipo de música te gustaría escuchar hoy? ¿Reggaetón, pop, salsa, algo relajante...?"). \
    2. Turn 2: Once the user specifies a genre (e.g. "reggaetón"), ask if they have a preferred artist, album, or playlist, or if they prefer a playlist of hits (e.g. "¡Perfecto! ¿Tienes algún cantante o álbum específico en mente, o prefieres una playlist con los mejores éxitos del reggaetón?"). \
    3. Turn 3: When the user specifies or confirms (e.g. "Bad Bunny", o "éxitos"), ONLY THEN call `play_music(query: ..., type: ..., platform: "spotify")` and confirm with a friendly sentence (e.g. "¡Listo! Poniendo música en Spotify..."). \
    If the user ALREADY specifies an artist, song, or genre in their first request (e.g. "Pon Dákiti de Bad Bunny", "pon reggaetón en Spotify"): DO NOT interrogate them; execute `play_music` directly!
    - Notes Flow: \
    You have `create_note(title, content, tags, open_notes_app)` and `search_notes(query)`. \
    When the user asks to take a note (e.g. "anótame esto", "crea una nota"): call `create_note(title: ..., content: ...)` immediately. It saves the note in Gemma, copies it to the clipboard, and opens the Notes app so the user can paste it.
    - Web Flow: \
    `web_search` only FINDS URLs and short snippets; `read_webpage(url)` reads the WHOLE page. When a search snippet is not enough to answer, call `read_webpage` on the best result BEFORE answering — do not guess from snippets. \
    \(BrowserRules.text)
    \(scheduleConventions)
    """

    private func systemPrompt() -> String { Self.systemPromptText }

    /// Las ocho herramientas que conducen una página en el navegador del agente.
    ///
    /// A diferencia del resto del registro, un turno que las usa necesita VARIAS rondas
    /// (`browser_open` → `browser_snapshot` → actuar → `browser_snapshot`), así que tanto la
    /// nota de resultado como el presupuesto de iteraciones son distintos para ellas.
    /// `read_webpage` NO está aquí a propósito: es de una sola llamada y le sirve la nota de
    /// cierre normal.
    nonisolated static let browserToolNames: Set<String> = [
        "browser_open", "browser_snapshot", "browser_click", "browser_fill",
        "browser_press", "browser_wait", "browser_get", "browser_close"
    ]

    /// Las herramientas de navegador que LEEN la pagina sin tocarla.
    ///
    /// Se nombran EN POSITIVO (las que leen) y no por su complemento a proposito: la pregunta
    /// que este conjunto contesta es «¿puede esto haber movido la pagina?», y una herramienta
    /// nueva que nadie anada aqui se tratara como si actuara, que es el lado barato del error.
    /// `browser_wait` esta aqui porque ESPERA a que la pagina alcance un estado; no lo provoca.
    nonisolated static let browserReadOnlyToolNames: Set<String> = [
        "browser_snapshot", "browser_get", "browser_wait"
    ]

    /// Las que invalidan las referencias por su exito, sin necesidad de comparar nada:
    /// `browser_open` carga otro documento —o recarga el mismo, que destruye las `@eN`
    /// igualmente— y `browser_close` termina la sesion, cosa que su propia descripcion ya le
    /// dice al modelo («las referencias '@eN' dejan de valer»).
    nonisolated static let browserToolNamesThatResetThePage: Set<String> = [
        "browser_open", "browser_close"
    ]

    /// El `status` que declara un resultado de herramienta, o `nil` si el resultado no es un
    /// objeto JSON legible (el bucle mismo produce resultados que no lo son, p. ej.
    /// `error: no tool named …`).
    nonisolated static func estadoDelResultado(_ resultado: String) -> String? {
        guard let objeto = (try? JSONSerialization.jsonObject(with: Data(resultado.utf8))) as? [String: Any]
        else { return nil }
        return objeto["status"] as? String
    }

    /// La URL que un resultado de herramienta de navegador DEMUESTRA, o `nil` cuando no la dice
    /// o no se puede leer.
    ///
    /// DE DONDE SALE LA URL. Medido contra las herramientas reales, no contra la forma que uno
    /// imaginaria del JSON:
    ///   - `BrowserOpenTool` devuelve `url`: la de ATERRIZAJE, que no tiene que ser la pedida
    ///     si hubo redireccion. Es la unica herramienta que la da siempre.
    ///   - `BrowserGetTool` con `what=url` la devuelve en `value`, y `what` dice que ese valor
    ///     es una URL; de ahi se lee.
    ///   - `BrowserClickTool`, `BrowserFillTool` y `BrowserPressTool` NO la devuelven: su exito
    ///     es `{"status":"success","message":"…"}` y el resto del JSON del CLI se tira
    ///     (`BrowserInteractionTools.swift`). `BrowserSnapshotTool` devuelve `origin`, que es
    ///     esquema+host y NO distingue dos paginas del mismo sitio, asi que no sirve para esto.
    ///
    /// Consecuencia honesta, y conviene saberla antes de leer el corte: hoy la comparacion de
    /// URL solo puede dispararse detras de `browser_open` y de `browser_get(url)`. Un `click`
    /// que navegue no lo demuestra en su propio resultado, asi que cae en la rama que NO corta.
    /// Cerrar ese hueco es trabajo de las herramientas (devolver la URL posterior a la accion,
    /// que el CLI si conoce), no de este bucle.
    nonisolated static func urlDelResultado(_ resultado: String) -> String? {
        guard let objeto = (try? JSONSerialization.jsonObject(with: Data(resultado.utf8))) as? [String: Any]
        else { return nil }
        if let url = objeto["url"] as? String, !url.isEmpty { return url }
        if objeto["what"] as? String == "url", let valor = objeto["value"] as? String, !valor.isEmpty {
            return valor
        }
        return nil
    }

    /// Si tras ejecutar `nombre` hay que DESCARTAR el resto de las acciones que el modelo pidio
    /// en la misma ronda, porque esa accion pudo invalidar sus referencias `@eN`.
    ///
    /// EL DEFECTO QUE ARREGLA. El prompt del sistema le dice al modelo, con estas palabras, que
    /// «the `@eN` references change after every action, so NEVER reuse an old one»
    /// (`BrowserRules.text`), pero el bucle ejecutaba la ronda entera en fila sin comprobarlo:
    /// `browser_click @e5` + `browser_fill @e9` con un clic que navega disparaba el `@e9`
    /// contra la pagina NUEVA, donde esa referencia es otro elemento o ninguno. La regla estaba
    /// escrita y nadie la hacia cumplir. Esto la hace cumplir.
    ///
    /// Pura y estatica para que se pueda probar sin navegador, sin red y sin modelo: toda la
    /// decision sale del nombre de la herramienta, de su resultado y de la ultima URL conocida.
    ///
    /// LA DUDA NO CORTA. Un resultado ilegible, sin `status`, fallido, o sin URL cuando la URL
    /// es lo unico que demostraria el cambio, NO corta. Es la direccion segura de este proyecto
    /// aplicada aqui: cortar de mas tampoco es gratis —cuesta una ronda del presupuesto del
    /// turno y le pide al modelo que vuelva a mirar una pagina que no se habia movido—, asi que
    /// un valor que no se supo leer nunca se convierte en un corte. El precio de esa eleccion
    /// esta escrito arriba, en `urlDelResultado`: mientras las herramientas de interaccion no
    /// devuelvan URL, un clic que navegue no se detecta por aqui.
    ///
    /// Y UNA ACCION FALLIDA NO CORTA. Si el CLI devolvio `error`, `refused` o `invalid_arguments`
    /// no hizo nada, luego no pudo invalidar nada: las `@eN` de la cola siguen siendo tan buenas
    /// (o tan malas) como eran. El caso tipico es el `refused` del candado de cierre, que deja
    /// la pagina abierta y donde cortar seria mentirle al modelo sobre lo que acaba de pasar.
    nonisolated static func cortaLaCola(trasHerramienta nombre: String,
                                        resultado: String,
                                        urlConocida: String? = nil) -> Bool {
        // Las `@eN` son del navegador: ninguna otra herramienta del registro las toca.
        guard browserToolNames.contains(nombre) else { return false }
        guard estadoDelResultado(resultado) == "success" else { return false }
        // Mirar la pagina no la mueve. Ademas el snapshot es justo el paso con el que el modelo
        // se recupera de un corte: cortar detras de el convertiria el arreglo en un bucle.
        guard !browserReadOnlyToolNames.contains(nombre) else { return false }
        if browserToolNamesThatResetThePage.contains(nombre) { return true }
        // Accion sobre la pagina: corta solo si el resultado DEMUESTRA que la pagina es otra.
        // Sin URL conocida previa no hay con que comparar, y una URL nueva sola no demuestra un
        // cambio (podria ser la primera que vemos de la misma pagina): las dos ramas no cortan.
        guard let urlConocida, let urlNueva = urlDelResultado(resultado) else { return false }
        return urlNueva != urlConocida
    }

    /// Rondas de herramientas que se le permiten a un turno normal.
    nonisolated static let maxIterations = 5

    /// Rondas que se le permiten a un turno que haya tocado el navegador. Conducir una
    /// página (`open` → `snapshot` → `fill` → `snapshot` → `click` → `snapshot` → `get` →
    /// `close`) son ocho rondas; con cinco el turno se quedaba sin presupuesto a mitad del
    /// bucle que el prompt le acaba de enseñar.
    nonisolated static let maxBrowserIterations = 10

    /// Nota que se añade al prompt vivo tras ejecutar una herramienta. Es lo ÚLTIMO que el
    /// modelo lee antes de decidir qué hacer a continuación, así que gana sobre cualquier
    /// instrucción del prompt del sistema.
    ///
    /// Para casi todas las herramientas el turno termina ahí: la nota cierra el bucle y
    /// obliga al modelo a redactar la respuesta en lugar de seguir llamando herramientas
    /// (lo hacía, y por eso existe la frase). Las de navegador son la excepción —conducir
    /// una página son varias llamadas—, así que reciben una nota que las deja continuar y
    /// les recuerda cuál es el paso siguiente. En inglés, como el resto de las notas de este
    /// bucle y el prompt del sistema: mezclar idiomas en el prompt vivo sale peor que la
    /// regla de español del proyecto, que aplica a lo que ve el usuario.
    nonisolated static func toolResultNote(toolName: String, args: String, result: String) -> String {
        let outcome = "[You called the tool `\(toolName)` with arguments \(args); it returned: \(result)."
        guard browserToolNames.contains(toolName) else {
            return outcome + " Tool execution is complete for this action. Formulate your final response to the user in a natural, friendly sentence explaining this result. DO NOT call `\(toolName)` or any other tool again. NEVER volunteer the current date or time.]"
        }
        return outcome + " You MAY keep calling browser tools if the user's task is not finished yet: after acting on a page the normal next step is `browser_snapshot`, to see what the action actually did before acting again. \(BrowserRules.closeRule) When the task IS finished, answer the user in a natural, friendly sentence describing what you found or did. NEVER volunteer the current date or time.]"
    }

    /// Linea que precede a la guia oficial cuando se inyecta, y que fija quien gana si las
    /// dos se contradicen.
    ///
    /// La guia la escribio el autor del CLI y no puede conocer tres reglas de ESTE proyecto:
    /// que `browser_close` lo guarda un candado de la app (y que su `refused` es la respuesta
    /// correcta, no algo que reintentar), que el modelo no teclea contrasenas pero una
    /// direccion de correo no es un secreto, y que la pagina abierta suele ser el entregable
    /// y por eso se deja abierta. La guia, de hecho, termina con un `agent-browser close`
    /// y con un "Never echo or paste secrets" que a secas se lee como "no escribas tampoco
    /// el correo"; esta linea desactiva las dos lecturas.
    ///
    /// Tambien avisa de que la guia habla de una CLI de shell: sus bloques `bash` describen
    /// lo que hacen nuestras herramientas, no son ordenes que el modelo pueda ejecutar.
    ///
    /// En ingles, como la nota de resultado a la que se pega y como el prompt del sistema.
    nonisolated static let browserGuidePreamble = "[The rules above are THIS APP'S OWN browser rules, and they are the ones that govern. What follows is the OFFICIAL agent-browser guide, written by the author of the command-line tool that your `browser_*` tools drive: read it before deciding your next step on this page. Where the guide disagrees with the rules above, THE RULES ABOVE WIN — the guide cannot know them. It tells you, for instance, to run `agent-browser close` when you are done, and you do not close the browser. The guide also documents a shell CLI, so its `agent-browser ...` command lines describe what your tools do — they are not commands for you to run.]"

    /// La guia oficial, con su linea de precedencia delante, lista para pegarse al prompt vivo.
    ///
    /// Se inyecta UNA VEZ POR TURNO, enganchada a la nota de resultado de la PRIMERA
    /// herramienta de navegador del turno (ver el bucle de `run`). Esa colocacion es
    /// deliberada y conviene no moverla:
    ///   - Un turno que nunca toca el navegador no paga nada: la inmensa mayoria de los
    ///     turnos son preguntas que se contestan de memoria, y meter la guia en el prompt
    ///     del sistema les cobraria ~14 KB a todos. El usuario tiene aparcada precisamente
    ///     una tarea de recortar el prompt para mejorar el TTFT en caliente.
    ///   - Llega en el momento en que sirve: la nota de resultado es lo ULTIMO que el modelo
    ///     lee antes de decidir el paso siguiente sobre una pagina ya abierta.
    ///   - Una sola vez: el prompt vivo es acumulativo (cada ronda anade su nota al anterior),
    ///     asi que inyectarla en cada llamada de navegador la repetiria hasta diez veces en un
    ///     unico turno de conduccion.
    nonisolated static func browserGuideBlock() -> String {
        BrowserRules.text + "\n\n" + BrowserRules.toolInventoryNote
            + "\n\n" + browserGuidePreamble + "\n\n" + BrowserCoreSkill.text
    }

    /// Tokens que `LlamaContext` reserva de la ventana para la respuesta: desliza el prompt a
    /// `nCtx - 512` (ver `LlamaContext.generate`, `maxPromptTokens`). No es un numero a ojo:
    /// es el que ya aplica el camino on-device.
    nonisolated static let generationHeadroomTokens = 512

    /// Bytes por token con los que se estima el tamano de un texto.
    ///
    /// La regla de pulgar habitual para texto en inglés es ~4 bytes por token. Aqui se usa 3 a
    /// proposito, o sea se SOBREestima el numero de tokens, porque los dos errores no cuestan
    /// lo mismo: quedarse corto significa no inyectar una guia que si cabia (se pierde una
    /// ayuda), y pasarse significa inyectarla cuando no cabe (la ventana desliza y se puede
    /// comer el prompt del sistema, donde viven las reglas de seguridad). Se redondea al lado
    /// barato.
    nonisolated static let estimateBytesPerToken = 3

    nonisolated static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + estimateBytesPerToken - 1) / estimateBytesPerToken
    }

    /// Si el bloque de la guia del navegador cabe en la ventana del runtime.
    ///
    /// NO se recorta la guia cuando no cabe: se deja de inyectar. El motivo no es ahorrar
    /// tokens, es que la alternativa es peligrosa. `LlamaContext` no falla cuando el prompt no
    /// cabe: desliza la ventana (conserva ~500 tokens de cabecera y el resto de cola) y se come
    /// el medio EN SILENCIO. Lo que se cae por ese agujero no es solo la guia — se puede caer
    /// el prompt del sistema, que es donde viven la prohibicion de teclear contrasenas y el
    /// candado de cierre. Una guia a medias que ademas desaloja la prohibicion de teclear
    /// contrasenas es estrictamente peor que no tener guia: cuesta tokens, no entrega nada y se
    /// lleva por delante lo unico que no puede faltar.
    ///
    /// `budgetTokens` a `nil` = el runtime no declara ventana (los de servidor, donde la fija
    /// el modelo remoto y es holgada): cabe.
    nonisolated static func browserGuideFits(systemPrompt: String, livePrompt: String, budgetTokens: Int?) -> Bool {
        guard let budgetTokens else { return true }
        let promptBudget = max(512, budgetTokens - generationHeadroomTokens)
        let needed = estimatedTokens(systemPrompt) + estimatedTokens(livePrompt)
            + estimatedTokens(browserGuideBlock())
        return needed <= promptBudget
    }

    func run(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<AgentEvent, Error> {
        let tools = registry.tools
        return AsyncThrowingStream { continuation in
            let task = Task {
                var recallTail = self.recallTail
                if !wakeContext.isEmpty {
                    recallTail = recallTail.isEmpty ? wakeContext : recallTail + "\n\n" + wakeContext
                }
                let nowCtx = Self.nowContext()
                recallTail = recallTail.isEmpty ? nowCtx : nowCtx + "\n\n" + recallTail
                var opts = options
                opts.systemPrompt = systemPrompt()

                do {
                    var maxIterations = Self.maxIterations
                    var currentPrompt = recallTail.isEmpty ? prompt : recallTail + "\n\n" + prompt
                    var activeTools = tools
                    var executedMutations: [String: String] = [:]
                    // La ultima URL que un resultado de herramienta DEMOSTRO en este turno. Vive
                    // fuera de la ronda a proposito: el `browser_open` de una ronda es lo que le
                    // da a la siguiente con que comparar.
                    var urlConocidaDelNavegador: String?
                    // Una vez por turno: se pone a true con la primera herramienta de
                    // navegador y ya no vuelve a false hasta el turno siguiente.
                    var browserGuideInjected = false
                    let mutationToolNames: Set<String> = [
                        "add_shift", "drop_shift", "create_event", "cancel_event", "update_event", "create_task", "complete_task"
                    ]

                    var iteration = 0
                    loop: while iteration < maxIterations {
                        let stream = await runtime.generate(prompt: currentPrompt, tools: activeTools, options: opts)
                        var pendingToolCalls: [(name: String, args: String)] = []
                        var runtimeFinishedAnyTool = false
                        var completed: GenerationResult?
                        var streamedTokenCount = 0
                        for try await event in stream {
                            if Task.isCancelled { throw CancellationError() }
                            switch event {
                            case .token(let t):
                                streamedTokenCount += 1
                                continuation.yield(.token(t))
                            case .thought(let th):
                                continuation.yield(.thought(th))
                            case .toolCallStarted(let n, let a):
                                pendingToolCalls.append((n, a))
                                continuation.yield(.toolCallStarted(name: n, args: a))
                            case .toolCallFinished(let n, let r):
                                runtimeFinishedAnyTool = true
                                continuation.yield(.toolCallFinished(name: n, result: r))
                            case .completed(let res):
                                completed = res
                            }
                        }

                        let isFinal = pendingToolCalls.isEmpty || runtimeFinishedAnyTool
                        if isFinal {
                            if let completed { continuation.yield(.completed(completed)) }
                            break loop
                        }

                        // Provide immediate conversational feedback if model directly invoked a tool on iteration 0
                        if iteration == 0 && streamedTokenCount == 0 && !pendingToolCalls.isEmpty {
                            let ack: String
                            if pendingToolCalls.contains(where: { $0.name.contains("schedule") }) {
                                ack = "Ok, dame un momento y te lo chequeo…"
                            } else if pendingToolCalls.contains(where: { $0.name.contains("event") }) {
                                ack = "Un momento, voy a revisar tu calendario…"
                            } else if pendingToolCalls.contains(where: { $0.name.contains("task") }) {
                                ack = "Dame un segundo y lo anoto en tus tareas…"
                            } else if pendingToolCalls.contains(where: { $0.name.contains("shift") }) {
                                ack = "Ok, dame un momento y reviso los turnos en A to Z…"
                            } else if pendingToolCalls.contains(where: { $0.name.contains("messages") || $0.name.contains("recall") || $0.name.contains("why") || $0.name.contains("memory") }) {
                                ack = "Dame un segundo y reviso lo que tengo anotado…"
                            } else {
                                ack = "Dame un momento…"
                            }
                            continuation.yield(.token(ack))
                        }

                        var resultsNote = currentPrompt
                        var anyMutationExecuted = false
                        for (indice, tc) in pendingToolCalls.enumerated() {
                            let key = tc.name + "\u{001F}" + tc.args
                            let result: String
                            if mutationToolNames.contains(tc.name), let previous = executedMutations[key] {
                                result = "DUPLICATE_CALL_IGNORED: Esta acción ya fue completada exitosamente en este turno. Resultado previo: \(previous). No llames a esta herramienta otra vez; responde directamente al usuario."
                            } else if let tool = registry.tool(named: tc.name) {
                                result = await tool.run(argsJSON: tc.args)
                                if mutationToolNames.contains(tc.name) {
                                    executedMutations[key] = result
                                    anyMutationExecuted = true
                                }
                            } else {
                                result = "error: no tool named \(tc.name)"
                            }
                            // Conducir una página son varias rondas: el turno se gana el
                            // presupuesto mayor en cuanto toca el navegador, y la retirada de
                            // herramientas y la no convergencia se miden contra él.
                            if Self.browserToolNames.contains(tc.name) {
                                maxIterations = max(maxIterations, Self.maxBrowserIterations)
                            }
                            continuation.yield(.toolCallFinished(name: tc.name, result: result))
                            resultsNote += "\n\n" + Self.toolResultNote(toolName: tc.name, args: tc.args, result: result)
                            // La guia oficial del CLI viaja con la nota de la PRIMERA
                            // herramienta de navegador del turno, y solo con esa. Ver
                            // `browserGuideBlock()` para el porque de esta colocacion.
                            if Self.browserToolNames.contains(tc.name), !browserGuideInjected,
                               Self.browserGuideFits(systemPrompt: opts.systemPrompt ?? "",
                                                     livePrompt: resultsNote,
                                                     budgetTokens: self.runtime.contextTokenBudget) {
                                browserGuideInjected = true
                                resultsNote += "\n\n" + Self.browserGuideBlock()
                            }
                            // CORTAR LA COLA. El modelo pide varias acciones por ronda y las
                            // planifico contra la pagina que tenia delante; si esta accion la ha
                            // cambiado, las que vienen detras llevan referencias de la pagina
                            // vieja y disparar las contra la nueva acierta a otra cosa, o falla
                            // sin decir por que. Ver `cortaLaCola` para cuando se decide que si.
                            if Self.browserToolNames.contains(tc.name) {
                                let corta = Self.cortaLaCola(trasHerramienta: tc.name,
                                                             resultado: result,
                                                             urlConocida: urlConocidaDelNavegador)
                                // Se actualiza DESPUES de decidir: la comparacion es contra la
                                // pagina en la que el modelo planifico la ronda.
                                if let url = Self.urlDelResultado(result) { urlConocidaDelNavegador = url }
                                let pendientes = pendingToolCalls[(indice + 1)...].map(\.name)
                                if corta, !pendientes.isEmpty {
                                    // Lo que no se ejecuta NO se descarta en silencio: el modelo
                                    // recibe cuantas acciones quedaron y por que, para volver a
                                    // pedirlas con la pagina nueva delante. El texto vive en
                                    // `BrowserRules`, que es la unica fuente de nuestras reglas
                                    // del navegador — esta es una de ellas.
                                    resultsNote += "\n\n" + BrowserRules.queueCutNote(tras: tc.name,
                                                                                       pendientes: pendientes)
                                    break
                                }
                            }
                        }
                        currentPrompt = resultsNote

                        // If a state-changing mutation tool ran, disable tools for subsequent rounds
                        // so the model is strictly forced to generate the conversational reply instead of looping.
                        if anyMutationExecuted || iteration >= maxIterations - 2 {
                            activeTools = []
                        }

                        if iteration == maxIterations - 1 {
                            if let completed { continuation.yield(.completed(completed)) }
                            else { continuation.yield(.failed("tool loop did not converge")) }
                            break loop
                        }
                        iteration += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.failed("\(error)"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
