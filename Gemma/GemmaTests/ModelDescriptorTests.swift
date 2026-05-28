import XCTest
@testable import Gemma

final class ModelDescriptorTests: XCTestCase {
    private let sample = ModelDescriptor(
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
    )

    func test_descriptor_sizeInMB_isCorrect() {
        XCTAssertEqual(sample.sizeInMB, 3489, accuracy: 1)
    }

    func test_descriptor_sizeInGB_isCorrect() {
        XCTAssertEqual(sample.sizeInGB, 3.41, accuracy: 0.01)
    }

    func test_descriptor_codable_roundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(sample)
        let decoded = try decoder.decode(ModelDescriptor.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_descriptor_idIsHashable() {
        let set: Set<ModelDescriptor> = [sample, sample]
        XCTAssertEqual(set.count, 1)
    }
}
