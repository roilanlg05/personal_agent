import Foundation

/// Single source of truth for memory label normalization. The small E4B often emits whole
/// sentences ("me gusta el sushi") or fragments ("me gusta") as labels; this turns them into
/// clean canonical entities for display and a stable key for dedup. Used by the consolidator,
/// the remember tool, and MemoryStore's dedup so they all agree.
enum MemoryText {
    private static let likePrefixes = [
        "me gustan ", "me gusta ", "le gusta ", "les gusta ",
        "i like ", "i love ", "likes ", "i prefer ", "my "
    ]
    private static let articlePrefixes = ["el ", "la ", "los ", "las ", "the ", "un ", "una ", "unos ", "unas "]

    /// Display label: trimmed, whitespace-collapsed, surrounding punctuation removed, and
    /// leading "I like"/article fillers stripped — but ORIGINAL CASE preserved ("Juan", "Messi").
    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:!¡¿?()[]"))
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for p in likePrefixes + articlePrefixes where lower.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return s
    }

    /// Case-insensitive dedup key derived from the clean label.
    static func dedupKey(_ raw: String) -> String { cleanLabel(raw).lowercased() }

    /// Fillers / non-facts that should never be stored as a memory on their own.
    static func isJunkLabel(_ raw: String) -> Bool {
        let k = dedupKey(raw)
        if k.isEmpty { return true }
        let junk: Set<String> = [
            "me gusta", "me gustan", "le gusta", "i like", "like", "likes", "gusta",
            "preferences", "preferencias", "preference", "stuff", "things", "cosas",
            "it", "that", "this", "eso", "esto", "user", "usuario"
        ]
        return junk.contains(k)
    }
}
