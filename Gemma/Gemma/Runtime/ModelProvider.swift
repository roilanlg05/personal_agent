import Foundation

/// A model backend the app can talk to via the OpenAI-compatible chat API.
struct ModelProvider: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case local, gemini, cerebras, groq
        var id: String { rawValue }

        /// Default provider when nothing is persisted. Cloud (not local) so the 15GB mlx server
        /// does NOT spawn by default — it spawns only when the user explicitly picks "local".
        static var defaultKind: Kind { .cerebras }

        var displayName: String {
            switch self {
            case .local: return "Gemma local (mlx)"
            case .gemini: return "Gemini"
            case .cerebras: return "Cerebras"
            case .groq: return "Groq"
            }
        }
        /// Cloud providers reject `chat_template_kwargs` and require a bearer key; local mlx is the
        /// inverse. This single switch drives both quirks.
        var isLocalMLX: Bool { self == .local }

        /// Endpoint directory that CONTAINS `chat/completions` (the runtime appends `chat/completions`).
        /// Each ends at the version segment — Gemini's is `/v1beta/openai` (NOT `/v1`).
        var defaultBaseURL: URL {
            switch self {
            case .local: return URL(string: "http://localhost:8080/v1")!
            case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
            case .cerebras: return URL(string: "https://api.cerebras.ai/v1")!
            case .groq: return URL(string: "https://api.groq.com/openai/v1")!
            }
        }
        var defaultModel: String {
            switch self {
            case .local: return "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit"
            case .gemini: return "gemini-2.5-flash"
            case .cerebras: return "gpt-oss-120b"
            case .groq: return "openai/gpt-oss-120b"
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
        self.model = (model?.isEmpty == false ? model! : kind.defaultModel)
        self.apiKey = apiKey
    }
}
