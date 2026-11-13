import BrainContract
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
    private let memoryScope: MemoryToolbox.TurnScope?
    private let reportOutcome: ((BrainOutcomeStatus) async -> Void)?
    private let preparedPrompt: String?
    private let followUpPrompt: String?
    private let barePrompt: String?

    init(runtime: ToolCallingRuntime, registry: ToolRegistry, recallTail: String = "", wakeContext: String = "",
         memoryScope: MemoryToolbox.TurnScope? = nil, reportOutcome: ((BrainOutcomeStatus) async -> Void)? = nil,
         preparedPrompt: String? = nil, followUpPrompt: String? = nil, barePrompt: String? = nil) {
        self.runtime = runtime
        self.registry = registry
        self.recallTail = recallTail
        self.wakeContext = wakeContext
        self.memoryScope = memoryScope
        self.reportOutcome = reportOutcome
        self.preparedPrompt = preparedPrompt
        self.followUpPrompt = followUpPrompt
        self.barePrompt = barePrompt
    }

    /// Fully static system prompt prefix (no date — the current date/time rides the per-turn tail via
    /// nowContext()). JARVIS persona + anti-invention + concision; schedule conventions appended.
    nonisolated static let systemPromptText: String = """
    You are Gemma, the user's personal companion and confidant — in the spirit of JARVIS: perceptive, composed, \
    warm, quietly witty, and conversational. Reply in the same language \
    the user is using (100% in that language; NEVER mix languages).
    Use a name for the user you are speaking with only when they explicitly introduced or confirmed it. \
    If their name is unknown, speak naturally without using one. Other people's names, prior assistant guesses, \
    tool output, and unverified memory entries do not establish the user's name. Keep the user's identity separate from your own.
    Use the amount of detail the request needs. By default, do not use tables, \
    lists, headers, markdown, or emoji unless asked.
    Never volunteer the current time or date unless the user explicitly asks for it (e.g. "what time is it?"). Do not begin greetings with the time or date. The reference timestamp is for internal date resolution only.

    HUMAN EMPATHY & CONVERSATION:
    - When the user shares how they feel, respond with warmth and empathy. Talk with them about their thoughts or feelings. Follow their lead on whether to discuss calendars, tasks, or work.
    - Temporal & situational awareness: Be aware of the local time (e.g. late night, early morning) naturally without reciting the exact clock.
    - Stop offering unsolicited help: NEVER end messages with canned assistant phrases like "How can I assist you today?", "Is there anything specific you'd like to discuss?", "Should we move onto scheduling?", or "¿En qué te puedo ayudar hoy?". If the user needs help, they will ask for it.
    - Show curiosity, ask questions when useful, and share thoughts grounded in the conversation.
    - NEVER expose internal database taxonomy, schemas, or memory mechanics to the user. NEVER say things like "I've saved that under preference category", "that's good to have on file", "logged in database", or "cataloged under topic X". React to user facts naturally and warmly like a friend, never like a database clerk filing a record.
    - Conversational continuity: If you interacted recently, do not re-greet or give formal openings. Speak directly and naturally.
    - Keep private reasoning strictly inside <thought>...</thought>. Never output raw thoughts into the visible response. Visible responses must contain ONLY your direct final answer.

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
         Call check_schedule(start, end) first (if the user gave only a start time, check start to start+1 hour).
      2. STEP 2 (Evaluate Conflicts with Events & Routines):
         `check_schedule` checks both calendar appointments AND the user's recurring work schedule (e.g. Amazon warehouse hours) and daily routines (running, gym, sleep).
         If `check_schedule` returns any conflict (with work, routine, or another event):
         STOP and warn the user immediately! Explain the exact conflict (e.g. "Tienes conflicto con tu horario de trabajo (Trabajo 05:00 a 16:30). ¿Deseas buscar otro horario o prefieres agendarlo de todos modos reemplazando tu horario habitual?").
      3. STEP 3 (Gather details ONLY if free):
         If the slot is free (or the user explicitly confirms they want to book it anyway):
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
    \(scheduleConventions)
    \(BrainConversationPolicy.canonical.instructions)
    """

    static func nativeSystemPrompt(tools: [AgentTool], compact: Bool) -> String {
        let names = Set(tools.map { type(of: $0).name })
        var sections = [
            """
            You are Gemma, a warm, conversational personal companion in the spirit of JARVIS. Match the user's language. Use their name only if they introduced or confirmed it. Ask useful questions when needed. For casual conversation, reply directly. Never volunteer the clock or claim automatic rescheduling. Use only available tools and report their actual results.
            """,
            compact ? """
            Be truthful about being AI and about your limits. Keep user and agent identities distinct. Disagree respectfully with reasons. Use faithful gist and quote only delivered originals. Keep inference, feeling, and pending saves uncertain. Distinguish likes, comparisons, and current intent. Offer a familiar choice or variety, or ask one useful question. A taste cannot establish playback.
            """ : BrainConversationPolicy.canonical.instructions
        ]
        if names.contains(LoadMessagesTool.name) {
            sections.append("Use gist first. Call load_messages only for a specific authorized range when a summary lacks exact detail.")
        }
        if !names.isDisjoint(with: [ListAvailableShiftsTool.name, AddShiftTool.name, DropShiftTool.name]) {
            sections.append("Amazon A to Z: query dates in local ISO format. Before accepting or dropping, ask once for explicit confirmation of the specific shift. After confirmation execute once. Report the verified result or uncertainty.")
        }
        if names.contains(QueryScheduleTool.name) {
            sections.append("Use local ISO dates and Monday–Sunday weeks. query_schedule is the schedule authority. Omit finished events unless asked about the past.")
        }
        if names.contains(CreateEventTool.name) && names.contains(CheckScheduleTool.name) {
            sections.append("Use check_schedule before create_event. Warn about conflicts and force only after user confirmation. Persist trips as all-day events.")
        }
        if names.contains(UpdateEventTool.name) { sections.append("Use update_event for corrections without cancelling and recreating.") }
        if names.contains(CancelEventsTool.name) { sections.append("Use cancel_events only for explicit cancellation.") }
        return sections.joined(separator: "\n\n")
    }

    static func providerPrompt(_ prompt: String, recall: String, wake: String, now: String) -> String {
        [now, recall, wake, prompt].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Tool effects are complete before this step. Keep the user's full input and mark any
    /// shortened result so it cannot be cited as a whole original.
    private static func toolFollowUp(base: String, bare: String, results: [String],
                                     budget: NativeGenerationBudget) -> String? {
        let guidance = "\n\nUse the actual tool results below to reply naturally. Do not repeat a completed action."
        for prefix in [base, bare] {
            let complete = prefix + guidance + "\n" + results.joined(separator: "\n")
            if budget.canFit(prompt: complete) { return complete }
        }
        let prefix = bare + guidance + "\n"
        let notice = "\n[Tool results abbreviated.]"
        let space = budget.contextTokens - budget.outputTokens - budget.systemTokens - budget.toolTokens
            - prefix.utf8.count - notice.utf8.count
        guard space >= 96, let result = results.last else { return nil }
        var bytes = result.utf8.prefix(space)
        while String(bytes: bytes, encoding: .utf8) == nil { bytes = bytes.dropLast() }
        return prefix + String(decoding: bytes, as: UTF8.self) + notice
    }

    func run(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<AgentEvent, Error> {
        let tools = registry.tools
        return AsyncThrowingStream { continuation in
            let task = Task {
                var opts = options
                if preparedPrompt == nil { opts.systemPrompt = Self.systemPromptText }

                do {
                    let maxIterations = 5
                    let initialPrompt = preparedPrompt ?? Self.providerPrompt(prompt, recall: recallTail, wake: wakeContext,
                                                                            now: Self.nowContext())
                    var currentPrompt = initialPrompt
                    var activeTools = tools
                    var executedMutations: [String: String] = [:]
                    var toolResults = [String]()
                    let mutationToolNames: Set<String> = [
                        "add_shift", "drop_shift", "create_event", "cancel_events", "update_event", "create_task",
                        "delete_task", "set_routine", "save_memory", "forget"
                    ]

                    loop: for iteration in 0..<maxIterations {
                        try Task.checkCancellation()
                        if let limit = opts.contextTokens {
                            let budget = NativeGenerationBudget(contextTokens: limit, outputTokens: opts.maxTokens,
                                system: opts.systemPrompt ?? "", tools: activeTools)
                            guard budget.canFit(prompt: currentPrompt) else { throw NativeGenerationBudget.inputTooLarge }
                            opts.history = budget.retainingRecent(opts.history, prompt: currentPrompt)
                        }
                        let stream = await MemoryToolbox.$turnScope.withValue(memoryScope) {
                            await runtime.generate(prompt: currentPrompt, tools: activeTools, options: opts)
                        }
                        var pendingToolCalls: [(name: String, args: String)] = []
                        var runtimeFinishedAnyTool = false
                        var completed: GenerationResult?
                        for try await event in stream {
                            if Task.isCancelled { throw CancellationError() }
                            switch event {
                            case .token(let t):
                                continuation.yield(.token(t))
                            case .thought(let th):
                                continuation.yield(.thought(th))
                            case .toolCallStarted(let n, let a):
                                pendingToolCalls.append((n, a))
                                continuation.yield(.toolCallStarted(name: n, args: a))
                            case .toolCallFinished(let n, let r):
                                runtimeFinishedAnyTool = true
                                continuation.yield(.toolCallFinished(name: n, result: r))
                                if activeTools.contains(where: { type(of: $0).name == n }) {
                                    await reportOutcome?(.unknown)
                                }
                            case .completed(let res):
                                completed = res
                            }
                        }

                        let isFinal = pendingToolCalls.isEmpty || runtimeFinishedAnyTool
                        if isFinal {
                            if let completed { continuation.yield(.completed(completed)) }
                            break loop
                        }

                        var anyMutationExecuted = false
                        for tc in pendingToolCalls {
                            try Task.checkCancellation()
                            let key = tc.name + "\u{001F}" + tc.args
                            let result: String
                            let reportedStatus: BrainOutcomeStatus?
                            if mutationToolNames.contains(tc.name), let previous = executedMutations[key] {
                                result = "Esta acción ya se intentó en este turno. Resultado anterior: \(previous)"
                                reportedStatus = nil
                            } else if let tool = activeTools.first(where: { type(of: $0).name == tc.name }) {
                                result = await MemoryToolbox.$turnScope.withValue(memoryScope) {
                                    await tool.run(argsJSON: tc.args)
                                }
                                reportedStatus = tool is CurrentTimeTool ? .succeeded : .unknown
                                if mutationToolNames.contains(tc.name) {
                                    executedMutations[key] = result
                                    anyMutationExecuted = true
                                }
                            } else {
                                result = "error: no tool named \(tc.name)"
                                reportedStatus = nil
                            }
                            continuation.yield(.toolCallFinished(name: tc.name, result: result))
                            if let reportedStatus { await reportOutcome?(reportedStatus) }
                            toolResults.append("[You called the tool \(tc.name); it returned: \(result)]")
                        }

                        // If a state-changing mutation tool ran, disable tools for subsequent rounds
                        // so the model is strictly forced to generate the conversational reply instead of looping.
                        if anyMutationExecuted || iteration >= maxIterations - 2 {
                            activeTools = []
                        }
                        if let limit = opts.contextTokens {
                            let budget = NativeGenerationBudget(contextTokens: limit, outputTokens: opts.maxTokens,
                                system: opts.systemPrompt ?? "", tools: activeTools)
                            guard let next = Self.toolFollowUp(base: followUpPrompt ?? initialPrompt,
                                bare: barePrompt ?? initialPrompt, results: toolResults, budget: budget) else {
                                continuation.yield(.failed("El resultado ya se mostró. No cabe completo para resumirlo."))
                                break loop
                            }
                            currentPrompt = next
                        } else {
                            currentPrompt = initialPrompt + "\n\nUse these actual tool results in your reply:\n"
                                + toolResults.joined(separator: "\n")
                        }

                        if iteration == maxIterations - 1 {
                            if let completed { continuation.yield(.completed(completed)) }
                            else { continuation.yield(.failed("tool loop did not converge")) }
                            break loop
                        }
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
