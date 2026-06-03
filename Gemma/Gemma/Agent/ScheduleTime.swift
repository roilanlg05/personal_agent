import Foundation

/// Deterministic conversion between human ISO-8601 LOCAL datetimes (what the model emits) and
/// epoch seconds (what the schedule API uses). The model never computes epoch; it passes a
/// local wall-clock string and this converts it in the device's timezone.
enum ScheduleTime {
    private static func df(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    /// Parse "yyyy-MM-dd'T'HH:mm" (or with space, or date-only → midnight) in local time → epoch.
    static func epoch(fromISO s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            if let d = df(fmt).date(from: t) { return d.timeIntervalSince1970 }
        }
        if let d = df("yyyy-MM-dd").date(from: t) { return d.timeIntervalSince1970 } // date-only → 00:00
        return nil
    }

    /// Epoch → "yyyy-MM-dd'T'HH:mm" in local time (for echoing events back to the model/user).
    static func iso(fromEpoch e: Double) -> String {
        df("yyyy-MM-dd'T'HH:mm").string(from: Date(timeIntervalSince1970: e))
    }

    /// Human-friendly local rendering for tool result text, e.g. "Tue 2026-06-09 08:00".
    static func human(fromEpoch e: Double) -> String {
        df("EEE yyyy-MM-dd HH:mm").string(from: Date(timeIntervalSince1970: e))
    }
}
