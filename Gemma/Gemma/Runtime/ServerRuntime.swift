import Foundation

/// Talks to a local mlx-lm OpenAI-style server. The client-side tool loop lives in the caller
/// (Agent); this runtime does one request/response and surfaces any tool call as events.
///
/// Branch A: the mlx-lm server normalizes Gemma's output to standard OpenAI shape — the visible
/// answer is `message.content` and tool calls are in `message.tool_calls`. `message.reasoning`
/// (Gemma's thought channel) is kept separate by the server and is NOT surfaced as the answer.
final class ServerRuntime: ModelRuntime, ToolCallingRuntime, @unchecked Sendable {
    nonisolated let identifier = "mlx-server"
    let provider: ModelProvider
    var baseURL: URL { provider.baseURL }
    var model: String { provider.model }
    let session: URLSession
    /// When false, we send `chat_template_kwargs: {"enable_thinking": false}` so the model skips
    /// its hidden chain-of-thought. Measured ~48x latency win (43s -> 0.9s for "hola") with an
    /// identical answer; tool-calling and memory recall still work. Toggle to true to re-enable.
    /// Only sent to local mlx — cloud providers reject `chat_template_kwargs`.
    let enableThinking: Bool
    let generationTimeout: Duration

    init(provider: ModelProvider = ModelProvider(kind: .local),
         session: URLSession = .shared,
         enableThinking: Bool = false,
         generationTimeout: Duration = .seconds(120)) {
        self.provider = provider
        self.session = session
        self.enableThinking = enableThinking
        self.generationTimeout = generationTimeout
    }

    /// Maps a non-2xx HTTP status to a clear Spanish, provider-prefixed message.
    static func errorMessage(status: Int, provider: ModelProvider) -> String {
        let p = provider.kind.displayName
        switch status {
        case 401: return "\(p): API key inválida o ausente."
        case 403: return "\(p): acceso denegado (revisa la API key/permisos)."
        case 429: return "\(p): rate limit — intenta de nuevo en un momento."
        default:  return "\(p): error HTTP \(status)."
        }
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
                    for m in options.history {
                        messages.append(["role": m.role.rawValue, "content": m.content])
                    }
                    messages.append(["role": "user", "content": prompt])

                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "max_tokens": options.maxTokens,
                        "temperature": options.temperature,
                        "stream": true,   // SSE: tokens arrive incrementally so the UI can render live.
                    ]
                    // Skip the model's hidden chain-of-thought (~48x faster; see `enableThinking`).
                    // Cloud providers reject this kwarg, so only send it to local mlx.
                    if provider.kind.isLocalMLX {
                        body["chat_template_kwargs"] = ["enable_thinking": enableThinking]
                    }
                    if !tools.isEmpty {
                        body["tools"] = tools.map { type(of: $0).functionSpec }
                    }

                    var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let key = provider.apiKey, !key.isEmpty {
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    req.timeoutInterval = Double(generationTimeout.components.seconds)

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // Drain the provider's error body — it usually states the exact reason
                        // (e.g. "model X not found", "free tier does not include …") — and append
                        // it to the mapped message so the user/log sees the real cause.
                        var raw = ""
                        for try await line in bytes.lines { raw += line; if raw.count > 2048 { break } }
                        let base = Self.errorMessage(status: http.statusCode, provider: provider)
                        throw RuntimeError.generationFailed(raw.isEmpty ? base : "\(base) — \(raw)")
                    }

                    // Parse the OpenAI SSE stream: `data: {chunk}` lines, ending with `data: [DONE]`.
                    // Emit each content delta as a token (live); accumulate tool-call deltas (which
                    // arrive fragmented by index) and emit them at the end so the Agent tool loop
                    // sees the same shape as before.
                    var visible = ""
                    var toolNames: [Int: String] = [:]
                    var toolArgs: [Int: String] = [:]
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let delta = (chunk["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
                        else { continue }
                        if let piece = delta["content"] as? String, !piece.isEmpty {
                            visible += piece
                            continuation.yield(.token(piece))
                        }
                        if let calls = delta["tool_calls"] as? [[String: Any]] {
                            for call in calls {
                                let idx = (call["index"] as? Int) ?? 0
                                let fn = call["function"] as? [String: Any]
                                if let n = fn?["name"] as? String, !n.isEmpty { toolNames[idx, default: ""] += n }
                                if let a = fn?["arguments"] as? String { toolArgs[idx, default: ""] += a }
                            }
                        }
                    }

                    for idx in toolNames.keys.sorted() {
                        let args = toolArgs[idx].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                        continuation.yield(.toolCallStarted(name: toolNames[idx] ?? "", args: args))
                    }
                    continuation.yield(.completed(GenerationResult(
                        text: GemmaToolCallParser.strip(visible),
                        metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    continuation.finish()
                } catch let e as RuntimeError {
                    // Already a clear, provider-prefixed message (e.g. the non-2xx mapping) — pass through.
                    continuation.finish(throwing: e)
                } catch {
                    let p = provider.kind.displayName
                    let msg = (error is URLError) ? "\(p): sin conexión." : "\(p): \(error.localizedDescription)"
                    continuation.finish(throwing: RuntimeError.generationFailed(msg))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
