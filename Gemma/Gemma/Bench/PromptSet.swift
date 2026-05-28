import Foundation

public enum PromptCategory: String, Sendable, Codable, Hashable {
    case factual
    case conversational
    case long
    case image
}

public enum PromptLanguage: String, Sendable, Codable, Hashable {
    case es
    case en
}

public struct BenchPrompt: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let category: PromptCategory
    public let language: PromptLanguage
    public let text: String
    /// For .image prompts: the name of an image bundled in Assets.xcassets (added later by image task).
    public let imageAssetName: String?

    public init(
        id: String,
        category: PromptCategory,
        language: PromptLanguage,
        text: String,
        imageAssetName: String? = nil
    ) {
        self.id = id
        self.category = category
        self.language = language
        self.text = text
        self.imageAssetName = imageAssetName
    }
}

public enum PromptSet {
    /// Fixed set of 20 prompts used by every bench run. DO NOT mutate during S1.
    /// Distribution: 8 factual (4 ES + 4 EN), 6 conversational (3 ES + 3 EN), 4 long (2 ES + 2 EN), 2 image (1 ES + 1 EN).
    public static let all: [BenchPrompt] = [
        // Factual ES
        .init(id: "fact-es-1", category: .factual, language: .es,
              text: "¿Cuál es la capital de Australia?"),
        .init(id: "fact-es-2", category: .factual, language: .es,
              text: "¿En qué año cayó el Muro de Berlín?"),
        .init(id: "fact-es-3", category: .factual, language: .es,
              text: "Nombra tres planetas del sistema solar."),
        .init(id: "fact-es-4", category: .factual, language: .es,
              text: "¿Quién escribió Cien años de soledad?"),

        // Factual EN
        .init(id: "fact-en-1", category: .factual, language: .en,
              text: "What is the boiling point of water at sea level in Celsius?"),
        .init(id: "fact-en-2", category: .factual, language: .en,
              text: "Who painted the Mona Lisa?"),
        .init(id: "fact-en-3", category: .factual, language: .en,
              text: "Name three programming languages used for iOS development."),
        .init(id: "fact-en-4", category: .factual, language: .en,
              text: "What does HTTP stand for?"),

        // Conversational ES
        .init(id: "conv-es-1", category: .conversational, language: .es,
              text: "Hola, ¿cómo estás hoy?"),
        .init(id: "conv-es-2", category: .conversational, language: .es,
              text: "Tengo hambre, ¿qué me recomiendas para cenar?"),
        .init(id: "conv-es-3", category: .conversational, language: .es,
              text: "Cuéntame un chiste corto."),

        // Conversational EN
        .init(id: "conv-en-1", category: .conversational, language: .en,
              text: "Hi, can you help me plan a weekend trip?"),
        .init(id: "conv-en-2", category: .conversational, language: .en,
              text: "I am tired. Give me a quick tip to relax."),
        .init(id: "conv-en-3", category: .conversational, language: .en,
              text: "Tell me a fun fact about octopuses."),

        // Long ES (500-1000 tokens context + question)
        .init(id: "long-es-1", category: .long, language: .es,
              text: String(repeating:
                "La inteligencia artificial generativa ha transformado múltiples industrias en los últimos años. "
              , count: 25) + "Resume el texto anterior en tres puntos."),
        .init(id: "long-es-2", category: .long, language: .es,
              text: String(repeating:
                "El cambio climático afecta a los ecosistemas marinos de formas cada vez más visibles. "
              , count: 25) + "¿Cuál es la idea principal del texto?"),

        // Long EN
        .init(id: "long-en-1", category: .long, language: .en,
              text: String(repeating:
                "Distributed systems must balance consistency, availability, and partition tolerance. "
              , count: 25) + "Summarize the trade-off in two sentences."),
        .init(id: "long-en-2", category: .long, language: .en,
              text: String(repeating:
                "On-device machine learning has matured rapidly thanks to hardware acceleration. "
              , count: 25) + "What is the main argument of the passage?"),

        // Image (1 ES + 1 EN); image assets are added in Task 9.
        .init(id: "img-es-1", category: .image, language: .es,
              text: "¿Qué hay en esta imagen?", imageAssetName: "bench-image-1"),
        .init(id: "img-en-1", category: .image, language: .en,
              text: "What do you see in this image?", imageAssetName: "bench-image-1"),
    ]
}
