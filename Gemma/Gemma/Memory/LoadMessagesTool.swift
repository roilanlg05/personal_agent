import CryptoKit
import Foundation

/// Drill-down (CAPA 1): given a summary's refs (chat_id + message range), return the verbatim
/// chat messages behind it. A READ tool — the model calls it ONLY when a summary lacks the
/// detail it needs, reading just that range. Delegates to `/v1/transcript/range`.
struct LoadMessagesTool: AgentTool {
    static let name = "load_messages"
    static let description = """
    Read exact messages in the active conversation when its authorized sources permit it. \
    Pass its chat_id and only the message range you need.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "chat_id", type: .string, description: "The chat id shown with the summary, e.g. \"g7y\".", required: true),
        AgentToolParam(name: "from", type: .integer, description: "First message number (seq) of the range.", required: true),
        AgentToolParam(name: "to", type: .integer, description: "Last message number (seq); omit for a single message.", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let chatId = ((obj["chat_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func sequence(_ key: String) -> Int? {
            (obj[key] as? Int) ?? (obj[key] as? Double).flatMap(Int.init(exactly:))
                ?? (obj[key] as? String).flatMap(Int.init)
        }
        guard !chatId.isEmpty, let from = sequence("from"), from > 0, from <= Int.max - 79,
              obj["to"] == nil || sequence("to") != nil else { return "need valid chat_id and message sequence" }
        let to = sequence("to") ?? from
        guard to >= from else { return "need a nondecreasing message range" }
        let scope = MemoryToolbox.turnScope
        if let scope, chatId != scope.threadID || scope.authorizedOriginalIDs?.isEmpty == true {
            return "No authorized originals in the requested range."
        }
        let cappedTo = min(to, from + 79)
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(chatId):\(from)-\(cappedTo)") }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let result = try await mem.loadMessages(chatId: chatId, from: from, to: cappedTo)
                let rows = result.messages.filter { row in
                    guard (from...cappedTo).contains(row.seq), ["assistant", "user"].contains(row.role) else { return false }
                    guard let authorized = scope?.authorizedOriginalIDs else { return true }
                    // Match the immutable transcript reference from BrainContract against the actual
                    // row, so a reused sequence or changed text cannot reveal an ungranted source.
                    let fingerprint = SHA256.hash(data: Data("\(chatId)\u{1}\(row.seq)\u{1}\(row.text)".utf8))
                    let id = "transcript:" + fingerprint.map { String(format: "%02x", $0) }.joined()
                    return authorized.contains(id)
                }
                guard !rows.isEmpty else { return "No authorized originals in the requested range." }
                var lines = [String]()
                var remaining = 3600
                for row in rows {
                    let line = "\(row.role == "assistant" ? "Gemma" : "User"): \(row.text)"
                    guard line.utf8.count + 1 <= remaining else { break }
                    lines.append(line)
                    remaining -= line.utf8.count + 1
                }
                let partial = lines.count < rows.count || rows.count < result.messages.count || result.truncated || cappedTo != to
                if partial { lines.append("Some messages were omitted. Quote only the complete lines shown.") }
                return lines.joined(separator: "\n")
            } catch { return "no messages found for chat \(chatId)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
