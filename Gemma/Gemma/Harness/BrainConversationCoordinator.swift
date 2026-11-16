import BrainContract
import Foundation

/// UTF-8 byte upper bounds for native model input, plus explicit adapter framing.
@MainActor
struct NativeGenerationBudget {
    let contextTokens: Int
    let outputTokens: Int
    let systemTokens: Int
    let toolTokens: Int

    static let inputTooLarge = RuntimeError.generationFailed("El mensaje no cabe completo en la ventana del modelo.")

    init(contextTokens: Int, outputTokens: Int, system: String, tools: [AgentTool]) {
        self.contextTokens = contextTokens
        self.outputTokens = outputTokens
        self.systemTokens = system.utf8.count + 192
        if tools.isEmpty {
            self.toolTokens = 0
        } else {
            let specs = tools.map { type(of: $0).functionSpec }
            let bytes = try? JSONSerialization.data(withJSONObject: specs)
            self.toolTokens = (bytes?.count ?? contextTokens) + 360
        }
    }

    func canFit(prompt: String, history: [ChatMessage] = [], spareTokens: Int = 0) -> Bool {
        let capacity = contextTokens - outputTokens - systemTokens - toolTokens - spareTokens
        return prompt.utf8.count + history.reduce(0) { $0 + $1.content.utf8.count + 32 } <= capacity
    }

    func retainingRecent(_ history: [ChatMessage], prompt: String) -> [ChatMessage] {
        var remaining = contextTokens - outputTokens - systemTokens - toolTokens - prompt.utf8.count
        var recent = [ChatMessage]()
        for message in history.suffix(40).reversed() {
            let cost = message.content.utf8.count + 32
            guard cost <= remaining else { break }
            remaining -= cost
            recent.append(message)
        }
        return Array(recent.reversed())
    }

}

/// The client, thread and legacy index belong to one submitted turn and never change across awaits.
@MainActor
struct BrainConversationCoordinator {
    enum Persistence: Equatable {
        case committed
        case pending
        case legacy
        case local
    }

    fileprivate enum Route {
        case admitted(BrainTurnResult)
        case legacy
        case local
        case unavailable
    }

    struct PreparedTurn {
        fileprivate let coordinatorID: UUID
        fileprivate let route: Route
        fileprivate let completionOperationID: String
        fileprivate let prompt: String
        fileprivate let providerPrompt: String
        fileprivate let followUpPrompt: String
        fileprivate let barePrompt: String
        fileprivate let options: GenerationOptions
        fileprivate let registry: ToolRegistry
        fileprivate let toolScope: MemoryToolbox.TurnScope
        fileprivate let audit: ToolAudit

        var persistence: Persistence {
            if audit.pending { return .pending }
            switch route {
            case .admitted(let receipt): return receipt.completion.state == .committed ? .committed : .pending
            case .legacy: return .legacy
            case .local: return .local
            case .unavailable: return .pending
            }
        }

        func run(runtime: ToolCallingRuntime, bóveda: SecretVault? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
            if case .admitted(let receipt) = route, !receipt.reply.isEmpty {
                return AsyncThrowingStream { continuation in
                    let metrics = RuntimeMetrics(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0,
                                                 peakResidentMemoryBytes: 0, draftAcceptanceRate: nil)
                    continuation.yield(.completed(GenerationResult(text: receipt.reply, metrics: metrics)))
                    continuation.finish()
                }
            }
            let reportOutcome: ((BrainOutcomeStatus) async -> Void)?
            if case .admitted(let receipt) = route, let client = toolScope.client {
                reportOutcome = { status in
                    let outcome = BrainOutcome(id: UUID().uuidString, description: "", status: status,
                        recordedAt: Date().timeIntervalSince1970, evidenceIDs: receipt.completion.evidenceIDs)
                    // An already executed effect owns its receipt independently of UI cancellation.
                    let recorded = await Task { @MainActor in
                        await Self.record(outcome, turnID: receipt.turnID, client: client)
                    }.value
                    if !recorded {
                        audit.pending = true
                    }
                }
            } else {
                reportOutcome = nil
            }
            return Agent(runtime: runtime, registry: registry, memoryScope: toolScope,
                         reportOutcome: reportOutcome, preparedPrompt: providerPrompt, followUpPrompt: followUpPrompt,
                         barePrompt: barePrompt, bóveda: bóveda)
                .run(prompt: prompt, options: options)
        }

