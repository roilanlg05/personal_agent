import BrainContract
import Foundation

struct TasteProfileTool: AgentTool {
    static let name = "taste_profile"
    static let description = "Recall the user's tastes, comparisons and current intent in one domain."
    static let parameters = [
        AgentToolParam(name: "domain", type: .string, description: "Domain such as music or games.", required: true),
        AgentToolParam(name: "situation", type: .string, description: "Current situation, if stated.", required: false)
    ]

    func run(argsJSON: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let domain = (args["domain"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let situation = (args["situation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty, domain.utf8.count <= 128, (situation?.utf8.count ?? 0) <= 320 else {
            return "Specify one taste domain and an optional short situation."
        }
        guard let scope = MemoryToolbox.turnScope, scope.isTyped, let client = scope.client else {
            return "Taste profiles are unavailable on this memory service."
        }
        do {
            let profile = try await client.tasteProfile(domain: domain, threadID: scope.threadID, situation: situation)
            guard profile.subjectID == BrainIdentity.userID else { return "Taste profile unavailable." }
            var lines = ["Enduring tastes and comparisons:"]
            let records = profile.records.filter { $0.subjectID == BrainIdentity.userID && $0.isEnduringTaste }
            lines += Self.describe(records)
            if records.isEmpty { lines.append("None recorded for this domain.") }
            let intent = (profile.currentIntent ?? []).filter { $0.subjectID == BrainIdentity.userID && $0.kind.isCurrentIntent }
            if !intent.isEmpty { lines += ["Current intent (this situation only):"] + Self.describe(intent) }
            let gaps = (profile.missingInformation ?? []).map(\.rawValue)
            if !gaps.isEmpty { lines.append("Missing information: " + gaps.joined(separator: ", ")) }
            lines.append("Offer a familiar choice or variety, or ask one useful question when needed. This profile does not verify playback.")
            return lines.joined(separator: "\n")
        } catch MemoryClient.ClientError.http(404, _) {
            return "Taste profiles are unavailable on this memory service."
        } catch { return "Taste profile unavailable." }
    }

    private static func describe(_ records: [BrainTasteRecord]) -> [String] {
        var remaining = 600
        var lines = [String]()
        for record in records {
            let alternatives = record.alternatives?.joined(separator: ", ")
            let line = [record.kind.rawValue, record.target, alternatives, record.criterion, record.context]
                .compactMap { $0 }.joined(separator: " | ")
            guard line.utf8.count + 1 <= remaining else {
                lines.append("Further records omitted.")
                break
            }
            remaining -= line.utf8.count + 1
            lines.append(line)
        }
        return lines
    }
}
