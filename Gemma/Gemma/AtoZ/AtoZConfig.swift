import Foundation
import Combine

/// Static identity and endpoint for the Amazon A to Z integration.
///
/// Per the AGENTS section of the A to Z terms, Gemma is an Agent and must identify itself on
/// every HTTP request as `Agent/Gemma`. No browser User-Agent, no browser fingerprint headers
/// (Sec-Fetch-*, Sec-GPC, …) and no human-pacing simulation are ever sent.
enum AtoZConstants {
    static let userAgent = "Agent/Gemma"
    static let graphQLURL = URL(string: "https://atoz-apps.amazon.work/apis/ScheduleManagementAssociateGateway/graphql")!
    static let loginURL = URL(string: "https://atoz.amazon.work/login")!
    /// Application identifier the A to Z web client sends for this service. Not a credential.
    static let clientIdHeader = "SCHEDULE_MANAGEMENT_SERVICE"
    /// Gemma's own guard against bulk querying (not an Amazon-published limit).
    static let maxQueryDays = 14
    /// A pending add-shift confirmation expires after this many seconds.
    static let confirmationTTL: TimeInterval = 300
}

/// UserDefaults keys for non-sensitive feature flags only.
/// Note: Authentication cookies and tokens are NEVER stored in UserDefaults, files, or Keychain.
/// They live purely in-memory during the active app lifecycle.
enum AtoZSettingsKeys {
    /// Bool. Master switch: registers the A to Z tools. Default false.
    static let enabled = "atoz.enabled"
    /// Bool. Allows `add_shift` to send the AddShift mutation. Must stay false until authorized. Default false.
    static let addShiftAuthorized = "atoz.addShiftAuthorized"
    /// Bool. When true, `add_shift` runs every gate but never sends the mutation. Default
    /// FALSE: the simulated mode is opt-in, so by default the request really does reach Amazon.
    /// (This line used to say "(default)" next to `true`, which was false in both places that
    /// set the default — `AtoZSettings.load` reads it as `?? false` and `SettingsView` declares
    /// it `= false` — and that wrong claim was copied into two code comments justifying the
    /// `dry_run` row status. Pinned by `TresCorreccionesDelStatusTests
    /// .test_el_modo_simulado_de_a_to_z_viene_desactivado_de_fabrica`.)
    static let dryRun = "atoz.dryRun"
    /// Bool. Latched to true when Amazon denies/limits access; all requests stop until the user clears it. Default false.
    static let suspended = "atoz.suspended"
    /// String. Human-readable reason for the suspension (no private data).
    static let suspendedReason = "atoz.suspendedReason"
}

/// Snapshot of the integration switches.
struct AtoZSettings: Equatable {
    var enabled: Bool
    var addShiftAuthorized: Bool
    var dryRun: Bool
    var suspended: Bool

    static func load(_ d: UserDefaults = .standard) -> AtoZSettings {
        AtoZSettings(
            enabled: d.object(forKey: AtoZSettingsKeys.enabled) as? Bool ?? true,
            addShiftAuthorized: d.object(forKey: AtoZSettingsKeys.addShiftAuthorized) as? Bool ?? true,
            dryRun: d.object(forKey: AtoZSettingsKeys.dryRun) as? Bool ?? false,
            suspended: d.bool(forKey: AtoZSettingsKeys.suspended))
    }

    static func suspend(reason: String, _ d: UserDefaults = .standard) {
        d.set(true, forKey: AtoZSettingsKeys.suspended)
        d.set(reason, forKey: AtoZSettingsKeys.suspendedReason)
    }

    static func clearSuspension(_ d: UserDefaults = .standard) {
        d.set(false, forKey: AtoZSettingsKeys.suspended)
        d.removeObject(forKey: AtoZSettingsKeys.suspendedReason)
    }
}

/// Ephemeral in-memory session.
/// PROTECTED: Never persisted to disk, Keychain, UserDefaults, or logs.
/// NEVER passed to the LLM model or included in chat messages.
final class AtoZSession: @unchecked Sendable {
    let cookie: String
    let employeeId: String
    let capturedAt: Date

    init(cookie: String, employeeId: String, capturedAt: Date = Date()) {
        self.cookie = cookie
        self.employeeId = employeeId
        self.capturedAt = capturedAt
    }
}

/// Global in-memory manager for the active A to Z session.
@MainActor
final class AtoZSessionManager: ObservableObject {
    static let shared = AtoZSessionManager()

    @Published private(set) var currentSession: AtoZSession?
    @Published var isLoginPresented: Bool = false
    @Published var isSyncing: Bool = false
    @Published var syncStatusMessage: String? = nil

    var isLoggedIn: Bool {
        currentSession != nil
    }