        private static func record(_ outcome: BrainOutcome, turnID: String, client: MemoryClient) async -> Bool {
            let request = BrainReportedOutcomeRequest(turnID: turnID, outcome: outcome)
            for attempt in 0...1 {
                do {
                    return try await client.recordOutcome(request) == outcome
                } catch {
                    if attempt != 0 || Task.isCancelled || !BrainConversationCoordinator.isRetryable(error) {
                        return false
                    }
                }
            }
            return false
        }
    }

    fileprivate final class ToolAudit { var pending = false }

    private let id: UUID
    private let client: MemoryClient?
    private let threadID: String
    private let transcriptIndex: Int

    init(client: MemoryClient?, threadID: String, transcriptIndex: Int, operationID: UUID? = nil) {
        self.id = operationID ?? UUID()
        self.client = client
        self.threadID = threadID
        self.transcriptIndex = transcriptIndex
    }

    func prepare(prompt: String, options: GenerationOptions, priorConversation: RecentConversation,
                 wakeContext: String, registry: ToolRegistry? = nil,
                 invalidateLocalHistory: @escaping () -> Void = {}) async throws -> PreparedTurn {
        try Task.checkCancellation()
        let registry = registry ?? ToolRegistry()
        let local = priorConversation.localHistory(threadID: threadID)
        let now = Agent.nowContext()
        let contextTokens = min(max(options.contextTokens ?? 4096, 1), 65_536)
        let compact = contextTokens <= 8192
        let basePrompt = Agent.providerPrompt(prompt, recall: "", wake: wakeContext, now: now)
        let minimumSystem = Agent.nativeSystemPrompt(tools: [], compact: compact)
        let maxOutput = contextTokens - minimumSystem.utf8.count - basePrompt.utf8.count - 192
        guard maxOutput > 0 else { throw NativeGenerationBudget.inputTooLarge }
        let priority = registry.prioritized(for: prompt, history: local)
        let requestedOutput = max(options.maxTokens, 1)
        let isConfirmation = ToolRegistry.isShortConfirmation(prompt)
        let groupSize = client == nil || isConfirmation ? 3 : 2
        // Small windows may need to trade output for a few related tools. With a larger
        // window, reserve the reply first and let the admission loop fit the tool schemas.
        let mainTools = compact ? Array(priority.prefix(groupSize)) : []
        let prioritySystem = Agent.nativeSystemPrompt(tools: mainTools, compact: compact)
        let fixed = NativeGenerationBudget(contextTokens: contextTokens, outputTokens: 0,
                                           system: prioritySystem, tools: mainTools)
        let localBytes = local.suffix(2).reduce(0) { $0 + $1.content.utf8.count + 32 }
        let projectCue = prompt.range(of: #"\b(project|proyecto|retomar|sigamos|continuemos|resume|continue)\b"#,
                                      options: [.regularExpression, .caseInsensitive]) != nil
        let crossChatCue = BrainConversationReference.refersToHistory(prompt)
        let calendarTools = [CheckScheduleTool.name, QueryScheduleTool.name, UpdateEventTool.name, CancelEventsTool.name]
        let calendarRequest = priority.first.map { calendarTools.contains(type(of: $0).name) } == true
        // Expand the recall allowance only within the space left by the prioritized tools.
        let recallRoom = contextTokens - fixed.systemTokens - fixed.toolTokens
            - basePrompt.utf8.count - min(requestedOutput, 192)
        let contextReserve = if client == nil { max(320, localBytes) }
            else if compact && projectCue && !calendarRequest { max(2400, localBytes) }
            else if crossChatCue { max(640, min(compact ? 1120 : 1600, recallRoom), localBytes) }
            else if contextTokens <= 8192 && priority.isEmpty { max(1536, localBytes) }
            else { max(640, localBytes) }
        let availableOutput = contextTokens - fixed.systemTokens - fixed.toolTokens - basePrompt.utf8.count - contextReserve
        let outputTokens = min(requestedOutput, max(1, availableOutput), maxOutput)
        var tools = [AgentTool]()
        for tool in priority {
            let candidate = tools + [tool]
            let system = Agent.nativeSystemPrompt(tools: candidate, compact: compact)
            let budget = NativeGenerationBudget(contextTokens: contextTokens, outputTokens: outputTokens,
                                                system: system, tools: candidate)
            if budget.canFit(prompt: basePrompt, spareTokens: contextReserve) { tools = candidate }
        }
        let system = Agent.nativeSystemPrompt(tools: tools, compact: compact)
        let budget = NativeGenerationBudget(contextTokens: contextTokens, outputTokens: outputTokens,
                                            system: system, tools: tools)
        let route: Route
        if let client {
            let request = try BrainTurnRequest(clientOperationID: id.uuidString, threadID: threadID,
                message: BrainMessageUnit(id: UUID().uuidString, speakerID: BrainIdentity.userID,
                                          text: prompt, observedAt: Date().timeIntervalSince1970, evidenceIDs: []),
                budget: .init(contextTokens: budget.contextTokens, outputTokens: budget.outputTokens,
                              systemTokens: budget.systemTokens, toolTokens: budget.toolTokens))
            route = try await admit(request, client: client)
        } else {
            route = .local
        }

        let toolClient: MemoryClient? = if case .unavailable = route { nil } else { client }
        if toolClient == nil {
            tools.removeAll { tool in
                !registry.independentToolNames.contains(type(of: tool).name)
            }
        }
        let deliveredSystem = Agent.nativeSystemPrompt(tools: tools, compact: compact)
        let deliveredBudget = NativeGenerationBudget(contextTokens: contextTokens, outputTokens: outputTokens,
                                                     system: deliveredSystem, tools: tools)
        var requestOptions = options
        requestOptions.contextTokens = contextTokens
        requestOptions.maxTokens = outputTokens
        requestOptions.systemPrompt = deliveredSystem
        var recallTail = ""
        var followUpRecall = ""
        var authorizedOriginalIDs: Set<String>? = []
        func fits(_ recall: String, _ history: [ChatMessage]) -> Bool {
            deliveredBudget.canFit(prompt: Agent.providerPrompt(prompt, recall: recall, wake: wakeContext, now: now),
                                   history: history)
        }
        var revision: Int64?
        switch route {
        case .admitted(let receipt):
            revision = receipt.context?.revision ?? receipt.completion.revision
            let delivery = Self.deliver(receipt, threadID: threadID, localHistory: local, fits: fits)
            requestOptions.history = delivery.history
            recallTail = delivery.recall
            followUpRecall = delivery.followUpRecall
            authorizedOriginalIDs = delivery.authorizedOriginalIDs
        case .legacy:
            let bundle = try? await client?.recall(query: prompt, threadId: threadID)
            try Task.checkCancellation()
            requestOptions.history = await priorConversation.history(threadID: threadID, client: client)
            let recall = bundle?.scopedToNativeThread(threadID).injectionBlock(includingRawOtherThreads: false) ?? ""
            if fits(recall, requestOptions.history) {
                recallTail = recall
                followUpRecall = recall
            }
            authorizedOriginalIDs = nil
        case .unavailable:
            requestOptions.history = local
            recallTail = Self.pendingGuidance
            followUpRecall = recallTail
        case .local:
            requestOptions.history = local
        }
        if !fits(recallTail, []) {
            recallTail = ""
            followUpRecall = ""
            authorizedOriginalIDs = []
        }
        let providerPrompt = Agent.providerPrompt(prompt, recall: recallTail, wake: wakeContext, now: now)
        let followUpPrompt = Agent.providerPrompt(prompt, recall: followUpRecall, wake: wakeContext, now: now)
        requestOptions.history = deliveredBudget.retainingRecent(requestOptions.history, prompt: providerPrompt)
        let frozenRegistry = ToolRegistry()
        for tool in tools { frozenRegistry.register(tool) }
        try Task.checkCancellation()
        let forgetTarget = ForgetTool.requestedTarget(in: prompt)
        let authorizedForgetID = forgetTarget.flatMap { target in authorizedOriginalIDs?.first { $0 == target } }
        return PreparedTurn(coordinatorID: id, route: route, completionOperationID: UUID().uuidString,
                            prompt: prompt, providerPrompt: providerPrompt, followUpPrompt: followUpPrompt,
                            barePrompt: basePrompt, options: requestOptions,
                            registry: frozenRegistry, toolScope: .init(client: toolClient, threadID: threadID,
                                authorizedOriginalIDs: authorizedOriginalIDs, revision: revision, authorizedForgetID: authorizedForgetID,
                                legacyForgetTarget: authorizedOriginalIDs == nil ? forgetTarget : nil,
                                erasure: .init(invalidate: invalidateLocalHistory)),
                            audit: ToolAudit())
    }

