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
                    // Cloud providers need a bearer key. If none is set, fail with a clear,
                    // actionable message instead of the provider's opaque 403 "not authenticated".
                    if !provider.kind.isLocalMLX, (provider.apiKey ?? "").isEmpty {
                        throw RuntimeError.generationFailed("\(provider.kind.displayName): falta la API key — agrégala en Settings → Modelos (y sal del campo para guardarla).")
                    }
                    let effectiveMaxTokens = max(options.maxTokens, 4096)
                    let isClaude = provider.kind == .claude
                    let endpoint = isClaude ? "messages" : "chat/completions"
                    var req = URLRequest(url: baseURL.appendingPathComponent(endpoint))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = Double(generationTimeout.components.seconds)

                    if isClaude {
                        if let key = provider.apiKey, !key.isEmpty {
                            req.setValue(key, forHTTPHeaderField: "x-api-key")
                        }
                        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                        var claudeMessages: [[String: Any]] = []
                        for m in options.history {
                            claudeMessages.append(["role": m.role == .assistant ? "assistant" : "user", "content": m.content])
                        }
                        claudeMessages.append(["role": "user", "content": prompt])

                        var body: [String: Any] = [
                            "model": model,
                            "messages": claudeMessages,
                            "max_tokens": effectiveMaxTokens,
                            "stream": true,
                        ]
                        if let sys = options.systemPrompt, !sys.isEmpty {
                            body["system"] = sys
                        }
                        if !tools.isEmpty {
                            body["tools"] = tools.map { t in
                                let spec = type(of: t).functionSpec
                                let fn = spec["function"] as? [String: Any] ?? [:]
                                return [
                                    "name": fn["name"] as? String ?? "",
                                    "description": fn["description"] as? String ?? "",
                                    "input_schema": fn["parameters"] as? [String: Any] ?? [:]
                                ]
                            }
                        }
                        req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    } else {
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
                            "max_tokens": effectiveMaxTokens,
                            "temperature": options.temperature,
                            "stream": true,
                        ]
                        if provider.kind.isLocalMLX {
                            body["chat_template_kwargs"] = ["enable_thinking": enableThinking]
                        }
                        if !tools.isEmpty {
                            body["tools"] = tools.map { type(of: $0).functionSpec }
                        }
                        if let key = provider.apiKey, !key.isEmpty {
                            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        }
                        req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    }

                    // Issue the request, retrying transient 429s (e.g. Cerebras free-tier
                    // "queue_exceeded") a few times with linear backoff before surfacing.
                    var bytesOpt: URLSession.AsyncBytes?
                    var attempt = 0
                    while bytesOpt == nil {
                        let (b, response) = try await session.bytes(for: req)
                        if let http = response as? HTTPURLResponse {
                            if http.statusCode == 429, attempt < 3 {
                                attempt += 1
                                try await Task.sleep(for: .milliseconds(700 * attempt))
                                continue
                            }
                            if !(200..<300).contains(http.statusCode) {
                                // Drain the provider's error body — it usually states the exact
                                // reason — and append it so the user/log sees the real cause.
                                var raw = ""
                                for try await line in b.lines { raw += line; if raw.count > 2048 { break } }
                                let base = Self.errorMessage(status: http.statusCode, provider: provider)
                                throw RuntimeError.generationFailed(raw.isEmpty ? base : "\(base) — \(raw)")
                            }
                        }
                        bytesOpt = b
                    }
                    let bytes = bytesOpt!

                    // Parse the OpenAI SSE stream: `data: {chunk}` lines, ending with `data: [DONE]`.
                    var visible = ""
                    // Compuerta de sintaxis de herramienta: todo texto que llega al usuario pasa
                    // por ella (ver `ToolSyntaxStreamGate`). En el camino de Anthropic las
                    // llamadas vienen estructuradas, así que no se aplica la regla de inicio.
                    var gate = ToolSyntaxStreamGate(checksStart: !isClaude)
                    func emitVisible(_ shown: String) {
                        if !shown.isEmpty { continuation.yield(.token(shown)) }
                    }
                    var inThoughtTag = false
                    var thoughtBuffer = ""
                    var toolNames: [Int: String] = [:]
                    var toolArgs: [Int: String] = [:]
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }

                        if isClaude {
                            let type = chunk["type"] as? String
                            if type == "content_block_delta" {
                                if let delta = chunk["delta"] as? [String: Any] {
                                    let deltaType = delta["type"] as? String
                                    if deltaType == "text_delta", let piece = delta["text"] as? String, !piece.isEmpty {
                                        visible += piece
                                        emitVisible(gate.feed(piece))
                                    } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                                        let idx = (chunk["index"] as? Int) ?? 0
                                        toolArgs[idx, default: ""] += partial
                                    }
                                }
                            } else if type == "content_block_start" {
                                if let block = chunk["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                                    let idx = (chunk["index"] as? Int) ?? 0
                                    if let name = block["name"] as? String {
                                        toolNames[idx] = name
                                    }
                                }
                            } else if type == "message_stop" {
                                break
                            }
                            continue
                        }

                        guard let delta = (chunk["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
                        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                            continuation.yield(.thought(reasoning))
                        }
                        if let piece = delta["content"] as? String, !piece.isEmpty {
                            visible += piece

                            if inThoughtTag {
                                thoughtBuffer += piece
                                if let endRange = thoughtBuffer.range(of: "</thought>") ??
                                                  thoughtBuffer.range(of: "</think>") ??
                                                  thoughtBuffer.range(of: "<channel|>") ??
                                                  thoughtBuffer.range(of: "<|channel|>") ??
                                                  thoughtBuffer.range(of: "<|end_of_thought|>") {
                                    let inside = String(thoughtBuffer[..<endRange.lowerBound])
                                    let remainder = String(thoughtBuffer[endRange.upperBound...])
                                    if !inside.isEmpty { continuation.yield(.thought(inside)) }
                                    thoughtBuffer = ""
                                    inThoughtTag = false
                                    if !remainder.isEmpty {
                                        emitVisible(gate.feed(remainder))
                                    }
                                } else {
                                    // Emit thought incrementally while holding back potential partial closing tag
                                    if thoughtBuffer.count > 25 {
                                        let safeIdx = thoughtBuffer.index(thoughtBuffer.endIndex, offsetBy: -25)
                                        let emit = String(thoughtBuffer[..<safeIdx])
                                        thoughtBuffer = String(thoughtBuffer[safeIdx...])
                                        continuation.yield(.thought(emit))
                                    }
                                }
                                continue
                            }

                            // Check if a thought tag starts in content
                            if piece.contains("<thought>") || piece.contains("<think>") ||
                               piece.contains("<|channel|>thought") || piece.contains("<|channel>thought") {
                                inThoughtTag = true
                                let startTags = ["<thought>", "<think>", "<|channel|>thought", "<|channel>thought"]
                                var remainder = piece
                                for tag in startTags {
                                    if let r = remainder.range(of: tag) {
                                        let before = String(remainder[..<r.lowerBound])
                                        remainder = String(remainder[r.upperBound...])
                                        if !before.isEmpty {
                                            emitVisible(gate.feed(before))
                                        }
                                        break
                                    }
                                }
                                thoughtBuffer = remainder
                                continue
                            }

                            emitVisible(gate.feed(piece))
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

                    // Suelta (o descarta) lo que la compuerta aún retenía al terminar el mensaje.
                    emitVisible(gate.finish())

                    // Flush any remaining thought buffer if stream ended without explicit close
                    if inThoughtTag && !thoughtBuffer.isEmpty {
                        continuation.yield(.thought(thoughtBuffer))
                    }

                    // Also extract any text-encoded tool calls emitted by models in delta["content"]
                    let (extractedCalls, cleanText) = GemmaToolCallParser.parseToolCalls(from: visible)
                    for (i, call) in extractedCalls.enumerated() {
                        let baseIdx = (toolNames.keys.max() ?? -1) + 1 + i
                        toolNames[baseIdx] = call.name
                        toolArgs[baseIdx] = call.args
                    }

                    for idx in toolNames.keys.sorted() {
                        let args = toolArgs[idx].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                        continuation.yield(.toolCallStarted(name: toolNames[idx] ?? "", args: args))
                    }

                    // Si la compuerta descartó algo que resultó no ser una llamada ejecutable
                    // (sin cerrar, o tokens de control sueltos), el usuario aún debe ver la
                    // parte limpia que no llegó a emitirse.
                    //   Salvo cuando lo descartado era sintaxis de INVOCACION (`<function_calls>`,
                    // `<invoke …>`): `strip` no la reconoce entera y deja restos como
                    // ` name="browser_wait">` en `cleanText`, y esta via los sacaba a pantalla
                    // (chat del 2026-11-11, seq 20). Ese resto no es prosa; el bucle del agente lo
                    // trata como llamada rota (`BrokenToolCallDetector`).
                    let eraInvocacion = BrokenToolCallDetector.marcasDeInvocacion.contains { visible.contains($0) }
                    if gate.phase == .suppressing && toolNames.isEmpty && !cleanText.isEmpty && !eraInvocacion {
                        emitVisible(gate.remainder(ofCleanText: cleanText))
                    }

                    continuation.yield(.completed(GenerationResult(
                        text: cleanText,
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
