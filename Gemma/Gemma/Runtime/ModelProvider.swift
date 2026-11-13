import Foundation

/// A model backend the app can talk to via the OpenAI-compatible chat API.
struct ModelProvider: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case local, onDevice, gemini, cerebras, groq, claude
        var id: String { rawValue }

        /// Default provider when nothing is persisted. Cloud for macOS so the 15GB mlx server
        /// does NOT spawn by default; on-device Metal for iOS.
        static var defaultKind: Kind {
            #if os(iOS)
            return .onDevice
            #else
            return .cerebras
            #endif
        }

        var displayName: String {
            switch self {
            case .local: return "Gemma Mac local (mlx)"
            case .onDevice: return "Gemma on-device (Metal)"
            case .gemini: return "Gemini"
            case .cerebras: return "Cerebras"
            case .groq: return "Groq"
            case .claude: return "Claude (Anthropic)"
            }
        }
        /// Cloud providers reject `chat_template_kwargs` and require a bearer key; local mlx is the
        /// inverse. This single switch drives both quirks.
        var isLocalMLX: Bool { self == .local || self == .onDevice }

        /// A conservative request limit for configurable models, not a claim about their maximum.
        var nativeContextTokens: Int {
            switch self {
            case .local: 4096
            case .onDevice: LlamaCppRuntime.nativeContextTokens
            case .gemini, .cerebras, .groq, .claude: 16_384
            }
        }

        /// Endpoint directory that CONTAINS `chat/completions` (the runtime appends `chat/completions`).
        /// Each ends at the version segment — Gemini's is `/v1beta/openai` (NOT `/v1`).
        var defaultBaseURL: URL {
            switch self {
            case .local: return URL(string: "http://localhost:8080/v1")!
            case .onDevice: return URL(string: "http://localhost:8080/v1")!
            case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
            case .cerebras: return URL(string: "https://api.cerebras.ai/v1")!
            case .groq: return URL(string: "https://api.groq.com/openai/v1")!
            case .claude: return URL(string: "https://api.anthropic.com/v1")!
            }
        }
        var defaultModel: String {
            switch self {
            case .local: return "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit"
            case .onDevice: return "Gemma-4-E4B-Uncensored-HauhauCS-Aggressive-Q5_K_P.gguf"
            case .gemini: return "gemini-2.5-flash"
            case .cerebras: return "gpt-oss-120b"
            case .groq: return "openai/gpt-oss-120b"
            case .claude: return "claude-haiku-5-5"
            }
        }
    }

    var kind: Kind
    var baseURL: URL
    var model: String
    var apiKey: String?

    init(kind: Kind, baseURL: URL? = nil, model: String? = nil, apiKey: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        let candidateModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if candidateModel.isEmpty {
            self.model = kind.defaultModel
        } else if kind == .claude && (candidateModel.hasSuffix(".gguf") || candidateModel.lowercased().contains("gemma") || candidateModel.contains("gpt-oss") || candidateModel == "claude-3-5-haiku-20241022") {
            self.model = kind.defaultModel
        } else if kind == .onDevice && (!candidateModel.hasSuffix(".gguf")) {
            self.model = kind.defaultModel
        } else if (kind == .gemini || kind == .cerebras || kind == .groq) && candidateModel.hasSuffix(".gguf") {
            self.model = kind.defaultModel
        } else {
            self.model = candidateModel
        }
        self.apiKey = apiKey
    }
}