    private func admit(_ request: BrainTurnRequest, client: MemoryClient) async throws -> Route {
        for attempt in 0...1 {
            do {
                let response = try await client.beginTurn(request)
                try Task.checkCancellation()
                guard response.clientOperationID == request.clientOperationID,
                      !response.turnID.isEmpty, !response.completion.evidenceIDs.isEmpty else { return .unavailable }
                return .admitted(response)
            } catch {
                try Task.checkCancellation()
                if attempt == 0, case MemoryClient.ClientError.http(404, _) = error { return .legacy }
                if attempt != 0 || !Self.isRetryable(error) { return .unavailable }
            }
        }
        return .unavailable
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case MemoryClient.ClientError.http(let status, _) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        return error is URLError || error is MemoryClient.ClientError
    }

    func complete(_ prepared: PreparedTurn, assistantText: String) async -> Persistence {
        guard prepared.coordinatorID == id, !Task.isCancelled, let client else { return prepared.persistence }
        let hasAssistant = !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch prepared.route {
        case .admitted(let receipt):
            if !receipt.reply.isEmpty { return prepared.persistence }
            if hasAssistant {
                guard let request = try? BrainTurnCompletionRequest(clientOperationID: prepared.completionOperationID,
                    turnID: receipt.turnID, assistantText: assistantText, evidenceIDs: receipt.completion.evidenceIDs) else {
                    return .pending
                }
                for attempt in 0...1 {
                    do {
                        let response = try await client.recordAssistant(request)
                        guard response.clientOperationID == request.clientOperationID,
                              response.turnID == request.turnID, response.reply == assistantText,
                              response.completion.evidenceIDs == request.evidenceIDs else { return .pending }
                        if !Task.isCancelled { try? await client.consolidationTurnEnd(threadId: threadID) }
                        return response.completion.state == .committed && !prepared.audit.pending ? .committed : .pending
                    } catch {
                        if Task.isCancelled || attempt != 0 || !Self.isRetryable(error) { return .pending }
                    }
                }
            } else {
                try? await client.consolidationTurnEnd(threadId: threadID)
                return prepared.persistence
            }
            return .pending
        case .legacy:
            do {
                try await client.appendTranscript(threadId: threadID, role: "user", text: prepared.prompt,
                                                  turnIndex: transcriptIndex)
                try Task.checkCancellation()
                if hasAssistant {
                    try await client.appendTranscript(threadId: threadID, role: "assistant", text: assistantText,
                                                      turnIndex: transcriptIndex)
                }
                if !Task.isCancelled { try? await client.consolidationTurnEnd(threadId: threadID) }
                return .legacy
            } catch { return .pending }
        case .unavailable:
            return .pending
        case .local:
            return .local
        }
    }