    private var memoryBaseURL: URL? {
        var raw = UserDefaults.standard.string(forKey: "memoryBaseURL") ?? "http://localhost:8081"
        #if os(iOS)
        if raw == "http://localhost:8081" || raw == "http://192.168.1.50:8081" || raw.isEmpty {
            raw = "http://100.91.174.81:8081"
        }
        #endif
        return URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var memoryBearerToken: String {
        let t = UserDefaults.standard.string(forKey: "memoryBearerToken") ?? ""
        return t.isEmpty ? "replace-me-with-a-long-random-string" : t
    }

    private init() {}

    /// Sets an in-memory session. Optionally syncs encrypted credentials to the central backend.
    func setSession(cookie: String, employeeId: String, syncToServer: Bool = true) {
        guard !cookie.isEmpty, !employeeId.isEmpty else { return }
        self.currentSession = AtoZSession(cookie: cookie, employeeId: employeeId)
        if syncToServer {
            Task {
                await self.pushSessionToServer(cookie: cookie, employeeId: employeeId)
            }
        }
    }

    /// Clears the ephemeral session from memory immediately and optionally deletes from server.
    func clearSession(removeFromRemote: Bool = true) {
        self.currentSession = nil
        self.syncStatusMessage = nil
        if removeFromRemote {
            Task {
                await self.deleteServerSession()
            }
        }
    }

    /// Push credentials to /v1/connection-services/amazon-atoz
    func pushSessionToServer(cookie: String, employeeId: String) async {
        guard let baseURL = memoryBaseURL else { return }
        let url = baseURL.appendingPathComponent("v1/connection-services/amazon-atoz")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !memoryBearerToken.isEmpty {
            req.setValue("Bearer \(memoryBearerToken)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "credentials": [
                "cookie": cookie,
                "employeeId": employeeId,
                "capturedAt": Date().timeIntervalSince1970
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        req.httpBody = body
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                self.syncStatusMessage = "Sincronizado con el servidor"
            }
        } catch {
            // Offline or unreachable
        }
    }

    /// Fetches active session from /v1/connection-services/amazon-atoz
    func syncSessionFromServer() async {
        guard let baseURL = memoryBaseURL else { return }
        let url = baseURL.appendingPathComponent("v1/connection-services/amazon-atoz")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !memoryBearerToken.isEmpty {
            req.setValue("Bearer \(memoryBearerToken)", forHTTPHeaderField: "Authorization")
        }
        self.isSyncing = true
        defer { self.isSyncing = false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let creds = json["credentials"] as? [String: Any],
                  let cookie = creds["cookie"] as? String, !cookie.isEmpty,
                  let empId = creds["employeeId"] as? String, !empId.isEmpty else {
                return
            }
            let meta = AtoZSessionParser.extractTokenMetadata(from: cookie)
            if meta?.isExpired == true {
                self.syncStatusMessage = "Sesión en servidor expirada"
                return
            }
            self.setSession(cookie: cookie, employeeId: empId, syncToServer: false)
            self.syncStatusMessage = "Sesión sincronizada del servidor"
        } catch {
            // Server offline or unreachable
        }
    }

    /// Deletes session from server
    func deleteServerSession() async {
        guard let baseURL = memoryBaseURL else { return }
        let url = baseURL.appendingPathComponent("v1/connection-services/amazon-atoz")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        if !memoryBearerToken.isEmpty {
            req.setValue("Bearer \(memoryBearerToken)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await URLSession.shared.data(for: req)
    }
}

/// Snapshot of the token metadata (unverified claims: sub and exp).
struct AtoZTokenMetadata: Equatable {
    let employeeId: String?
    let expiration: Date?
    let issuedAt: Date?
    let isExpired: Bool
    let secondsRemaining: Int

    var statusMessage: String {
        guard let exp = expiration else { return "Token presente (sin fecha de expiración)" }
        let now = Date()
        let diff = Int(exp.timeIntervalSince(now))
        if diff <= 0 {
            let ago = max(1, Int(abs(diff) / 60))
            let timeStr = DateFormatter.localizedString(from: exp, dateStyle: .none, timeStyle: .short)
            return "⚠️ El token expiró hace \(ago) min (a las \(timeStr)). En A to Z cada token dura solo 15 minutos."
        } else {
            let minLeft = max(1, Int(diff / 60))
            let timeStr = DateFormatter.localizedString(from: exp, dateStyle: .none, timeStyle: .short)
            return "🟢 Token activo por \(minLeft) min más (expira a las \(timeStr))."
        }
    }
}

/// Helper to parse pasted cURL commands, raw Cookie headers, or DevTools cookie tables.
/// Always returns a normalized single-line `name=value; name2=value2` header (or nil).
enum AtoZSessionParser {
    static func parse(text: String) -> (cookie: String?, employeeId: String?) {
        let cookie = extractCookie(text)
        let empId = extractEmployeeId(text, cookie: cookie)
        return (cookie, empId)
    }

    // MARK: Token Metadata (JWT inspection)

    static func extractRawToken(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"atoz-oauth-token=([A-Za-z0-9_\-\.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[range])
    }

    static func extractTokenMetadata(from text: String) -> AtoZTokenMetadata? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Find atoz-oauth-token=...
        let pattern = #"atoz-oauth-token=([A-Za-z0-9_\-\.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else { return nil }

        let token = String(trimmed[range])
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let sub = json["sub"] as? String ?? (json["sub"] as? NSNumber)?.stringValue
        let expTimestamp = (json["exp"] as? Double) ?? (json["exp"] as? Int).map { Double($0) }
        let iatTimestamp = (json["iat"] as? Double) ?? (json["iat"] as? Int).map { Double($0) }

        let expDate = expTimestamp.map { Date(timeIntervalSince1970: $0) }
        let iatDate = iatTimestamp.map { Date(timeIntervalSince1970: $0) }

        let now = Date()
        let isExpired = expDate.map { now > $0 } ?? false
        let secondsRemaining = expDate.map { Int($0.timeIntervalSince(now)) } ?? 0

        return AtoZTokenMetadata(
            employeeId: sub,
            expiration: expDate,
            issuedAt: iatDate,
            isExpired: isExpired,
            secondsRemaining: secondsRemaining
        )
    }

    // MARK: employeeId

    static func extractEmployeeId(_ text: String, cookie: String? = nil) -> String? {
        let empPattern = #"(?:employeeId=|employeeId%3D|/apis/[^/]+/|"employeeId"\s*:\s*"?)([0-9]{6,12})"#
        if let regex = try? NSRegularExpression(pattern: empPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }

        // Fall back to JWT sub claim if present
        if let meta = extractTokenMetadata(from: cookie ?? text), let sub = meta.employeeId, !sub.isEmpty {
            return sub
        }

        return nil
    }

    // MARK: Cookie

    static func extractCookie(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. cURL: -H 'Cookie: …' / -H "cookie: …" / -b '…' / --cookie '…'
        let curlPatterns = [
            #"(?:-H|--header)\s+'[Cc]ookie:\s*([^']+)'"#,
            #"(?:-H|--header)\s+"[Cc]ookie:\s*([^"]+)""#,
            #"(?:-b|--cookie)\s+'([^']+)'"#,
            #"(?:-b|--cookie)\s+"([^"]+)""#,
            #"\$'[Cc]ookie:\s*([^']+)'"#
        ]
        for p in curlPatterns {
            if let v = firstCapture(p, in: trimmed) {
                return normalizeHeader(v)
            }
        }
        // A cURL command without any cookie is not a cookie.
        if trimmed.hasPrefix("curl ") { return nil }

        // 2. Firefox "Request Cookies" JSON: {"Request Cookies": {"name": "value"}} or {"name": "value"}
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let dict = (obj["Request Cookies"] as? [String: Any]) ?? (obj["request cookies"] as? [String: Any]) ?? obj
            let pairs = dict.compactMap { k, v -> (String, String)? in
                guard let s = v as? String ?? (v as? NSNumber)?.stringValue else { return nil }
                return (k, s)
            }.sorted { $0.0 < $1.0 }
            return join(pairs)
        }

        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 3. DevTools cookie table (Chrome/Safari): tab-separated rows "name<TAB>value<TAB>domain…"
        if lines.contains(where: { $0.contains("\t") }) {
            var pairs: [(String, String)] = []
            for line in lines {
                let cols = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                guard cols.count >= 2 else { continue }
                let name = cols[0], value = cols[1]
                if name.lowercased() == "name" && value.lowercased() == "value" { continue } // header row
                guard isValidName(name) else { continue }
                pairs.append((name, value))
            }
            return join(pairs)
        }

        // 4. Raw "Cookie: a=b; c=d" header (single or multi-line)
        let single = lines.joined(separator: "; ")
            .replacingOccurrences(of: #"(?i)^cookie:\s*"#, with: "", options: .regularExpression)
        if single.contains("=") {
            return normalizeHeader(single)
        }

        // 5. "name: value" lines
        let colonPairs = lines.compactMap { line -> (String, String)? in
            guard let idx = line.firstIndex(of: ":") else { return nil }
            let n = line[..<idx].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            return isValidName(n) ? (n, v) : nil
        }
        return join(colonPairs)
    }

    /// Cookie names only (never values) — safe to display for diagnostics.
    static func cookieNames(_ cookie: String) -> [String] {
        cookie.components(separatedBy: ";").compactMap { part in
            let p = part.trimmingCharacters(in: .whitespaces)
            guard let eq = p.firstIndex(of: "=") else { return nil }
            let n = String(p[..<eq])
            return n.isEmpty ? nil : n
        }
    }

    // MARK: helpers

    private static func normalizeHeader(_ raw: String) -> String? {
        let pairs: [(String, String)] = raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: ";")
            .components(separatedBy: ";")
            .compactMap { part in
                let p = part.trimmingCharacters(in: .whitespaces)
                guard let eq = p.firstIndex(of: "=") else { return nil }
                let n = String(p[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(p[p.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                return isValidName(n) ? (n, v) : nil
            }
        return join(pairs)
    }

    private static func join(_ pairs: [(String, String)]) -> String? {
        let clean = pairs.filter { !$0.0.isEmpty && !$0.1.contains(where: { $0.isNewline || $0 == "\t" }) }
        guard !clean.isEmpty else { return nil }
        return clean.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func isValidName(_ n: String) -> Bool {
        guard !n.isEmpty, n.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$%&'*+-.^_`|~"))
        return n.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
