import Foundation

public enum ModelLicense: String, Sendable, Codable, Hashable {
    case gemmaTermsOfUse
    case apache2
    case other
}

public struct ModelDescriptor: Sendable, Codable, Hashable, Identifiable {
    public let id: String                           // canonical id e.g. "gemma-4-e4b-it"
    public let displayName: String                  // user-facing
    public let modelFile: String                    // filename on disk e.g. "gemma-4-E4B-it.litertlm"
    public let sourceURL: URL                       // direct HTTP URL to the model file
    public let sizeInBytes: Int64
    public let minDeviceMemoryGB: Int               // from the Google catalog
    public let supportsImage: Bool
    public let supportsAudio: Bool
    public let supportsSpeculativeDecoding: Bool
    public let maxContextLength: Int
    public let license: ModelLicense

    public init(
        id: String,
        displayName: String,
        modelFile: String,
        sourceURL: URL,
        sizeInBytes: Int64,
        minDeviceMemoryGB: Int,
        supportsImage: Bool,
        supportsAudio: Bool,
        supportsSpeculativeDecoding: Bool,
        maxContextLength: Int,
        license: ModelLicense
    ) {
        self.id = id
        self.displayName = displayName
        self.modelFile = modelFile
        self.sourceURL = sourceURL
        self.sizeInBytes = sizeInBytes
        self.minDeviceMemoryGB = minDeviceMemoryGB
        self.supportsImage = supportsImage
        self.supportsAudio = supportsAudio
        self.supportsSpeculativeDecoding = supportsSpeculativeDecoding
        self.maxContextLength = maxContextLength
        self.license = license
    }

    public var sizeInMB: Double {
        Double(sizeInBytes) / (1024.0 * 1024.0)
    }
    public var sizeInGB: Double {
        Double(sizeInBytes) / (1024.0 * 1024.0 * 1024.0)
    }
}
