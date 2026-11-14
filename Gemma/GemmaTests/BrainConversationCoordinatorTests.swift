import BrainContract
import Foundation
import CryptoKit
import XCTest
@testable import Gemma

@MainActor
final class BrainConversationCoordinatorTests: XCTestCase {
    private final class RecordingRuntime: ToolCallingRuntime {
        struct Request {
            let prompt: String
            let options: GenerationOptions
            let tools: [String]
        }

        private(set) var requests: [Request] = []

        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions)
            async -> AsyncThrowingStream<GenerationEvent, Error> {
            requests.append(Request(prompt: prompt, options: options, tools: tools.map { type(of: $0).name }))
            return AsyncThrowingStream { continuation in
                let metrics = RuntimeMetrics(tokensGenerated: 1, elapsedSeconds: 0, timeToFirstTokenSeconds: 0,
                                             peakResidentMemoryBytes: 0, draftAcceptanceRate: nil)
                continuation.yield(.completed(GenerationResult(text: "Seguimos.", metrics: metrics)))
                continuation.finish()
            }
        }
    }

    private final class ToolThenFailureRuntime: ToolCallingRuntime {
        private let name: String
        private let arguments: String
        private(set) var prompts: [String] = []
        private(set) var histories: [[ChatMessage]] = []

        init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }

        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions)
            async -> AsyncThrowingStream<GenerationEvent, Error> {
            prompts.append(prompt)
            histories.append(options.history)
            let isFirst = prompts.count == 1
            return AsyncThrowingStream { continuation in
                if isFirst {
                    continuation.yield(.toolCallStarted(name: name, args: arguments))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: URLError(.cannotConnectToHost))
                }
            }
        }
    }

    private final class CountingTool: AgentTool {
        static let name = "counting_fixture"
        static let description = "Increment the synthetic execution counter."
        private(set) var executions = 0
        private let result: String
        var onExecuted: (() -> Void)?

        init(result: String = "Executed.") { self.result = result }

        func run(argsJSON: String) async -> String {
            executions += 1
            onExecuted?()
            return result
        }
    }

    private struct HTTPRequest {
        let path: String
        let body: [String: Any]
        let query: [String: String]
    }

    private final class HTTPJournal: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [HTTPRequest] = []

        var requests: [HTTPRequest] { lock.withLock { entries } }

        func record(_ request: URLRequest) -> (HTTPRequest, Int) {
            let body = Self.body(of: request)
            let queryItems = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            let query = Dictionary(queryItems.compactMap { item in item.value.map { (item.name, $0) } },
                                   uniquingKeysWith: { first, _ in first })
            let entry = HTTPRequest(path: request.url?.path ?? "", body: body, query: query)
            return lock.withLock {
                entries.append(entry)
                return (entry, entries.filter { $0.path == entry.path }.count)
            }
        }

        private static func body(of request: URLRequest) -> [String: Any] {
            var data = request.httpBody ?? Data()
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
    }

    private nonisolated static func response(_ json: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private nonisolated static func admission(operation: String, reply: String = "", context: [String: Any]? = nil,
                                               persistence: String = "committed") -> Data {
        var result: [String: Any] = [
            "clientOperationID": operation, "turnID": "admitted-turn", "reply": reply,
            "completion": ["state": persistence, "revision": 7, "evidenceIDs": ["current-input"]]
        ]
        if let context { result["context"] = context }
        return response(result)
    }

    private nonisolated static func bundle(prompt: String) -> [String: Any] {
        [
            "renderedContext": "Corrección vigente: el proyecto Lirio usa azul.\nContexto de apertura: se aprobó la maqueta.",
            "recentMessageUnits": [
                unit(id: "previous-reply", speaker: "self:agent", text: "La maqueta está lista."),
                unit(id: "shortened-input", speaker: "self:user", text: "Un recuerdo recortado."),
                unit(id: "current-input", speaker: "self:user", text: prompt)
            ],
            "sourceReferences": [
                source(id: "previous-reply", kind: "assistantMessage", speaker: "self:agent"),
                source(id: "shortened-input", kind: "userMessage", speaker: "self:user"),
                source(id: "current-input", kind: "userMessage", speaker: "self:user"),
                source(id: "omitted-original", kind: "userMessage", speaker: "self:user")
            ],
            "sourceUses": ["previous-reply": ["recentWhole"], "shortened-input": ["recentPrefix"],
                           "current-input": ["recentWhole"]],
            "revision": 7, "policyRevision": 1
        ]
    }

    private nonisolated static func unit(id: String, speaker: String, text: String) -> [String: Any] {
        ["id": id, "speakerID": speaker, "text": text, "observedAt": 12, "evidenceIDs": [id]]
    }

    private nonisolated static func source(id: String, kind: String, speaker: String) -> [String: Any] {
        ["id": id, "sourceKind": kind, "speakerID": speaker, "threadID": "new-connection",
         "observedAt": 12, "recordedAt": 12, "accessScope": "thread"]
    }

    func testFirstGenerationUsesCorrectedContextAndForwardsCurrentInputOnce() async throws {
        let input = "Sigamos con el proyecto Lirio en azul."
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            let operation = record.body["clientOperationID"] as? String ?? ""
            switch record.path {
            case "/v1/brain/turns/begin":
                return (200, Self.admission(operation: operation, context: Self.bundle(prompt: input)))
            case "/v1/brain/turns/complete":
                return (200, Self.admission(operation: operation, reply: "Seguimos."))
            case "/v1/consolidation/turn-end":
                return (200, Data())
            default:
                return (404, Data())
            }
        }
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: "new-connection", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: input, options: GenerationOptions(),
                                                     priorConversation: RecentConversation(), wakeContext: "")
        for try await _ in prepared.run(runtime: runtime) {}
        _ = await coordinator.complete(prepared, assistantText: "Seguimos.")

        let request = try XCTUnwrap(runtime.requests.first)
        XCTAssertEqual(runtime.requests.count, 1)
        XCTAssertTrue(request.prompt.contains("Corrección vigente: el proyecto Lirio usa azul."))
        XCTAssertTrue(request.prompt.contains("Contexto de apertura: se aprobó la maqueta."))
        XCTAssertEqual(request.prompt.components(separatedBy: input).count, 2)
        XCTAssertFalse(request.options.history.contains { $0.content == input })
        XCTAssertTrue(request.options.history.contains(.init(role: .assistant, content: "La maqueta está lista.")))
        XCTAssertTrue(request.prompt.contains("previous-reply"))
        XCTAssertFalse(request.prompt.contains("shortened-input"))
        XCTAssertFalse(request.prompt.contains("omitted-original"))

        let writes = journal.requests
        let admission = try XCTUnwrap(writes.first { $0.path == "/v1/brain/turns/begin" })
        let message = try XCTUnwrap(admission.body["message"] as? [String: Any])
        XCTAssertEqual(admission.body["threadID"] as? String, "new-connection")
        XCTAssertEqual(message["text"] as? String, input)
        XCTAssertEqual(message["speakerID"] as? String, "self:user")
        XCTAssertEqual(message["evidenceIDs"] as? [String], [])
        let completions = writes.filter { $0.path == "/v1/brain/turns/complete" }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.body["turnID"] as? String, "admitted-turn")
        XCTAssertEqual(completions.first?.body["evidenceIDs"] as? [String], ["current-input"])
        XCTAssertFalse(writes.contains { $0.path == "/v1/transcript/append" })
    }

    func testOlderServerUsesLocalHistoryAndWritesLegacyTurnsOnlyOnce() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            switch record.path {
            case "/v1/brain/turns/begin": return (404, Data())
            case "/v1/conversation/window":
                return (200, Self.response(["turns": []]))
            case "/v1/memory/recall":
                return (200, Self.response(["core": [], "recall": [
                    ["kind": "fact", "label": "Caja segura", "body": "La caja de repuesto es amarilla."],
                    ["kind": "fact", "label": "Foreign node", "body": "Private foreign node body",
                     "extra": #"{"scope":"thread","threadId":"foreign-chat"}"#],
                    ["kind": "fact", "label": "Malformed node", "body": "Private malformed scope body",
                     "extra": #"{"scope":["user"]}"#]
                ], "summaries": [
                    ["summaryId": "prior-summary", "chatId": "foreign-chat", "messageRange": [4, 5],
                     "text": "Private foreign summary body"],
                    ["summaryId": "same-thread-summary", "chatId": "older-server", "messageRange": [1, 2],
                     "text": "Una maqueta anterior quedó aprobada."]
                ], "recentTurns": [["role": "user", "text": "private other-chat fixture"]]]))
            default: return (200, Data())
            }
        }
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: "older-server", transcriptIndex: 3)
        let prior = ChatMessage(role: .user, content: "La puerta es azul.")
        var history = RecentConversation()
        history.start(threadID: "older-server")
        history.append(prior, threadID: "older-server")
        let input = "¿De qué color era la puerta?"
        let prepared = try await coordinator.prepare(prompt: input, options: GenerationOptions(),
                                                     priorConversation: history, wakeContext: "")
        for try await _ in prepared.run(runtime: runtime) {}
        _ = await coordinator.complete(prepared, assistantText: "Azul.")

        XCTAssertEqual(runtime.requests.first?.options.history, [prior])
        XCTAssertTrue(runtime.requests.first?.prompt.hasSuffix(input) == true)
        XCTAssertTrue(runtime.requests.first?.prompt.contains("Una maqueta anterior quedó aprobada.") == true)
        XCTAssertTrue(runtime.requests.first?.prompt.contains("La caja de repuesto es amarilla.") == true)
        XCTAssertFalse(runtime.requests.first?.prompt.contains("foreign-chat") == true)
        XCTAssertFalse(runtime.requests.first?.prompt.contains("Private foreign summary body") == true)
        XCTAssertFalse(runtime.requests.first?.prompt.contains("Private foreign node body") == true)
        XCTAssertFalse(runtime.requests.first?.prompt.contains("Private malformed scope body") == true)
        XCTAssertFalse(runtime.requests.first?.prompt.contains("private other-chat fixture") == true)
        let requests = journal.requests
        let legacy = requests.filter { $0.path == "/v1/transcript/append" }
        XCTAssertEqual(legacy.compactMap { $0.body["text"] as? String }, [input, "Azul."])
        XCTAssertEqual(legacy.compactMap { $0.body["turnIndex"] as? Int }, [3, 3])
        XCTAssertFalse(requests.contains { $0.path == "/v1/brain/turns/complete" })
    }

    func testAmbiguousAdmissionRetriesWithSameOperationAndKeepsLocalHistory() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, count) = journal.record(request)
            // A later 404 cannot disprove that the first 503 came after the database write.
            return (record.path == "/v1/brain/turns/begin" && count == 1 ? 503 : 404, Data())
        }
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: "intermittent", transcriptIndex: 2)
        let prior = ChatMessage(role: .assistant, content: "La puerta está abierta.")
        var history = RecentConversation()
        history.start(threadID: "intermittent")
        history.append(prior, threadID: "intermittent")
        let input = "Déjala así."
        let prepared = try await coordinator.prepare(prompt: input, options: GenerationOptions(),
                                                     priorConversation: history, wakeContext: "")
        for try await _ in prepared.run(runtime: runtime) {}
        XCTAssertEqual(prepared.persistence, .pending)
        let persistence = await coordinator.complete(prepared, assistantText: "De acuerdo.")
        XCTAssertEqual(persistence, .pending)

        XCTAssertEqual(runtime.requests.first?.options.history, [prior])
        XCTAssertTrue(runtime.requests.first?.prompt.hasSuffix(input) == true)
        let requests = journal.requests
        let admissions = requests.filter { $0.path == "/v1/brain/turns/begin" }
        let operations = admissions.compactMap { $0.body["clientOperationID"] as? String }
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(Set(operations).count, 1)
        let messages = admissions.compactMap { $0.body["message"] as? [String: Any] }
        XCTAssertEqual(messages.compactMap { $0["text"] as? String }, [input, input])
        XCTAssertEqual(Set(messages.compactMap { $0["id"] as? String }).count, 1)
        XCTAssertFalse(requests.contains { $0.path == "/v1/transcript/append" })
        XCTAssertFalse(requests.contains { $0.path == "/v1/brain/turns/complete" })
    }

    func testPendingAdmissionWithoutContextStillForwardsPersistenceGuidance() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            let operation = record.body["clientOperationID"] as? String ?? ""
            return (200, Self.admission(operation: operation, persistence: "pending"))
        }
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: "pending-turn", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Anótalo si puedes.", options: GenerationOptions(),
                                                     priorConversation: RecentConversation(), wakeContext: "")
        for try await _ in prepared.run(runtime: runtime) {}

        XCTAssertEqual(prepared.persistence, .pending)
        let request = try XCTUnwrap(runtime.requests.first)
        XCTAssertTrue(request.prompt.contains("Memory changes for this turn are pending"))
    }

    func testDispatchedToolReportsRedactedOutcomeEvenWhenProviderFails() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            if record.path == "/v1/brain/turns/begin" {
                return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? ""))
            }
            return (200, Self.response(record.body["outcome"] as? [String: Any] ?? [:]))
        }
        let runtime = ToolThenFailureRuntime(name: "get_current_time", arguments: #"{"Authorization":"private-fixture"}"#)
        let coordinator = BrainConversationCoordinator(client: client, threadID: "tool-failure", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "¿Qué hora es?", options: GenerationOptions(),
                                                     priorConversation: RecentConversation(), wakeContext: "", registry: ToolRegistry.withDefaults())
        var completed = false
        var failed = false
        var acknowledgments: [String] = []
        for try await event in prepared.run(runtime: runtime) {
            if case .token(let text) = event { acknowledgments.append(text) }
            if case .completed = event { completed = true }
            if case .failed = event { failed = true }
        }
        _ = await coordinator.complete(prepared, assistantText: "")

        XCTAssertTrue(failed)
        XCTAssertFalse(completed)
        XCTAssertTrue(acknowledgments.isEmpty)
        let outcomes = journal.requests.filter { $0.path == "/v1/brain/outcomes" }
        XCTAssertEqual(outcomes.count, 1)
        let body = try XCTUnwrap(outcomes.first?.body)
        XCTAssertEqual(body["turnID"] as? String, "admitted-turn")
        let outcome = try XCTUnwrap(body["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["evidenceIDs"] as? [String], ["current-input"])
        XCTAssertEqual(outcome["description"] as? String, "")
        XCTAssertNil(outcome["observation"])
        XCTAssertFalse(String(describing: body).contains("private-fixture"))
        XCTAssertFalse(journal.requests.contains { $0.path == "/v1/brain/turns/complete" })
    }

    func testTypedTurnRejectsRawHistoryRequestForAnotherThread() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            if record.path == "/v1/brain/turns/begin" {
                return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? ""))
            }
            if record.path == "/v1/transcript/range" {
                return (200, Self.response(["messages": [["seq": 1, "role": "user", "text": "foreign transcript"]],
                                            "truncated": false]))
            }
            return (404, Data())
        }
        let original = MemoryToolbox.shared.memory
        MemoryToolbox.shared.memory = client
        defer { MemoryToolbox.shared.memory = original }
        let runtime = ToolThenFailureRuntime(name: "load_messages", arguments: #"{"chat_id":"foreign-thread","from":1}"#)
        let coordinator = BrainConversationCoordinator(client: client, threadID: "current-thread", transcriptIndex: 0)
        let registry = ToolRegistry()
        registry.register(LoadMessagesTool())
        let prepared = try await coordinator.prepare(prompt: "Busca la frase exacta.", options: GenerationOptions(),
                                                     priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        for try await _ in prepared.run(runtime: runtime) {}

        XCTAssertFalse(journal.requests.contains { $0.path == "/v1/transcript/range" })
        XCTAssertFalse(runtime.prompts.contains { $0.contains("foreign transcript") })
    }

    func testRemoteFullMessageReplacesEquivalentBoundedLocalHistory() async throws {
        let previous = "La maqueta anterior. " + String(repeating: "detalle largo ", count: 90) + "La fecha era el martes."
        let client = makeStubMemoryClient { request in
            let (record, _) = HTTPJournal().record(request)
            let context: [String: Any] = [
                "renderedContext": "",
                "recentMessageUnits": [Self.unit(id: "full-original", speaker: "self:user", text: previous)],
                "sourceReferences": [Self.source(id: "full-original", kind: "userMessage", speaker: "self:user")],
                "sourceUses": ["full-original": ["recentWhole"]], "revision": 7, "policyRevision": 3
            ]
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
        }
        var history = RecentConversation()
        history.start(threadID: "new-connection")
        history.append(.init(role: .user, content: previous), threadID: "new-connection")
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: "new-connection", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "¿Cuál era la fecha?", options: GenerationOptions(),
                                                     priorConversation: history, wakeContext: "")
        for try await _ in prepared.run(runtime: runtime) {}

        let request = try XCTUnwrap(runtime.requests.first)
        XCTAssertEqual(request.options.history, [.init(role: .user, content: previous)])
        XCTAssertTrue(request.prompt.contains("full-original"))
    }

    func testRenderedQuoteDoesNotMarkShortenedHistoryAsExact() async throws {
        let input = "¿Puedes citar la nota?"
        let client = makeStubMemoryClient { request in
            let (record, _) = HTTPJournal().record(request)
            var context = Self.bundle(prompt: input)
            context["renderedContext"] = "[original quote source=shortened-input]\nUn recuerdo recortado. La versión completa."
            context["sourceUses"] = ["previous-reply": ["recentWhole"],
                                     "shortened-input": ["recentPrefix", "renderedQuote"],
                                     "current-input": ["recentWhole"]]
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
        }
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: "new-connection", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: input, options: GenerationOptions(),
                                                     priorConversation: RecentConversation(), wakeContext: "")
        for try await _ in prepared.run(runtime: runtime) {}

        let request = try XCTUnwrap(runtime.requests.first)
        XCTAssertTrue(request.options.history.contains(.init(role: .user, content: "Un recuerdo recortado.")))
        XCTAssertTrue(request.prompt.contains("original quote source=shortened-input"))
        XCTAssertFalse(request.prompt.contains("history message 2: shortened-input"))
        XCTAssertFalse(request.prompt.contains("omitted-original"))
    }

    func testCloudReservesReplyBeforeSelectingTools() async throws {
        struct OversizedTool: AgentTool {
            static let name = "oversized_fixture"
            static let description = String(repeating: "schema ", count: 3000)
            func run(argsJSON: String) async -> String { "" }
        }
        let registry = ToolRegistry.withDefaults()
        registry.register(OversizedTool())
        let coordinator = BrainConversationCoordinator(client: nil, threadID: "cloud-window", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Hola", options: .init(maxTokens: 2048, contextTokens: 16_384),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        let runtime = RecordingRuntime()
        for try await _ in prepared.run(runtime: runtime) {}

        let request = try XCTUnwrap(runtime.requests.first)
        XCTAssertEqual(request.options.maxTokens, 2048)
        XCTAssertEqual(request.tools, [CurrentTimeTool.name])
        XCTAssertTrue(request.prompt.hasSuffix("Hola"))
    }

    func testFirstProviderRequestHonorsTotal4096WindowAndKeepsCurrentInput() async throws {
        let journal = HTTPJournal()
        let input = "Sigamos con el proyecto Lirio."
        let recent = ChatMessage(role: .user, content: "La maqueta se aprobó ayer.")
        let oversized = String(repeating: "東", count: 1800) + "oversized fixture"
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            var context = Self.bundle(prompt: input)
            context["renderedContext"] = oversized
            context["recentMessageUnits"] = [Self.unit(id: "recent", speaker: "self:user", text: recent.content)]
            context["sourceReferences"] = [Self.source(id: "recent", kind: "userMessage", speaker: "self:user")]
            context["sourceUses"] = ["recent": ["recentWhole"]]
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
        }
        var prior = RecentConversation()
        prior.start(threadID: "new-connection")
        prior.append(recent, threadID: "new-connection")
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: "new-connection", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: input, options: GenerationOptions(maxTokens: 1024),
                                                     priorConversation: prior, wakeContext: "", registry: ToolRegistry.withDefaults())
        for try await _ in prepared.run(runtime: runtime) {}

        let request = try XCTUnwrap(runtime.requests.first)
        let admission = try XCTUnwrap(journal.requests.first { $0.path == "/v1/brain/turns/begin" })
        let budget = try XCTUnwrap(admission.body["budget"] as? [String: Int])
        let system = try XCTUnwrap(budget["systemTokens"])
        let tools = try XCTUnwrap(budget["toolTokens"])
        XCTAssertEqual(budget["contextTokens"], 4096)
        XCTAssertTrue(try XCTUnwrap(request.options.systemPrompt).hasPrefix(BrainConversationPolicy.persona))
        XCTAssertEqual(request.options.maxTokens, budget["outputTokens"])
        XCTAssertGreaterThan(system, 0)
        XCTAssertGreaterThan(tools, 0)
        XCTAssertEqual(request.tools, [CurrentTimeTool.name])
        XCTAssertTrue(request.prompt.hasSuffix(input))
        XCTAssertFalse(request.prompt.contains("oversized fixture"))
        XCTAssertEqual(request.options.history, [recent])
        let history = request.options.history.reduce(0) { $0 + $1.content.utf8.count + 16 }
        XCTAssertLessThanOrEqual(system + tools + request.options.maxTokens + request.prompt.utf8.count + history, 4096)
    }

    func testRecentPrefixDoesNotGrantOriginalEvenWhenHashMatchesTranscriptRow() async throws {
        let thread = "new-connection"
        let original = "La versión original contiene una cláusula reservada."
        let prefix = "La versión original"
        let id = "transcript:" + SHA256.hash(data: Data("\(thread)\u{1}7\u{1}\(original)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            switch record.path {
            case "/v1/brain/turns/begin":
                let context: [String: Any] = [
                    "renderedContext": "", "recentMessageUnits": [Self.unit(id: id, speaker: "self:user", text: prefix)],
                    "sourceReferences": [Self.source(id: id, kind: "userMessage", speaker: "self:user")],
                    "sourceUses": [id: ["recentPrefix"]], "revision": 7, "policyRevision": 1
                ]
                return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
            case "/v1/transcript/range":
                return (200, Self.response(["messages": [["seq": 7, "role": "user", "text": original]], "truncated": false]))
            default: return (404, Data())
            }
        }
        let runtime = ToolThenFailureRuntime(name: "load_messages", arguments: #"{"chat_id":"new-connection","from":7}"#)
        let coordinator = BrainConversationCoordinator(client: client, threadID: thread, transcriptIndex: 0)
        let registry = ToolRegistry()
        registry.register(LoadMessagesTool())
        let prepared = try await coordinator.prepare(prompt: "Lee el mensaje 7.", options: GenerationOptions(),
                                                     priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        for try await _ in prepared.run(runtime: runtime) {}

        XCTAssertFalse(journal.requests.contains { $0.path == "/v1/transcript/range" })
        XCTAssertFalse(runtime.prompts.contains { $0.contains(original) })
    }

    func testUnconfirmedToolReportKeepsTurnPendingWithoutRepeatingTool() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            let operation = record.body["clientOperationID"] as? String ?? ""
            switch record.path {
            case "/v1/brain/turns/begin": return (200, Self.admission(operation: operation))
            case "/v1/brain/outcomes": return (503, Data())
            case "/v1/brain/turns/complete": return (200, Self.admission(operation: operation, reply: "Listo."))
            default: return (200, Data())
            }
        }
        let tool = CountingTool()
        let registry = ToolRegistry()
        registry.register(tool)
        let runtime = ToolThenFailureRuntime(name: CountingTool.name, arguments: "{}")
        let coordinator = BrainConversationCoordinator(client: client, threadID: "report-pending", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Prueba la acción.", options: GenerationOptions(),
                                                     priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        var completedToolEvents = 0
        for try await event in prepared.run(runtime: runtime) {
            if case .toolCallFinished = event { completedToolEvents += 1 }
        }
        let persistence = await coordinator.complete(prepared, assistantText: "Listo.")

        XCTAssertEqual(tool.executions, 1)
        XCTAssertEqual(completedToolEvents, 1)
        let outcomes = journal.requests.filter { $0.path == "/v1/brain/outcomes" }
        XCTAssertEqual(outcomes.count, 2)
        let ids = outcomes.compactMap { ($0.body["outcome"] as? [String: Any])?["id"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertEqual(persistence, .pending)
    }

    func testCompletedToolPersistsOutcomeAfterGenerationCancellation() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            if record.path == "/v1/brain/outcomes" {
                return (200, Self.response(record.body["outcome"] as? [String: Any] ?? [:]))
            }
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? ""))
        }
        let tool = CountingTool(result: "Synthetic private result")
        tool.onExecuted = { withUnsafeCurrentTask { $0?.cancel() } }
        let registry = ToolRegistry()
        registry.register(tool)
        let runtime = ToolThenFailureRuntime(name: CountingTool.name, arguments: #"{"raw":"private argument"}"#)
        let coordinator = BrainConversationCoordinator(client: client, threadID: "tool-cancellation", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Ejecuta la acción.", options: .init(maxTokens: 512),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        for try await _ in prepared.run(runtime: runtime) {}

        XCTAssertEqual(tool.executions, 1)
        XCTAssertEqual(runtime.prompts.count, 1)
        let reports = journal.requests.filter { $0.path == "/v1/brain/outcomes" }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.body["turnID"] as? String, "admitted-turn")
        let outcome = try XCTUnwrap(reports.first?.body["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["description"] as? String, "")
        XCTAssertEqual(outcome["evidenceIDs"] as? [String], ["current-input"])
        XCTAssertNil(outcome["observation"])
    }

    func testCorrectedDictationUsesOnlyFreshFinalContextBeforeFirstGeneration() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            if record.path == "/v1/brain/context" {
                var speculative = Self.bundle(prompt: "")
                speculative["renderedContext"] = "Speculative red fixture from an earlier draft."
                return (200, Self.response(speculative))
            }
            var final = Self.bundle(prompt: "")
            final["renderedContext"] = "The active project Lirio is blue."
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: final))
        }
        let cues = BrainCuePrefetch(delay: .milliseconds(10))
        let superseded = cues.submit(partial: "Lirio está en verde", threadID: "old-connection", client: client)
        let stable = cues.submit(partial: "Lirio está en rojo", threadID: "old-connection", client: client)
        await superseded?.value
        await stable?.value
        cues.cancel()

        let finalInput = "¿Seguimos con el proyecto Lirio en azul?"
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: "new-connection", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: finalInput, options: GenerationOptions(),
                                                     priorConversation: RecentConversation(), wakeContext: "")
        for try await _ in prepared.run(runtime: runtime) {}

        let read = journal.requests.filter { $0.path == "/v1/brain/context" }
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.query["mode"], "prefetch")
        XCTAssertEqual(read.first?.body["query"] as? String, "Lirio está en rojo")
        XCTAssertEqual(read.first?.body["threadID"] as? String, "old-connection")
        let admissions = journal.requests.filter { $0.path == "/v1/brain/turns/begin" }
        XCTAssertEqual(admissions.count, 1)
        XCTAssertEqual(admissions.first?.body["threadID"] as? String, "new-connection")
        XCTAssertEqual((admissions.first?.body["message"] as? [String: Any])?["text"] as? String, finalInput)
        let first = try XCTUnwrap(runtime.requests.first)
        XCTAssertTrue(first.prompt.contains("The active project Lirio is blue."))
        XCTAssertFalse(first.prompt.contains("Speculative red fixture"))
    }

    func testUnchangedDictationTransfersOnlyItsOperationToFinalAdmission() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            if record.path == "/v1/brain/context" {
                return (200, Self.response(Self.bundle(prompt: "")))
            }
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? ""))
        }
        let cue = BrainCuePrefetch(delay: .milliseconds(1))
        let text = "Retoma el proyecto Lirio."
        await cue.submit(partial: text, threadID: "dictation", client: client)?.value
        let operation = try XCTUnwrap(cue.consume(final: text, threadID: "dictation", client: client))
        XCTAssertNil(cue.consume(final: text, threadID: "dictation", client: client))
        let coordinator = BrainConversationCoordinator(client: client, threadID: "dictation", transcriptIndex: 0,
                                                       operationID: operation)
        _ = try await coordinator.prepare(prompt: text, options: GenerationOptions(), priorConversation: RecentConversation(),
                                          wakeContext: "")
        XCTAssertEqual(journal.requests.compactMap { $0.body["clientOperationID"] as? String },
                       [operation.uuidString, operation.uuidString])
        XCTAssertEqual(journal.requests.map(\.path), ["/v1/brain/context", "/v1/brain/turns/begin"])
    }

    func testCancelledDictationDoesNotSendAPartialOrWriteATurn() async {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            _ = journal.record(request)
            return (404, Data())
        }
        let cues = BrainCuePrefetch(delay: .milliseconds(10))
        let pending = cues.submit(partial: "Este borrador se canceló.", threadID: "old-connection", client: client)
        cues.cancel()
        await pending?.value
        XCTAssertTrue(journal.requests.isEmpty)
    }

    func testNativeToolRegistryPreservesAtoZWithoutMemory() async throws {
        let registry = ToolRegistry.native(memoryAvailable: false)
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: nil, threadID: "local", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Hola.", options: GenerationOptions(maxTokens: 1024),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        for try await _ in prepared.run(runtime: runtime) {}

        let request = try XCTUnwrap(runtime.requests.first)
        let names = Set(request.tools)
        XCTAssertTrue(names.isSuperset(of: ["list_available_shifts", "add_shift", "drop_shift"]))
        XCTAssertFalse(names.contains("search_memory"))
        XCTAssertFalse(names.contains("taste_profile"))
        XCTAssertFalse(request.options.systemPrompt?.contains("load_messages") == true)
    }

    func testTypedTasteToolScopesProfileAndKeepsTemporaryIntentSeparate() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            switch record.path {
            case "/v1/brain/turns/begin":
                return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? ""))
            case "/v1/brain/tastes/profile":
                let current: [String: Any] = [
                    "id": "one-selection", "subjectID": "self:user", "kind": "selection", "target": "Jhay Wheeler",
                    "domain": "music", "provenance": "explicit", "durability": "contextual", "recordedAt": 1,
                    "evidenceIDs": ["taste-evidence"]
                ]
                return (200, Self.response(["subjectID": "self:user", "revision": 7, "records": [],
                                           "currentIntent": [current], "missingInformation": ["taste"]]))
            case "/v1/brain/outcomes":
                return (200, Self.response(record.body["outcome"] as? [String: Any] ?? [:]))
            default: return (404, Data())
            }
        }
        let registry = ToolRegistry()
        registry.register(TasteProfileTool(), requiresMemory: true)
        let runtime = ToolThenFailureRuntime(name: "taste_profile",
            arguments: #"{"domain":"music","situation":"while cooking","threadID":"foreign","subjectID":"another-person"}"#)
        let coordinator = BrainConversationCoordinator(client: client, threadID: "taste-current", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Pon algo de música.", options: GenerationOptions(maxTokens: 512),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        for try await _ in prepared.run(runtime: runtime) {}

        let request = try XCTUnwrap(journal.requests.first { $0.path == "/v1/brain/tastes/profile" })
        XCTAssertEqual(request.query["domain"], "music")
        XCTAssertEqual(request.query["threadID"], "taste-current")
        XCTAssertEqual(request.query["situation"], "while cooking")
        XCTAssertNotEqual(request.query["subjectID"], "another-person")
        let nextPrompt = try XCTUnwrap(runtime.prompts.dropFirst().first)
        XCTAssertTrue(nextPrompt.contains("Current intent (this situation only)"))
        XCTAssertTrue(nextPrompt.contains("Jhay Wheeler"))
        XCTAssertTrue(nextPrompt.contains("Missing information: taste"))
        XCTAssertTrue(nextPrompt.contains("ask one useful question"))
    }

    func testOlderServerExplicitlyLacksTypedTasteProfile() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            switch record.path {
            case "/v1/conversation/window": return (200, Self.response(["turns": []]))
            case "/v1/memory/recall":
                return (200, Self.response(["core": [], "recall": [], "summaries": [], "recentTurns": []]))
            default: return (404, Data())
            }
        }
        let registry = ToolRegistry()
        registry.register(TasteProfileTool(), requiresMemory: true)
        let runtime = ToolThenFailureRuntime(name: "taste_profile", arguments: #"{"domain":"music"}"#)
        let coordinator = BrainConversationCoordinator(client: client, threadID: "legacy-tastes", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "¿Qué gustos recuerdas?", options: GenerationOptions(maxTokens: 512),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        for try await _ in prepared.run(runtime: runtime) {}

        let nextPrompt = try XCTUnwrap(runtime.prompts.dropFirst().first)
        XCTAssertTrue(nextPrompt.contains("Taste profiles are unavailable on this memory service"))
        XCTAssertFalse(journal.requests.contains { $0.path == "/v1/brain/tastes/profile" })
    }

    func testFreshConnectionUsesProjectCheckpointAndRestoredThreadUsesItsRecentMessages() async throws {
        let journal = HTTPJournal()
        let restoredID = "restored-project"
        let exact = "El texto original de la maqueta se quedó pendiente."
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            let opened = record.body["threadID"] as? String == restoredID
            var source = Self.source(id: "older-project-message", kind: "userMessage", speaker: "self:user")
            source["threadID"] = restoredID
            let context: [String: Any] = [
                "renderedContext": opened ? "" : "Proyecto Lirio: falta revisar la maqueta.",
                "recentMessageUnits": [Self.unit(id: "older-project-message", speaker: "self:user", text: exact)],
                "sourceReferences": [source], "sourceUses": ["older-project-message": ["recentWhole"]],
                "revision": 7, "policyRevision": 3
            ]
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
        }
        let runtime = RecordingRuntime()
        let prompt = "Sigamos con el proyecto Lirio."
        var episode = ChatSession.Episode(lastActivity: 1)
        let freshID = episode.begin(now: 6000).id
        XCTAssertNotEqual(freshID, restoredID)
        for restore in [false, true] {
            if restore { episode.restore(threadID: restoredID, now: 7200) }
            let session = episode.begin(now: restore ? 7201 : 6001)
            let coordinator = BrainConversationCoordinator(client: client, threadID: session.id, transcriptIndex: session.index)
            let prepared = try await coordinator.prepare(prompt: prompt, options: GenerationOptions(),
                priorConversation: RecentConversation(), wakeContext: "")
            for try await _ in prepared.run(runtime: runtime) {}
        }
        let fresh = try XCTUnwrap(runtime.requests.first)
        XCTAssertTrue(fresh.prompt.contains("Proyecto Lirio: falta revisar la maqueta."))
        XCTAssertFalse(fresh.prompt.contains("older-project-message"))
        XCTAssertTrue(fresh.options.history.isEmpty)
        let restored = try XCTUnwrap(runtime.requests.last)
        XCTAssertEqual(restored.options.history, [.init(role: .user, content: exact)])
        XCTAssertTrue(restored.prompt.contains("history message 1: older-project-message"))
        XCTAssertEqual(journal.requests.compactMap { $0.body["threadID"] as? String }, [freshID, restoredID])
    }

    func testNativeProjectRecallGetsServerBudgetAndFirstGenerationContext() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            let budget = record.body["budget"] as? [String: Int] ?? [:]
            let window = budget["contextTokens", default: 0]
            let output = budget["outputTokens", default: 0]
            let system = budget["systemTokens", default: 0]
            let tools = budget["toolTokens", default: 0]
            var bundle: [String: Any] = ["renderedContext": "[recalled project reported checkpoint sources=prior-close]\nFalta validar la importación.\n[previous exchange opening orientation]\nEmpezamos Aurora.\n[previous exchange closing orientation]\nTerminamos revisando el plano.",
                "recentMessageUnits": [], "sourceReferences": [
                    Self.source(id: "prior-open", kind: "userMessage", speaker: "self:user"),
                    Self.source(id: "prior-close", kind: "userMessage", speaker: "self:user")],
                "sourceUses": ["prior-open": ["startupOrientation"], "prior-close": ["recalledSupport", "startupOrientation"]],
                "revision": 7, "policyRevision": 3, "truncations": []]
            bundle["accounting"] = ["estimatedInputTokens": 0, "reservedOutputTokens": output,
                "reservedSystemTokens": system, "reservedToolTokens": tools, "totalWindowTokens": window]
            let wireBytes = Self.response(bundle).count + 64 + 100
            if wireBytes > window - output - system - tools { bundle["renderedContext"] = "" }
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: bundle))
        }
        let coordinator = BrainConversationCoordinator(client: client, threadID: "new-connection", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Sigamos con el proyecto Aurora.",
            options: .init(maxTokens: 2048, contextTokens: 4096), priorConversation: RecentConversation(),
            wakeContext: "", registry: .native(memoryAvailable: true))
        let runtime = RecordingRuntime()
        for try await _ in prepared.run(runtime: runtime) {}
        let first = try XCTUnwrap(runtime.requests.first)
        XCTAssertTrue(first.prompt.contains("Falta validar la importación."))
        XCTAssertTrue(first.prompt.contains("Empezamos Aurora."))
        XCTAssertTrue(first.prompt.contains("Terminamos revisando el plano."))
        XCTAssertTrue(first.options.history.isEmpty)
    }

    func testAlarmAndReminderRequestsPrioritizeTheirNativeTool() {
        let registry = ToolRegistry.native(memoryAvailable: true)
        registry.register(CreateAlarmTool())
        registry.register(ListAlarmsTool())
        registry.register(CreateReminderTool())
        registry.register(ListRemindersTool())

        let alarm = registry.prioritized(for: "Configúrame tres alarmas.", history: [])
        XCTAssertEqual(alarm.first.map { type(of: $0).name }, CreateAlarmTool.name)

        let existing = registry.prioritized(for: "¿Tengo una alarma para las 4:25?", history: [])
        XCTAssertEqual(existing.first.map { type(of: $0).name }, ListAlarmsTool.name)

        let reminder = registry.prioritized(for: "Sí, ponlo como recordatorio.", history: [])
        XCTAssertEqual(reminder.first.map { type(of: $0).name }, CreateReminderTool.name)

        let followUp = registry.prioritized(for: "Ponle Breaks", history: [
            .init(role: .user, content: "Crea un recordatorio a las 08:10"),
            .init(role: .assistant, content: "No he creado nada en la agenda.")
        ])
        XCTAssertEqual(followUp.first.map { type(of: $0).name }, CreateReminderTool.name)

        let attribution = registry.prioritized(for: "¿Tú creaste el recordatorio que choca?", history: [])
        XCTAssertEqual(Array(attribution.prefix(2).map { type(of: $0).name }),
                       [ListRemindersTool.name, QueryScheduleTool.name])
    }

    func testProductionRegistrySelectsRelevantShiftAndCalendarToolsAt4096() async throws {
        let client = makeStubMemoryClient { request in
            let (record, _) = HTTPJournal().record(request)
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? ""))
        }
        let runtime = RecordingRuntime()
        let registry = ToolRegistry.native(memoryAvailable: true)
        registry.register(CreateAlarmTool())
        registry.register(ListAlarmsTool())
        registry.register(CreateReminderTool())
        let inputs: [(String, Set<String>)] = [
            ("¿Puedes soltar mi turno del martes?", ["drop_shift"]),
            ("Quiero aceptar ese turno en Amazon.", ["add_shift"]),
            ("¿Qué tengo agendado en mi calendario el martes?", ["query_schedule"]),
            ("Agenda una cita mañana a las diez.", ["check_schedule", "create_event"]),
            ("Necesito que me prepares una alarma para las 4:25 P.M.", ["create_alarm"]),
            ("Pon una alarma hoy a las 4:25 para mi turno de Amazon.", ["create_alarm"]),
            ("Despiértame mañana a las siete.", ["create_alarm"])
        ]
        for (prompt, expected) in inputs {
            let coordinator = BrainConversationCoordinator(client: client, threadID: "tool-choice", transcriptIndex: 0)
            let prepared = try await coordinator.prepare(prompt: prompt, options: GenerationOptions(maxTokens: 1024, contextTokens: 4096),
                priorConversation: RecentConversation(), wakeContext: "", registry: registry)
            for try await _ in prepared.run(runtime: runtime) {}
            let request = try XCTUnwrap(runtime.requests.last)
            if expected.contains("create_alarm") {
                XCTAssertEqual(request.tools.first, "create_alarm")
                XCTAssertTrue(request.options.systemPrompt?.contains("Use create_alarm for alarms") == true)
            }
            XCTAssertTrue(Set(request.tools).isSuperset(of: expected), "\(prompt) received \(request.tools)")
        }
    }

    func testFollowUpNeverLabelsTrimmedHistoryAsItsOriginalIndex() async throws {
        let thread = "new-connection"
        let oldest = "Primera nota: " + String(repeating: "primera ", count: 79)
        let latest = "Segunda nota: " + String(repeating: "segunda ", count: 79)
        let client = makeStubMemoryClient { request in
            let (record, _) = HTTPJournal().record(request)
            if record.path == "/v1/brain/outcomes" { return (200, Self.response(record.body["outcome"] as? [String: Any] ?? [:])) }
            let context: [String: Any] = [
                "renderedContext": "",
                "recentMessageUnits": [
                    Self.unit(id: "exact-first", speaker: "self:user", text: oldest),
                    Self.unit(id: "exact-second", speaker: "self:agent", text: latest)
                ],
                "sourceReferences": [
                    Self.source(id: "exact-first", kind: "userMessage", speaker: "self:user"),
                    Self.source(id: "exact-second", kind: "assistantMessage", speaker: "self:agent")
                ],
                "sourceUses": ["exact-first": ["recentWhole"], "exact-second": ["recentWhole"]],
                "revision": 7, "policyRevision": 3
            ]
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
        }
        let registry = ToolRegistry()
        registry.register(CountingTool(result: "Executed. " + String(repeating: "tool-result ", count: 90)))
        let runtime = ToolThenFailureRuntime(name: CountingTool.name, arguments: "{}")
        let coordinator = BrainConversationCoordinator(client: client, threadID: thread, transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Usa el resultado.", options: GenerationOptions(maxTokens: 1024, contextTokens: 4096),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        for try await _ in prepared.run(runtime: runtime) {}

        XCTAssertEqual(runtime.histories.first?.count, 2)
        XCTAssertTrue(runtime.prompts.first?.contains("history message 1: exact-first") == true)
        let next = try XCTUnwrap(runtime.prompts.dropFirst().first)
        let nextHistory = try XCTUnwrap(runtime.histories.dropFirst().first)
        XCTAssertLessThan(nextHistory.count, 2)
        XCTAssertFalse(next.contains("history message 1: exact-first"))
        XCTAssertFalse(nextHistory.count < 2 && next.contains("history message 2: exact-second"))
        XCTAssertTrue(next.contains("Executed."))
    }

    func testTypedErasureRequiresUserToSelectExactSourceAndCommittedReceipt() async throws {
        let firstID = "transcript:" + String(repeating: "a", count: 64)
        let otherID = "transcript:" + String(repeating: "b", count: 64)
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            switch record.path {
            case "/v1/brain/forget":
                let scope = record.body["scope"] as? [String: Any] ?? [:]
                return (200, Self.response(["clientOperationID": record.body["clientOperationID"] as? String ?? "",
                    "scope": scope, "state": "pending", "revision": 8, "forgottenEvidenceIDs": [], "forgottenClaimIDs": []]))
            case "/v1/brain/outcomes":
                return (200, Self.response(record.body["outcome"] as? [String: Any] ?? [:]))
            default:
                let context: [String: Any] = [
                    "renderedContext": "",
                    "recentMessageUnits": [
                        Self.unit(id: firstID, speaker: "self:user", text: "First synthetic source."),
                        Self.unit(id: otherID, speaker: "self:user", text: "Second synthetic source.")
                    ],
                    "sourceReferences": [
                        Self.source(id: firstID, kind: "userMessage", speaker: "self:user"),
                        Self.source(id: otherID, kind: "userMessage", speaker: "self:user")
                    ],
                    "sourceUses": [firstID: ["recentWhole"], otherID: ["recentWhole"]], "revision": 7, "policyRevision": 3
                ]
                return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
            }
        }
        let registry = ToolRegistry()
        registry.register(ForgetTool(), requiresMemory: true)
        var outputs: [String] = []
        for chosenID in [otherID, firstID] {
            let runtime = ToolThenFailureRuntime(name: "forget", arguments: #"{"evidence_id":"\#(chosenID)"}"#)
            let coordinator = BrainConversationCoordinator(client: client, threadID: "new-connection", transcriptIndex: 0)
            let prepared = try await coordinator.prepare(prompt: "Olvida \(firstID).", options: GenerationOptions(maxTokens: 512),
                priorConversation: RecentConversation(), wakeContext: "", registry: registry)
            for try await event in prepared.run(runtime: runtime) {
                if case .toolCallFinished(_, let result) = event { outputs.append(result) }
            }
        }
        let writes = journal.requests.filter { $0.path == "/v1/brain/forget" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual((writes.first?.body["scope"] as? [String: Any])?["id"] as? String, firstID)
        XCTAssertEqual(writes.first?.body["expectedRevision"] as? Int, 7)
        XCTAssertEqual(outputs, ["No memory was erased. Select the exact authorized source to forget.", "Erasure was not confirmed."])
    }

    func testConfirmedErasureClearsFollowUpContextAndLocalFallback() async throws {
        let id = "transcript:" + String(repeating: "a", count: 64)
        let erasedText = "The synthetic forgotten sentence."
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, index) = journal.record(request)
            switch record.path {
            case "/v1/brain/forget":
                return (200, Self.response(["clientOperationID": record.body["clientOperationID"] as? String ?? "",
                    "scope": record.body["scope"] as? [String: Any] ?? [:], "state": "committed", "revision": 8,
                    "forgottenEvidenceIDs": [id], "forgottenClaimIDs": []]))
            case "/v1/brain/outcomes":
                return (200, Self.response(record.body["outcome"] as? [String: Any] ?? [:]))
            default:
                guard index == 1 else { return (503, Data()) }
                let context: [String: Any] = ["renderedContext": "An earlier gist: \(erasedText)",
                    "recentMessageUnits": [Self.unit(id: id, speaker: "self:user", text: erasedText)],
                    "sourceReferences": [Self.source(id: id, kind: "userMessage", speaker: "self:user")],
                    "sourceUses": [id: ["recentWhole"]], "revision": 7, "policyRevision": 3]
                return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
            }
        }
        let thread = "new-connection"
        var recent = RecentConversation()
        recent.start(threadID: thread)
        recent.append(.init(role: .user, content: erasedText), threadID: thread)
        let registry = ToolRegistry()
        registry.register(ForgetTool(), requiresMemory: true)
        let coordinator = BrainConversationCoordinator(client: client, threadID: thread, transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Olvida \(id).", options: .init(maxTokens: 512),
            priorConversation: recent, wakeContext: "", registry: registry,
            invalidateLocalHistory: { recent = RecentConversation() })
        let runtime = ToolThenFailureRuntime(name: "forget", arguments: #"{"evidence_id":"\#(id)"}"#)
        for try await _ in prepared.run(runtime: runtime) {}
        XCTAssertTrue(runtime.histories.first?.contains(where: { $0.content == erasedText }) == true)
        XCTAssertEqual(runtime.histories.dropFirst().first, [])
        let followUp = try XCTUnwrap(runtime.prompts.dropFirst().first)
        XCTAssertFalse(followUp.contains(erasedText))
        XCTAssertTrue(followUp.contains("Forgot the authorized source."))

        let next = BrainConversationCoordinator(client: client, threadID: thread, transcriptIndex: 1)
        let nextTurn = try await next.prepare(prompt: "Hola.", options: .init(maxTokens: 512),
                                              priorConversation: recent, wakeContext: "")
        let recording = RecordingRuntime()
        for try await _ in nextTurn.run(runtime: recording) {}
        XCTAssertEqual(nextTurn.persistence, .pending)
        XCTAssertEqual(recording.requests.first?.options.history, [])
    }

    func testTypedOriginalLookupUsesDeliveredIDAndRequiresCompleteQuote() async throws {
        let journal = HTTPJournal()
        let id = "previous-reply"
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            switch record.path {
            case "/v1/brain/context":
                var context = Self.bundle(prompt: "")
                context["renderedContext"] = "[original quote source=\(id)]\nLa maqueta está lista."
                context["sourceUses"] = [id: ["renderedQuote"]]
                return (200, Self.response(context))
            case "/v1/brain/outcomes":
                return (200, Self.response(record.body["outcome"] as? [String: Any] ?? [:]))
            default:
                return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "",
                                            context: Self.bundle(prompt: "")))
            }
        }
        let coordinator = BrainConversationCoordinator(client: client, threadID: "new-connection", transcriptIndex: 0)
        let registry = ToolRegistry()
        registry.register(LoadMessagesTool(), requiresMemory: true)
        let turn = try await coordinator.prepare(prompt: "Cita el mensaje completo.", options: .init(maxTokens: 512),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        let runtime = ToolThenFailureRuntime(name: "load_messages", arguments: #"{"evidence_id":"\#(id)"}"#)
        for try await _ in turn.run(runtime: runtime) {}
        let request = try XCTUnwrap(journal.requests.first { $0.path == "/v1/brain/context" })
        XCTAssertEqual(request.body["quoteEvidenceIDs"] as? [String], [id])
        XCTAssertEqual(request.body["threadID"] as? String, "new-connection")
        XCTAssertTrue(runtime.prompts.dropFirst().first?.contains("[original quote source=\(id)]\nLa maqueta está lista.") == true)
        XCTAssertFalse(journal.requests.contains { $0.path == "/v1/transcript/range" })
    }

    func testTypedReflectionReportsUnconfirmedWithoutUsingLegacyRoute() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            switch record.path {
            case "/v1/brain/turns/begin":
                return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? ""))
            case "/v1/brain/consolidate": return (503, Data())
            default: return (404, Data())
            }
        }
        let registry = ToolRegistry()
        registry.register(ReflectTool(), requiresMemory: true)
        let runtime = ToolThenFailureRuntime(name: "reflect", arguments: "{}")
        let coordinator = BrainConversationCoordinator(client: client, threadID: "reflection", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Reflexiona sobre esto.", options: GenerationOptions(maxTokens: 512),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        var output: String?
        for try await event in prepared.run(runtime: runtime) {
            if case .toolCallFinished(_, let result) = event { output = result }
        }
        let requests = journal.requests
        XCTAssertEqual(requests.filter { $0.path == "/v1/brain/consolidate" }.count, 1)
        XCTAssertFalse(requests.contains { $0.path == "/v1/memory/reflect" })
        XCTAssertEqual(output, "Reflection was not confirmed.")
    }

    func testLegacyNativeToolCannotEraseAnUnrequestedMemory() async throws {
        let journal = HTTPJournal()
        let client = makeStubMemoryClient { request in
            let (record, _) = journal.record(request)
            switch record.path {
            case "/v1/conversation/window": return (200, Self.response(["turns": []]))
            case "/v1/memory/recall": return (200, Self.response(["core": [], "recall": [], "summaries": [], "recentTurns": []]))
            default: return (404, Data())
            }
        }
        let registry = ToolRegistry()
        registry.register(ForgetTool(), requiresMemory: true)
        let runtime = ToolThenFailureRuntime(name: "forget", arguments: #"{"query":"wrong label"}"#)
        let coordinator = BrainConversationCoordinator(client: client, threadID: "legacy", transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "Olvida la maqueta.", options: GenerationOptions(maxTokens: 512),
            priorConversation: RecentConversation(), wakeContext: "", registry: registry)
        for try await _ in prepared.run(runtime: runtime) {}
        XCTAssertFalse(journal.requests.contains { $0.path == "/v1/nodes" || $0.path == "/v1/memory/forget" })
    }

    func testUnavailableServerRetainsLatestLocalMessageWithNativeDefaults() async throws {
        let client = makeStubMemoryClient { _ in (503, Data()) }
        let threadID = "unavailable-native"
        var recent = RecentConversation()
        recent.start(threadID: threadID)
        let previous = ChatMessage(role: .user, content: "La caja de repuesto es amarilla.")
        recent.append(previous, threadID: threadID)
        let runtime = RecordingRuntime()
        let coordinator = BrainConversationCoordinator(client: client, threadID: threadID, transcriptIndex: 0)
        let prepared = try await coordinator.prepare(prompt: "¿Y de qué color era?",
            options: GenerationOptions(maxTokens: 2048, contextTokens: 4096), priorConversation: recent,
            wakeContext: "", registry: .native(memoryAvailable: true))
        for try await _ in prepared.run(runtime: runtime) {}
        XCTAssertEqual(runtime.requests.first?.options.history, [previous])
        XCTAssertEqual(prepared.persistence, .pending)
    }

    func testShortConfirmationInRestoredEpisodeRetainsDropToolAtNativeDefaults() async throws {
        let threadID = "restored-shift"
        let question = "¿Confirmas que quieres soltar el turno del martes de 5 a 9?"
        let client = makeStubMemoryClient { request in
            let (record, _) = HTTPJournal().record(request)
            var source = Self.source(id: "confirmed-shift", kind: "assistantMessage", speaker: "self:agent")
            source["threadID"] = threadID
            let context: [String: Any] = [
                "renderedContext": "", "sourceReferences": [source], "sourceUses": ["confirmed-shift": ["recentWhole"]],
                "recentMessageUnits": [Self.unit(id: "confirmed-shift", speaker: "self:agent", text: question)],
                "revision": 7, "policyRevision": 3
            ]
            return (200, Self.admission(operation: record.body["clientOperationID"] as? String ?? "", context: context))
        }
        var episode = ChatSession.Episode(lastActivity: 1)
        episode.restore(threadID: threadID, now: 6000)
        let restored = episode.begin(now: 6001)
        let coordinator = BrainConversationCoordinator(client: client, threadID: restored.id, transcriptIndex: restored.index)
        let prepared = try await coordinator.prepare(prompt: "Sí.", options: GenerationOptions(maxTokens: 2048, contextTokens: 4096),
            priorConversation: RecentConversation(), wakeContext: "", registry: .native(memoryAvailable: true))
        let runtime = RecordingRuntime()
        for try await _ in prepared.run(runtime: runtime) {}
        let request = try XCTUnwrap(runtime.requests.first)
        XCTAssertTrue(request.tools.contains("drop_shift"))
        XCTAssertEqual(request.options.history, [.init(role: .assistant, content: question)])
    }
}
