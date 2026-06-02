import Foundation

/// Real health client: probes `/v1/models` and runs a representative warm-up/keep-alive completion that exercises the multi-token + MTP decode path.
nonisolated final class HTTPServerHealth: ServerHealth, @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func probe(_ config: ServerConfig) async -> Bool {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/models"))
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse { return (200..<300).contains(http.statusCode) }
            return false
        } catch { return false }
    }

    func warm(_ config: ServerConfig) async throws {
        // Representative warm-up: a system message + a multi-token generation so the FIRST real
        // turn doesn't pay Metal-kernel JIT (incl. the MTP speculative-decode path). A 1-token,
        // system-less ping only compiles a subset and leaves the first real turn ~31s slow.
        let body: [String: Any] = [
            "model": config.modelId,
            "messages": [
                ["role": "system", "content": "You are Gemma, a helpful on-device assistant."],
                ["role": "user", "content": "Say hello in one short sentence."],
            ],
            "max_tokens": 16,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180   // first warm-up loads the 15GB model
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RuntimeError.generationFailed("warm-up HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data.prefix(256), encoding: .utf8) ?? "")")
        }
    }
}
