import Foundation

/// Parses and cleans Gemma native syntax: thought channel `<|channel>thought...<channel|>`,
/// turn tokens `<start_of_turn>`, `<end_of_turn>`, and tool call syntax.
enum GemmaToolCallParser {
    struct ExtractedToolCall: Sendable {
        let name: String
        let args: String
    }

    /// Extracts tool calls from text in formats:
    /// 1. call:tool_name{args}
    /// 2. <execute_tool>tool_name{args}</execute_tool> or <tool_call>...
    /// 3. {"name": "...", "arguments": {...}}
    /// 4. <function name="tool"><parameter name="k">valor</parameter></function>
    static func parseToolCalls(from text: String) -> (toolCalls: [ExtractedToolCall], cleanText: String) {
        var calls: [ExtractedToolCall] = []
        var clean = text

        // Format 4 va PRIMERO: es el único con delimitadores que encierran valores de texto
        // libre (un `selector`, un `text` a teclear), y esos valores pueden contener `call:x{..}`,
        // llaves o JSON que los otros formatos confundirían con llamadas propias. Quitado el
        // bloque entero, los demás ya no lo ven.
        let (xmlCalls, withoutXml) = extractFunctionTagCalls(from: clean)
        calls.append(contentsOf: xmlCalls)
        clean = withoutXml

        // Format 1: call:tool_name{args} or <|call:tool_name{args}> or call:tool_name\n{args}
        let pattern1 = #"(?:<\|)?call:([a-zA-Z0-9_]+)\s*(\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\})(?:>|\s*\|>)?"#
        if let regex1 = try? NSRegularExpression(pattern: pattern1, options: []) {
            let nsText = clean as NSString
            let matches = regex1.matches(in: clean, range: NSRange(location: 0, length: nsText.length))
            for m in matches {
                if m.numberOfRanges >= 3 {
                    let name = nsText.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let args = nsText.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    calls.append(ExtractedToolCall(name: name, args: args.isEmpty ? "{}" : args))
                }
            }
            if !calls.isEmpty {
                clean = regex1.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: nsText.length), withTemplate: "")
            }
        }

        // Format 2: <execute_tool>tool_name{args}</execute_tool> or <tool_call>tool_name{args}</tool_call> or <|tool_call>...
        let patternExecuteTool = #"(?:<execute_tool>|<tool_call>|<\|tool_call>|<\|tool>)\s*([a-zA-Z0-9_]+)\s*(\{.*?\})?\s*(?:</execute_tool>|</tool_call>|<tool_call\|>|<\|tool_call\|>|<tool\|>)"#
        if let regexExec = try? NSRegularExpression(pattern: patternExecuteTool, options: [.dotMatchesLineSeparators]) {
            let nsText = clean as NSString
            let matches = regexExec.matches(in: clean, range: NSRange(location: 0, length: nsText.length))
            for m in matches {
                if m.numberOfRanges >= 2 {
                    let name = nsText.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    var args = "{}"
                    if m.numberOfRanges >= 3 && m.range(at: 2).location != NSNotFound {
                        let extracted = nsText.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !extracted.isEmpty { args = extracted }
                    }
                    calls.append(ExtractedToolCall(name: name, args: args))
                }
            }
            if !matches.isEmpty {
                clean = regexExec.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: nsText.length), withTemplate: "")
            }
        }

        // Format 3: JSON format {"name": "...", "arguments" or "parameters": {...}}
        if calls.isEmpty {
            let pattern2 = #"\{\s*"name"\s*:\s*"([a-zA-Z0-9_]+)"\s*,\s*"(?:arguments|parameters)"\s*:\s*(\{.*?\})\s*\}"#
            if let regex2 = try? NSRegularExpression(pattern: pattern2, options: [.dotMatchesLineSeparators]) {
                let nsText = clean as NSString
                let matches = regex2.matches(in: clean, range: NSRange(location: 0, length: nsText.length))
                for m in matches {
                    if m.numberOfRanges >= 3 {
                        let name = nsText.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                        let args = nsText.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                        calls.append(ExtractedToolCall(name: name, args: args.isEmpty ? "{}" : args))
                    }
                }
                if !calls.isEmpty {
                    clean = regex2.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: nsText.length), withTemplate: "")
                }
            }
        }

        clean = strip(clean)
        return (calls, clean)
    }

    /// Formato `<function name="x"><parameter name="k">v</parameter></function>`: lo que el
    /// modelo emitió como texto en el chat del 2026-11-08 en lugar de un bloque `tool_use`.
    ///
    /// Reglas deliberadas:
    /// - Solo cuenta un bloque CERRADO (`</function>`, o `<function name="x"/>`). Uno sin cerrar
    ///   puede ser una llamada a medio escribir o prosa que cita la etiqueta; ejecutarlo sería
    ///   inventar una llamada, así que no produce ninguna (y `strip` lo retira del texto visible).
    /// - Los valores se toman literales, sin interpretar: `<`, `>`, comillas, saltos de línea y
    ///   JSON viajan intactos. El valor termina en el primer `</parameter>`.
    /// - `args` sale como OBJETO JSON en cadena, igual que los otros tres formatos y lo que
    ///   consume el resto del pipeline. Los valores son cadenas, salvo los que son un objeto o
    ///   un array JSON válidos, que se incrustan estructurados; los números quedan como cadena
    ///   porque las herramientas aceptan la cadena además del tipo nativo (ver
    ///   `CancelAlarmTool.coerceBool` / `coerceDouble`); el parser no puede conocer el tipo de un
    ///   argumento sin el esquema de la herramienta y convertir `"123"` corrompería cadenas reales.
    ///
    /// Fallo seguro (revisión del 2026-11-08): como el valor termina en el primer `</parameter>`
    /// y el bloque en el primer `</function>`, un valor que contenga uno de esos cierres
    /// truncaría la llamada, y una llamada truncada que se EJECUTA es peor que ninguna
    /// (`browser_fill` tecleando medio texto en la página del usuario sin que él vea por qué).
    /// Por eso un bloque solo se acepta si, quitados sus `<parameter>` bien formados, no queda
    /// nada más que espacio, y si no repite parámetros. Si no, es ambiguo: no produce llamada y
    /// se retira del texto visible desde su inicio hasta el último `</function>`, para que ni
    /// siquiera quede la cola del valor.
    static func extractFunctionTagCalls(from text: String) -> (calls: [ExtractedToolCall], clean: String) {
        let blockPattern = #"<function\s+name\s*=\s*["']([A-Za-z0-9_\-.]+)["']\s*(?:/>|>(.*?)</function\s*>)"#
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: [.dotMatchesLineSeparators]),
              let paramRegex = try? NSRegularExpression(
                pattern: #"<parameter\s+name\s*=\s*["']([^"']+)["']\s*>(.*?)</parameter\s*>"#,
                options: [.dotMatchesLineSeparators]) else { return ([], text) }
        let ns = text as NSString
        let blocks = blockRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !blocks.isEmpty else { return ([], text) }

        var calls: [ExtractedToolCall] = []
        var validRanges: [NSRange] = []
        var ambiguousFrom: Int?
        for b in blocks {
            var params: [String: Any] = [:]
            var ambiguous = false
            if b.range(at: 2).location != NSNotFound {
                let body = ns.substring(with: b.range(at: 2)) as NSString
                let matches = paramRegex.matches(in: body as String, range: NSRange(location: 0, length: body.length))
                for p in matches {
                    let key = body.substring(with: p.range(at: 1))
                    if params[key] != nil { ambiguous = true }
                    let raw = body.substring(with: p.range(at: 2))
                    params[key] = structuredValue(raw) ?? raw
                }
                var leftover = body as String
                for p in matches.reversed() { leftover = (leftover as NSString).replacingCharacters(in: p.range, with: "") }
                if !leftover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ambiguous = true }
            }
            if ambiguous { ambiguousFrom = b.range.location; break }
            let data = (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            calls.append(ExtractedToolCall(name: ns.substring(with: b.range(at: 1)), args: String(decoding: data, as: UTF8.self)))
            validRanges.append(b.range)
        }

        var clean = text as NSString
        if let cut = ambiguousFrom {
            let tail = NSRange(location: cut, length: clean.length - cut)
            let lastClose = clean.range(of: "</function", options: .backwards, range: tail)
            var end = clean.length
            if lastClose.location != NSNotFound {
                let after = clean.range(of: ">", range: NSRange(location: lastClose.location, length: clean.length - lastClose.location))
                end = after.location == NSNotFound ? clean.length : after.location + 1
            }
            clean = clean.replacingCharacters(in: NSRange(location: cut, length: end - cut), with: "") as NSString
        }
        for r in validRanges.reversed() { clean = clean.replacingCharacters(in: r, with: "") as NSString }
        return (calls, clean as String)
    }

    /// Un valor de parámetro que es un objeto o array JSON bien formado; cualquier otra cosa
    /// (incluidos números y `true`) se queda como la cadena que escribió el modelo.
    private static func structuredValue(_ raw: String) -> Any? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, first == "{" || first == "[",
              let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) else { return nil }
        return obj
    }

    /// Strips `<|channel>thought...<channel|>`, `<thought>...</thought>`, turn markers, and tool call invocations.
    static func strip(_ s: String) -> String {
        var clean = s
        // Truncate at any leaked simulated turn markers (model hallucinating subsequent turns)
        if let idx = clean.range(of: "<start_of_turn>")?.lowerBound {
            clean = String(clean[..<idx])
        }
        if let idx = clean.range(of: "<end_of_turn>")?.lowerBound {
            clean = String(clean[..<idx])
        }
        if let idx = clean.range(of: "<|turn>")?.lowerBound {
            clean = String(clean[..<idx])
        }
        if let idx = clean.range(of: "<turn|>")?.lowerBound {
            clean = String(clean[..<idx])
        }
        if let idx = clean.range(of: "<|turn")?.lowerBound {
            clean = String(clean[..<idx])
        }
        if let idx = clean.range(of: "<turn|")?.lowerBound {
            clean = String(clean[..<idx])
        }
        // Strip thought channels: <|channel>thought ... <channel|>, <thought> ... </thought>, <think> ... </think>, or [Start thinking] ... [End thinking]
        // Note: (?:...|$) ensures unclosed thoughts at end-of-stream are also stripped completely!
        clean = clean.replacingOccurrences(of: #"(?is)\[start thinking\].*?(?:\[end thinking\]|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?is)\[thinking\].*?(?:\[/thinking\]|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?is)\[thought\].*?(?:\[/thought\]|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<\|channel\>thought.*?(?:<channel\|>|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<\|channel\|>thought.*?(?:<\|channel\|>|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<thought>.*?(?:</thought>|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<think>.*?(?:</think>|$)"#, with: "", options: .regularExpression)
        // Strip any dangling thought tags
        clean = clean.replacingOccurrences(of: "[Start thinking]", with: "")
        clean = clean.replacingOccurrences(of: "[End thinking]", with: "")
        clean = clean.replacingOccurrences(of: "[start thinking]", with: "")
        clean = clean.replacingOccurrences(of: "[end thinking]", with: "")
        clean = clean.replacingOccurrences(of: "[Thinking]", with: "")
        clean = clean.replacingOccurrences(of: "[/Thinking]", with: "")
        clean = clean.replacingOccurrences(of: "[thinking]", with: "")
        clean = clean.replacingOccurrences(of: "[/thinking]", with: "")
        clean = clean.replacingOccurrences(of: "<thought>", with: "")
        clean = clean.replacingOccurrences(of: "</thought>", with: "")
        clean = clean.replacingOccurrences(of: "<think>", with: "")
        clean = clean.replacingOccurrences(of: "</think>", with: "")
        clean = clean.replacingOccurrences(of: "<|channel>thought", with: "")
        clean = clean.replacingOccurrences(of: "<|channel|>thought", with: "")
        clean = clean.replacingOccurrences(of: "<channel|>", with: "")
        clean = clean.replacingOccurrences(of: "<|channel|>", with: "")
        clean = clean.replacingOccurrences(of: "<|end_of_thought|>", with: "")
        // Strip turn markers
        clean = clean.replacingOccurrences(of: "<start_of_turn>model", with: "")
        clean = clean.replacingOccurrences(of: "<start_of_turn>assistant", with: "")
        clean = clean.replacingOccurrences(of: "<start_of_turn>user", with: "")
        clean = clean.replacingOccurrences(of: "<start_of_turn>system", with: "")
        clean = clean.replacingOccurrences(of: "<start_of_turn>", with: "")
        clean = clean.replacingOccurrences(of: "<end_of_turn>", with: "")
        clean = clean.replacingOccurrences(of: "<|turn>model", with: "")
        clean = clean.replacingOccurrences(of: "<|turn>assistant", with: "")
        clean = clean.replacingOccurrences(of: "<|turn>user", with: "")
        clean = clean.replacingOccurrences(of: "<|turn>system", with: "")
        clean = clean.replacingOccurrences(of: "<turn|>", with: "")
        clean = clean.replacingOccurrences(of: "<|turn|>", with: "")
        clean = clean.replacingOccurrences(of: "<|turn>", with: "")
        clean = clean.replacingOccurrences(of: "<turn|", with: "")
        clean = clean.replacingOccurrences(of: "<|turn", with: "")
        clean = clean.replacingOccurrences(of: "<|channel", with: "")
        clean = clean.replacingOccurrences(of: "<channel|", with: "")
        clean = clean.replacingOccurrences(of: "<|think|>", with: "")
        clean = clean.replacingOccurrences(of: "<|thought|>", with: "")
        // Bloques `<function name=..>..</function>` completos o sin cerrar: una llamada a medio
        // escribir no debe llegar a pantalla, y sin cerrar se descarta hasta el final del texto.
        clean = clean.replacingOccurrences(of: #"(?s)<function\s+name\s*=.*?(?:</function\s*>|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<parameter\s+name\s*=.*?(?:</parameter\s*>|$)"#, with: "", options: .regularExpression)
        // Strip call:tool_name{...}, <execute_tool>...</execute_tool>, <tool_call>...</tool_call>
        clean = clean.replacingOccurrences(of: #"(?s)call:[a-zA-Z0-9_]+\s*\{.*?\}"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<execute_tool>.*?</execute_tool>"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<\|tool_call\>.*?(?:<tool_call\|>|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<\|tool_response\>.*?(?:<tool_response\|>|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)<\|tool\>.*?(?:<tool\|>|$)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "<execute_tool>", with: "")
        clean = clean.replacingOccurrences(of: "</execute_tool>", with: "")
        clean = clean.replacingOccurrences(of: "<tool_call>", with: "")
        clean = clean.replacingOccurrences(of: "</tool_call>", with: "")
        clean = clean.replacingOccurrences(of: "<|tool_call>", with: "")
        clean = clean.replacingOccurrences(of: "<tool_call|>", with: "")
        clean = clean.replacingOccurrences(of: "<|tool_response>", with: "")
        clean = clean.replacingOccurrences(of: "<tool_response|>", with: "")
        clean = clean.replacingOccurrences(of: "<|tool>", with: "")
        clean = clean.replacingOccurrences(of: "<tool|>", with: "")
        // Strip any remaining model control tag prefixes, XML tool tags, or bare tokens like "<|"
        clean = clean.replacingOccurrences(of: #"(?s)</?[a-zA-Z0-9_\-|:]+>?|\s*<\|\s*$"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?s)(?:execute_tool|tool_call|channel|turn)>"#, with: "", options: .regularExpression)
        let trimmedClean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedClean == "<|" || trimmedClean == "<" || trimmedClean.hasPrefix("<|") || trimmedClean.hasSuffix("<|") || trimmedClean.hasPrefix("</") || trimmedClean.contains("execute_tool") || trimmedClean.contains("tool_call") {
            clean = ""
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts the thought reasoning string if present.
    static func extractThought(_ s: String) -> String? {
        if let match = s.range(of: #"(?is)(?<=\[start thinking\]\n?).*?(?=\[end thinking\])"#, options: .regularExpression) {
            let t = String(s[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let match = s.range(of: #"(?is)(?<=\[thinking\]\n?).*?(?=\[/thinking\])"#, options: .regularExpression) {
            let t = String(s[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let match = s.range(of: #"(?s)(?<=<\|channel\>thought\n?).*?(?=<channel\|>)"#, options: .regularExpression) {
            let t = String(s[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let match = s.range(of: #"(?s)(?<=<thought>\n?).*?(?=</thought>)"#, options: .regularExpression) {
            let t = String(s[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let match = s.range(of: #"(?s)(?<=<think>\n?).*?(?=</think>)"#, options: .regularExpression) {
            let t = String(s[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }
}
