import Foundation

/// One voice turn's result: the spoken reply WAV plus the recognized text and the reply text
/// (decoded from the i3's percent-encoded X-STT-Text / X-Reply-Text headers).
struct VoiceReply: Sendable {
    let audio: Data
    let sttText: String
    let replyText: String
}

enum VoiceError: Error, Equatable {
    case silence                              // HTTP 400 — nothing transcribed
    case http(status: Int, reply: String?)    // non-2xx
    case invalidResponse
}

/// Abstraction so VoiceController can be unit-tested with a fake.
protocol VoiceTurning: Sendable {
    func turn(wav: Data, threadId: String, timezone: String, isPassive: Bool) async throws -> VoiceReply
}

/// HTTP client to the i3 voice service. Mirrors MemoryClient (baseURL + bearer + injectable session).
/// Sends a multipart/form-data POST to /v1/voice/turn (audio in -> audio out).
struct VoiceClient: VoiceTurning {
    let baseURL: URL
    let bearerToken: String
    let session: URLSession

    init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
    }

    func turn(wav: Data, threadId: String, timezone: String, isPassive: Bool = false) async throws -> VoiceReply {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        // audio part
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"u.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")
        // text fields
        for (name, value) in [("threadId", threadId), ("timezone", timezone)] {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/voice/turn"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if isPassive {
            req.setValue("true", forHTTPHeaderField: "X-Voice-Passive")
        }
        req.httpBody = body
        req.timeoutInterval = 180

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VoiceError.invalidResponse }
        func header(_ key: String) -> String? {
            http.value(forHTTPHeaderField: key)?.removingPercentEncoding
        }
        if http.statusCode == 204 {
            return VoiceReply(audio: Data(), sttText: header("X-STT-Text") ?? "", replyText: "")
        }
        if http.statusCode == 400 { throw VoiceError.silence }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceError.http(status: http.statusCode, reply: header("X-Reply-Text"))
        }
        return VoiceReply(audio: data, sttText: header("X-STT-Text") ?? "", replyText: header("X-Reply-Text") ?? "")
    }
}
