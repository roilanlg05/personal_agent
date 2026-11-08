import Foundation

public final class LlamaCppRuntime: ModelRuntime, ToolCallingRuntime, @unchecked Sendable {
    public nonisolated let identifier: String = "llamacpp-metal"

    private var context: LlamaContext?
    /// Ventana con la que se cargó el contexto, para que `Agent` pueda decidir si un bloque
    /// grande cabe antes de añadirlo al prompt. `nil` mientras no hay modelo cargado: en el
    /// bucle del agente eso no pasa, porque la primera `generate` carga el modelo mucho antes
    /// de que haya un resultado de herramienta al que pegar nada.
    private var loadedContextLength: Int?
    private var lastMetrics: RuntimeMetrics?
    private var isGenerating: Bool = false
    private let lock = NSLock()

    public init() {}

    public func isLoaded() async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return context != nil
    }

    public static func defaultModelURL() -> URL? {
        let fm = FileManager.default
        // 0. Explicit custom path saved by user
        if let customPath = UserDefaults.standard.string(forKey: "customGGUFPath"),
           fm.fileExists(atPath: customPath) {
            return URL(fileURLWithPath: customPath)
        }
        // 1. Documents directory (iOS Files app / AirDrop)
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            if let files = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil),
               let gguf = files.first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                return gguf
            }
        }
        // 2. App Bundle
        if let bundled = Bundle.main.urls(forResourcesWithExtension: "gguf", subdirectory: nil)?.first {
            return bundled
        }
        // 3. User Downloads (macOS & Simulator convenience)
        let downloadsPath = NSHomeDirectory() + "/Downloads"
        if let downloadsURL = URL(string: "file://" + downloadsPath),
           let files = try? fm.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: nil),
           let gguf = files.first(where: { $0.pathExtension.lowercased() == "gguf" }) {
            return gguf
        }
        return nil
    }

    public static func importModel(from sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw RuntimeError.loadFailed("No se pudo acceder al directorio Documents de la app.")
        }
        let destURL = docs.appendingPathComponent(sourceURL.lastPathComponent)
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: sourceURL, to: destURL)
        UserDefaults.standard.set(destURL.path, forKey: "customGGUFPath")
        return destURL
    }

    public func load(options: ModelLoadOptions) async throws {
        let ctx = try LlamaContext.createContext(
            path: options.modelPath.path,
            contextLength: options.contextLength,
            useGPU: options.backend == .gpu
        )
        lock.lock()
        self.context = ctx
        self.loadedContextLength = options.contextLength
        lock.unlock()
    }

    /// Ventana que se declara mientras no hay modelo cargado.
    ///
    /// Procedencia: es la que usa `ensureLoaded` cuando carga el modelo por su cuenta
    /// (`ModelLoadOptions(modelPath: modelURL, contextLength: 8192, backend: .gpu)`), o sea la
    /// ventana con la que este runtime se va a cargar si nadie le dice otra cosa.
    ///
    /// Se declara en lugar de devolver `nil` a propósito: `nil` significa «no hay ventana» y
    /// quien decide lo trata como «cabe». Para el camino on-device eso seria mentira, y el
    /// error caeria del lado caro — inyectar 17 KB en una ventana que no los aguanta hace que
    /// `LlamaContext` deslice y se coma el prompt del sistema, donde viven las reglas de
    /// seguridad. Mejor declarar una ventana estrecha de mas que ninguna.
    public nonisolated static let fallbackContextTokens = 8192

    public var contextTokenBudget: Int? {
        lock.lock()
        defer { lock.unlock() }
        return loadedContextLength ?? Self.fallbackContextTokens
    }

    private func ensureLoaded() async throws {
        lock.lock()
        let isLoaded = (self.context != nil)
        lock.unlock()
        if !isLoaded {
            guard let modelURL = Self.defaultModelURL() else {
                throw RuntimeError.loadFailed("No se encontró ningún archivo .gguf en la carpeta Documents de la app ni en Descargas.")
            }
            try await load(options: ModelLoadOptions(modelPath: modelURL, contextLength: 8192, backend: .gpu))
        }
    }

    /// Pre-warm model weights and Metal pipelines on launch so the first user query runs with zero cold start.
    public func preheat() async throws {
        lock.lock()
        if isGenerating {
            lock.unlock()
            return
        }
        isGenerating = true
        lock.unlock()
        defer {
            lock.lock()
            isGenerating = false
            lock.unlock()
        }

        try await ensureLoaded()
        lock.lock()
        guard let ctx = self.context else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Clear context completely to leave it pristine for user prompts
        await ctx.clear()
    }

    public func unload() async {
        lock.lock()
        self.context = nil
        lock.unlock()
    }

    public func currentMetrics() async -> RuntimeMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return lastMetrics
    }

    public func generate(
        prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error> {
        await generate(prompt: prompt, tools: [], options: options)
    }

    public func generate(
        prompt: String,
        tools: [AgentTool],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                while true {
                    self.lock.lock()
                    if !self.isGenerating {
                        self.isGenerating = true
                        self.lock.unlock()
                        break
                    }
                    self.lock.unlock()
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                defer {
                    self.lock.lock()
                    self.isGenerating = false
                    self.lock.unlock()
                }

                do {
                    try await self.ensureLoaded()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                lock.lock()
                guard let ctx = self.context else {
                    lock.unlock()
                    continuation.finish(throwing: RuntimeError.notLoaded)
                    return
                }
                lock.unlock()

                let start = DispatchTime.now().uptimeNanoseconds
                var firstTokenTime: UInt64? = nil
                var fullText = ""
                var tokenCount = 0

                do {
                    // If tools are provided, inject their declarations into the prompt
                    var toolsPrompt = ""
                    if !tools.isEmpty {
                        toolsPrompt = "\n[AVAILABLE TOOLS]\nYou can call tools to perform actions or look up information. For simple greetings (like 'hola', 'hello') or casual chat, NEVER call any tools — reply directly with text. To call a tool, respond with ONLY: call:tool_name{\"param\": \"value\"}\nTools available:\n"
                        for t in tools {
                            let spec = type(of: t).functionSpec
                            let fn = spec["function"] as? [String: Any] ?? [:]
                            let name = fn["name"] as? String ?? ""
                            let desc = fn["description"] as? String ?? ""
                            var paramsDesc = "{}"
                            if let params = fn["parameters"] as? [String: Any],
                               let data = try? JSONSerialization.data(withJSONObject: params, options: []),
                               let str = String(data: data, encoding: .utf8) {
                                paramsDesc = str
                            }
                            toolsPrompt += "- \(name): \(desc). Schema: \(paramsDesc)\n"
                        }
                        toolsPrompt += "[END TOOLS]\n"
                    }

                    // Build full prompt including history if present
                    var fullPrompt = ""
                    var systemText = options.systemPrompt ?? ""
                    if !toolsPrompt.isEmpty {
                        systemText += toolsPrompt
                    }

                    // Extract injected context (Current date and time, recall notes) from the user prompt
                    var userMessage = prompt
                    var injectedContext = ""

                    if prompt.hasPrefix("Current date and time:") || prompt.hasPrefix("[Reference datetime:") {
                        let paragraphs = prompt.components(separatedBy: "\n\n")
                        var contextList: [String] = []
                        var userParts: [String] = []
                        var stillInContext = true

                        for p in paragraphs {
                            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
                            if stillInContext {
                                if trimmed.hasPrefix("Current date and time:") ||
                                   trimmed.hasPrefix("[Reference datetime:") ||
                                   trimmed.hasPrefix("Last interaction with user:") ||
                                   trimmed.hasPrefix("Memory/context") ||
                                   trimmed.hasPrefix("Wake/background context") ||
                                   trimmed.hasPrefix("You are speaking with") ||
                                   trimmed.hasPrefix("What you remember") ||
                                   trimmed.hasPrefix("Episodic summaries") ||
                                   trimmed.hasPrefix("Recent conversation") ||
                                   trimmed.hasPrefix("(You were just reflecting on:") ||
                                   trimmed.hasPrefix("You were reflecting on:") {
                                    contextList.append(trimmed)
                                } else {
                                    stillInContext = false
                                    userParts.append(p)
                                }
                            } else {
                                userParts.append(p)
                            }
                        }
                        if !contextList.isEmpty {
                            injectedContext = contextList.joined(separator: "\n\n")
                            userMessage = userParts.joined(separator: "\n\n")
                            if userMessage.hasPrefix("User request:\n") {
                                userMessage = String(userMessage.dropFirst("User request:\n".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }

                    if !injectedContext.isEmpty {
                        systemText += "\n\n[CONTEXT & MEMORY - Strictly internal reference. NEVER greet with or recite the date/time unprompted to the user]:\n\(injectedContext)\n"
                    }

                    let isGemma4 = Self.defaultModelURL()?.lastPathComponent.lowercased().contains("gemma-4") == true ||
                                   Self.defaultModelURL()?.lastPathComponent.lowercased().contains("gemma4") == true

                    let turnStart = isGemma4 ? "<|turn>" : "<start_of_turn>"
                    let turnEnd = isGemma4 ? "<turn|>" : "<end_of_turn>"

                    if !systemText.isEmpty {
                        fullPrompt += "\(turnStart)system\n\(systemText)\(turnEnd)\n"
                    }

                    // Retain recent turns (up to 40) so the conversation maintains full continuity and never forgets details discussed earlier
                    let historyToInclude = options.history.suffix(40)
                    for msg in historyToInclude {
                        let roleStr: String = {
                            switch msg.role {
                            case .system: return "system"
                            case .user: return "user"
                            case .assistant: return "model"
                            }
                        }()
                        fullPrompt += "\(turnStart)\(roleStr)\n\(msg.content)\(turnEnd)\n"
                    }

                    let trimmedUser = userMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let isShortGreeting = ["hola", "hola!", "hola gemma", "buenos días", "buenas tardes", "buenas noches", "buenas", "hi", "hello", "hey", "qué tal", "que tal"].contains(trimmedUser)
                    let finalUserMessage = isShortGreeting ? "\(userMessage) (Responde de inmediato con calidez y brevedad, sin pensar)" : userMessage
                    fullPrompt += "\(turnStart)user\n\(finalUserMessage)\(turnEnd)\n\(turnStart)model\n"

                    try await ctx.completionInit(prompt: fullPrompt, temperature: Float(options.temperature))

                    var isPotentiallyToolCall: Bool? = nil
                    var inThoughtChannel = false
                    var thoughtBuffer = ""
                    var streamBuffer = ""
                    var reachedStop = false

                    let stopSequences = [
                        "<end_of_turn>",
                        "<|end_of_turn|>",
                        "<turn|>",
                        "<|turn|>",
                        "</s>",
                        "<eos>"
                    ]

                    let thoughtStartTags = [
                        "<thought>",
                        "<think>",
                        "<|thought|>",
                        "<|think|>",
                        "<|channel|>thought",
                        "<|channel>thought",
                        "<channel>thought",
                        "[Start thinking]",
                        "[start thinking]",
                        "[Thinking]",
                        "[thinking]",
                        "[Thought]",
                        "[thought]"
                    ]

                    let thoughtEndTags = [
                        "</thought>",
                        "</think>",
                        "<channel|>",
                        "<|channel|>",
                        "<|end_of_thought|>",
                        "[End thinking]",
                        "[end thinking]",
                        "[/Thinking]",
                        "[/thinking]",
                        "[/Thought]",
                        "[/thought]"
                    ]

                    let effectiveMaxTokens = max(options.maxTokens, 2048)

                    while tokenCount < effectiveMaxTokens {
                        if Task.isCancelled { break }
                        let (piece, isDone) = try await ctx.completionNextToken()
                        if firstTokenTime == nil && !piece.isEmpty {
                            firstTokenTime = DispatchTime.now().uptimeNanoseconds
                        }
                        if !piece.isEmpty {
                            fullText += piece
                            tokenCount += 1

                            // Check if stop sequence reached
                            reachedStop = false
                            for stopSeq in stopSequences {
                                if let range = fullText.range(of: stopSeq) {
                                    fullText = String(fullText[..<range.lowerBound])
                                    reachedStop = true
                                    break
                                }
                            }
                            if reachedStop {
                                break
                            }

                            if inThoughtChannel {
                                thoughtBuffer += piece

                                // Check for thought end tag
                                var foundEnd = false
                                for endTag in thoughtEndTags {
                                    if let range = thoughtBuffer.range(of: endTag) {
                                        let insideThought = String(thoughtBuffer[..<range.lowerBound])
                                        let remainder = String(thoughtBuffer[range.upperBound...])
                                        if !insideThought.isEmpty {
                                            continuation.yield(.thought(insideThought))
                                        }
                                        thoughtBuffer = ""
                                        inThoughtChannel = false
                                        foundEnd = true
                                        isPotentiallyToolCall = nil
                                        if !remainder.isEmpty {
                                            streamBuffer += remainder
                                        }
                                        break
                                    }
                                }
                                if !foundEnd {
                                    // Hold back possible partial end tag
                                    var holdBack = 0
                                    for k in (1...min(thoughtBuffer.count, 25)).reversed() {
                                        let suffix = String(thoughtBuffer.suffix(k))
                                        if thoughtEndTags.contains(where: { $0.hasPrefix(suffix) }) {
                                            holdBack = k
                                            break
                                        }
                                    }
                                    let safeCount = thoughtBuffer.count - holdBack
                                    if safeCount > 0 {
                                        let safeIdx = thoughtBuffer.index(thoughtBuffer.startIndex, offsetBy: safeCount)
                                        let toEmit = String(thoughtBuffer[..<safeIdx])
                                        thoughtBuffer = String(thoughtBuffer[safeIdx...])
                                        continuation.yield(.thought(toEmit))
                                    }
                                }
                            } else {
                                streamBuffer += piece

                                // Check for thought start tag in streamBuffer
                                var foundStart = false
                                for startTag in thoughtStartTags {
                                    if let range = streamBuffer.range(of: startTag) {
                                        let prefix = String(streamBuffer[..<range.lowerBound])
                                        let remainder = String(streamBuffer[range.upperBound...])
                                        let cleanPrefix = GemmaToolCallParser.strip(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !cleanPrefix.isEmpty && isPotentiallyToolCall == false {
                                            continuation.yield(.token(cleanPrefix))
                                        }
                                        streamBuffer = ""
                                        inThoughtChannel = true
                                        thoughtBuffer = remainder
                                        foundStart = true
                                        break
                                    }
                                }

                                if !foundStart {
                                    if isPotentiallyToolCall == nil {
                                        let trimmed = streamBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !tools.isEmpty {
                                            if trimmed.hasPrefix("<") || trimmed.hasPrefix("call") || trimmed.hasPrefix("{") || trimmed.hasPrefix("`") || trimmed.hasPrefix("[") {
                                                isPotentiallyToolCall = true
                                            } else if trimmed.count >= 4 {
                                                isPotentiallyToolCall = false
                                            }
                                        } else {
                                            isPotentiallyToolCall = false
                                        }
                                    }

                                    // Stream token only if confirmed NOT a tool call invocation
                                    if isPotentiallyToolCall == false {
                                        // Hold back any suffix that could be the start of a stop sequence OR thought start tag OR model control tag
                                        var holdBack = 0
                                        let candidates = stopSequences + thoughtStartTags + [
                                            "<|turn", "<turn|", "<|channel", "<channel|", "<|think", "<|thought", "<|tool", "<tool|", "<|call", "call:",
                                            "[Start", "[start", "[Thinking", "[thinking", "[Thought", "[thought"
                                        ]
                                        for k in (1...min(streamBuffer.count, 25)).reversed() {
                                            let suffix = String(streamBuffer.suffix(k))
                                            if candidates.contains(where: { $0.hasPrefix(suffix) }) || "<|".hasPrefix(suffix) || "<".hasPrefix(suffix) || "[".hasPrefix(suffix) {
                                                holdBack = k
                                                break
                                            }
                                        }
                                        let safeCount = streamBuffer.count - holdBack
                                        if safeCount > 0 {
                                            let safeIdx = streamBuffer.index(streamBuffer.startIndex, offsetBy: safeCount)
                                            let toEmit = String(streamBuffer[..<safeIdx])
                                            streamBuffer = String(streamBuffer[safeIdx...])
                                            var cleanPiece = toEmit
                                                .replacingOccurrences(of: "<channel|>", with: "")
                                                .replacingOccurrences(of: "<|channel|>", with: "")
                                                .replacingOccurrences(of: "<|channel>", with: "")
                                                .replacingOccurrences(of: "<turn|>", with: "")
                                                .replacingOccurrences(of: "<|turn|>", with: "")
                                                .replacingOccurrences(of: "<|turn>", with: "")
                                                .replacingOccurrences(of: "<turn|", with: "")
                                                .replacingOccurrences(of: "<|turn", with: "")
                                                .replacingOccurrences(of: "<|think|>", with: "")
                                                .replacingOccurrences(of: "<|thought|>", with: "")
                                                .replacingOccurrences(of: "</thought>", with: "")
                                                .replacingOccurrences(of: "</think>", with: "")
                                                .replacingOccurrences(of: "<start_of_turn>model\n", with: "")
                                                .replacingOccurrences(of: "<start_of_turn>model", with: "")
                                                .replacingOccurrences(of: "<start_of_turn>", with: "")
                                                .replacingOccurrences(of: "<end_of_turn>", with: "")

                                            cleanPiece = cleanPiece.replacingOccurrences(of: #"(?s)</?[a-zA-Z0-9_\-|:]+>?|\s*<\|\s*$"#, with: "", options: .regularExpression)
                                            cleanPiece = cleanPiece.replacingOccurrences(of: #"(?s)(?:execute_tool|tool_call|channel|turn)>"#, with: "", options: .regularExpression)
                                            let trimmedClean = cleanPiece.trimmingCharacters(in: .whitespacesAndNewlines)
                                            if trimmedClean == "<" || trimmedClean == "<|" || trimmedClean.hasPrefix("<|") || trimmedClean.hasSuffix("<|") || trimmedClean.hasPrefix("</") || trimmedClean == "<turn" || trimmedClean == "<channel" || trimmedClean.contains("execute_tool") || trimmedClean.contains("tool_call") {
                                                cleanPiece = ""
                                            }
                                            if !cleanPiece.isEmpty {
                                                continuation.yield(.token(cleanPiece))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if isDone {
                            break
                        }
                    }

                    // Flush any remaining safe text from streamBuffer
                    if isPotentiallyToolCall != true && !streamBuffer.isEmpty {
                        var safeEnd = streamBuffer
                        for stopSeq in stopSequences {
                            if let range = safeEnd.range(of: stopSeq) {
                                safeEnd = String(safeEnd[..<range.lowerBound])
                            }
                        }
                        var clean = GemmaToolCallParser.strip(safeEnd)
                        clean = clean.replacingOccurrences(of: #"(?s)<\|?[a-zA-Z0-9_\-|]*>?"#, with: "", options: .regularExpression)
                        if !clean.isEmpty && !clean.hasPrefix("<|") && clean != "<" {
                            continuation.yield(.token(clean))
                        }
                        streamBuffer = ""
                    }

                    let end = DispatchTime.now().uptimeNanoseconds
                    let elapsed = Double(end - start) / 1_000_000_000.0
                    let ttft = firstTokenTime != nil ? Double(firstTokenTime! - start) / 1_000_000_000.0 : elapsed

                    let metrics = RuntimeMetrics(
                        tokensGenerated: tokenCount,
                        elapsedSeconds: elapsed,
                        timeToFirstTokenSeconds: ttft,
                        peakResidentMemoryBytes: 0,
                        draftAcceptanceRate: nil
                    )

                    lock.lock()
                    self.lastMetrics = metrics
                    lock.unlock()

                    // Parse any tool calls from the generation
                    let (parsedCalls, cleanText) = GemmaToolCallParser.parseToolCalls(from: fullText)
                    for call in parsedCalls {
                        continuation.yield(.toolCallStarted(name: call.name, args: call.args))
                    }

                    // Ensure clean final response is yielded if nothing was streamed yet
                    if parsedCalls.isEmpty && !cleanText.isEmpty {
                        continuation.yield(.completed(GenerationResult(text: cleanText, metrics: metrics)))
                    } else {
                        continuation.yield(.completed(GenerationResult(text: cleanText, metrics: metrics)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
