import Foundation

/// Talks to a local mlx-lm OpenAI-style server. The client-side tool loop lives in the caller
/// (Agent); this runtime does one request/response and surfaces any tool call as events.
///
/// Branch A: the mlx-lm server normalizes Gemma's output to standard OpenAI shape — the visible
/// answer is `message.content` and tool calls are in `message.tool_calls`. `message.reasoning`
/// (Gemma's thought channel) is kept separate by the server and is NOT surfaced as the answer.
final class ServerRuntime: ModelRuntime, ToolCallingRuntime, @unchecked Sendable {
    nonisolated let identifier = "mlx-server"
    let baseURL: URL
    let model: String
    let session: URLSession
    /// When false, we send `chat_template_kwargs: {"enable_thinking": false}` so the model skips
    /// its hidden chain-of-thought. Measured ~48x latency win (43s -> 0.9s for "hola") with an
    /// identical answer; tool-calling and memory recall still work. Toggle to true to re-enable.
    let enableThinking: Bool

    init(baseURL: URL = URL(string: "http://localhost:8080")!,
         model: String = "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
         session: URLSession = .shared,
         enableThinking: Bool = false) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.enableThinking = enableThinking
    }

    func isLoaded() async -> Bool { true }
    func load(options: ModelLoadOptions) async throws {}
    func unload() async {}
    func currentMetrics() async -> RuntimeMetrics? { nil }

    func generate(prompt: String, options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
        await generate(prompt: prompt, tools: [], options: options)
    }

    func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages: [[String: Any]] = []
                    if let sys = options.systemPrompt, !sys.isEmpty {
                        messages.append(["role": "system", "content": sys])
                    }
                    messages.append(["role": "user", "content": prompt])

                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "max_tokens": options.maxTokens,
                        "temperature": options.temperature,
                        "stream": false,
                        // Skip the model's hidden chain-of-thought (~48x faster; see `enableThinking`).
                        // Per-request override wins; else fall back to the runtime's own default.
                        "chat_template_kwargs": ["enable_thinking": options.enableThinking ?? enableThinking],
                    ]
                    if !tools.isEmpty {
                        body["tools"] = tools.map { type(of: $0).functionSpec }
                    }

                    var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (data, response) = try await session.data(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // Surface non-2xx as an error instead of falling through to empty content.
                        let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        let serverMsg = (errJson?["error"] as? [String: Any])?["message"] as? String
                            ?? (errJson?["error"] as? String)
                            ?? String(data: data.prefix(512), encoding: .utf8)
                        throw RuntimeError.generationFailed("server returned HTTP \(http.statusCode): \(serverMsg ?? "<no body>")")
                    }
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let choice = (json?["choices"] as? [[String: Any]])?.first
                    let message = choice?["message"] as? [String: Any]
                    // The visible answer is `content`; `reasoning` is the thought channel — never surface it.
                    let content = (message?["content"] as? String) ?? ""

                    // Branch A: native OpenAI tool_calls.
                    if let calls = message?["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                        for call in calls {
                            let fn = call["function"] as? [String: Any]
                            let name = (fn?["name"] as? String) ?? ""
                            let args = (fn?["arguments"] as? String) ?? "{}"
                            continuation.yield(.toolCallStarted(name: name, args: args))
                        }
                    }

                    let visible = GemmaToolCallParser.strip(content)
                    if !visible.isEmpty { continuation.yield(.token(visible)) }
                    continuation.yield(.completed(GenerationResult(
                        text: visible,
                        metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: RuntimeError.generationFailed("server error: \(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