    private static let pendingGuidance = "Memory changes for this turn are pending. Do not report them as saved."

    private static func deliver(_ receipt: BrainTurnResult, threadID: String,
                                localHistory: [ChatMessage], fits: (String, [ChatMessage]) -> Bool)
        -> (history: [ChatMessage], recall: String, followUpRecall: String, authorizedOriginalIDs: Set<String>) {
        let pending = receipt.completion.state == .pending
        guard let context = receipt.context else {
            let guidance = pending ? pendingGuidance : ""
            return (localHistory, guidance, guidance, [])
        }
        let currentIDs = Set(receipt.completion.evidenceIDs)
        let references = Dictionary(context.sourceReferences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let units = context.recentMessageUnits.compactMap { unit -> (id: String, message: ChatMessage)? in
            guard unit.evidenceIDs.contains(unit.id), currentIDs.isDisjoint(with: unit.evidenceIDs),
                  let reference = references[unit.id], reference.threadID == threadID,
                  reference.speakerID == unit.speakerID, !unit.text.isEmpty, seen.insert(unit.id).inserted else { return nil }
            switch (reference.sourceKind, unit.speakerID) {
            case (.userMessage, BrainIdentity.userID):
                return (unit.id, ChatMessage(role: .user, content: unit.text))
            case (.assistantMessage, BrainIdentity.agentID):
                return (unit.id, ChatMessage(role: .assistant, content: unit.text))
            default:
                return nil
            }
        }.suffix(40)
        let remote = units.map(\.message)
        let useRemote = remote.suffix(localHistory.count).compactMap(RecentConversation.bounded).elementsEqual(localHistory)
            && fits("", Array(remote.suffix(2)))
        let availableHistory = useRemote ? remote : localHistory

        let renderedCurrent = currentIDs.contains { id in
            let uses = context.sourceUses?[id] ?? []
            return uses.contains(.renderedQuote) || uses.contains(.renderedDetail)
        }
        let rendered = renderedCurrent ? "" : context.renderedContext
        let renderedIDs = context.exactCitationSourceReferences(includingRenderedContext: !rendered.isEmpty,
                                                                 forwardedRecentUnitIDs: []).map(\.id).sorted()
        func delivery(recentCount: Int, includeRendered: Bool) -> (recall: String, exact: Set<String>) {
            let forwarded = useRemote ? units.suffix(recentCount) : units.suffix(0)
            let exactRecent = Set(context.exactCitationSourceReferences(includingRenderedContext: false,
                                                                       forwardedRecentUnitIDs: Set(forwarded.map(\.id))).map(\.id))
            let exactRendered = includeRendered ? renderedIDs : []
            let recentCitations = forwarded.enumerated().compactMap { index, unit in
                exactRecent.contains(unit.id) ? "history message \(index + 1): \(unit.id)" : nil
            }
            let citationLines = recentCitations + exactRendered.map { "rendered context: \($0)" }
            let citations = citationLines.isEmpty ? "" : "Exact citation sources delivered:\n" + citationLines.joined(separator: "\n")
            let recall = [includeRendered ? rendered : "", citations, pending ? pendingGuidance : ""]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            return (recall, exactRecent.union(exactRendered))
        }
        let latestCount = min(2, availableHistory.count)
        let renderedWithLatest = delivery(recentCount: latestCount, includeRendered: true)
        let includeRendered = !rendered.isEmpty && fits(renderedWithLatest.recall, Array(availableHistory.suffix(latestCount)))
        var chosen = delivery(recentCount: 0, includeRendered: includeRendered)
        var history = [ChatMessage]()
        for count in 1..<(availableHistory.count + 1) {
            let candidate = delivery(recentCount: count, includeRendered: includeRendered)
            let candidateHistory = Array(availableHistory.suffix(count))
            guard fits(candidate.recall, candidateHistory) else { break }
            chosen = candidate
            history = candidateHistory
        }
        let eligible = chosen.exact.subtracting(currentIDs).filter { id in
            guard let reference = references[id], reference.threadID == threadID else { return false }
            return (reference.sourceKind == .userMessage && reference.speakerID == BrainIdentity.userID)
                || (reference.sourceKind == .assistantMessage && reference.speakerID == BrainIdentity.agentID)
        }
        return (history, chosen.recall, delivery(recentCount: 0, includeRendered: includeRendered).recall, eligible)
    }
}
