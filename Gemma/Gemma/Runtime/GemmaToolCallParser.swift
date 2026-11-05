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
    static func parseToolCalls(from text: String) -> (toolCalls: [ExtractedToolCall], cleanText: String) {
        var calls: [ExtractedToolCall] = []
        var clean = text

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
