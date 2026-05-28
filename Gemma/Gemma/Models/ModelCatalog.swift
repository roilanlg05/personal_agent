import Foundation

/// Static catalog of supported models. Mirrors the relevant entries from the Google AI Edge Gallery iOS catalog.
public enum ModelCatalog {
    public static let builtIn: [ModelDescriptor] = [
        ModelDescriptor(
            id: "gemma-4-e4b-it",
            displayName: "Gemma 4 E4B",
            modelFile: "gemma-4-E4B-it.litertlm",
            sourceURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/28299f30ee4d43294517a4ac93abd6163412f07f/gemma-4-E4B-it.litertlm")!,
            sizeInBytes: 3_659_530_240,
            minDeviceMemoryGB: 8,
            supportsImage: true,
            supportsAudio: true,
            supportsSpeculativeDecoding: true,
            maxContextLength: 32_000,
            license: .gemmaTermsOfUse
        ),
        ModelDescriptor(
            id: "gemma-4-e2b-it",
            displayName: "Gemma 4 E2B",
            modelFile: "gemma-4-E2B-it.litertlm",
            sourceURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/6e5c4f1e395deb959c494953478fa5cec4b8008f/gemma-4-E2B-it.litertlm")!,
            sizeInBytes: 2_588_147_712,
            minDeviceMemoryGB: 6,
            supportsImage: true,
            supportsAudio: true,
            supportsSpeculativeDecoding: true,
            maxContextLength: 32_000,
            license: .gemmaTermsOfUse
        )
    ]

    public static func find(_ id: String) -> ModelDescriptor? {
        builtIn.first { $0.id == id }
    }
}
