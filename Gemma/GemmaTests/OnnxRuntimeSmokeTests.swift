import XCTest
import OnnxRuntimeBindings
@testable import Gemma

final class OnnxRuntimeSmokeTests: XCTestCase {
    func test_can_create_ort_env_and_session_options() throws {
        // Proves the onnxruntime package links + its ObjC API is callable from Swift.
        let env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        XCTAssertNotNil(env)
        XCTAssertNotNil(opts)
    }

    private func modelURL(_ name: String) throws -> URL {
        let b = Bundle(for: type(of: self))
        let url = b.url(forResource: name, withExtension: "onnx")
        return try XCTUnwrap(url, "\(name).onnx not in test bundle — check Target Membership")
    }

    func test_loads_all_three_openwakeword_models() throws {
        let env = try ORTEnv(loggingLevel: .warning)
        for name in ["melspectrogram", "embedding_model", "hey_jarvis_v0.1"] {
            let session = try ORTSession(env: env, modelPath: try modelURL(name).path,
                                         sessionOptions: try ORTSessionOptions())
            let inputs = try session.inputNames()
            XCTAssertFalse(inputs.isEmpty, "\(name) has no inputs?")
            print("MODEL \(name): inputs=\(inputs) outputs=\(try session.outputNames())")
        }
    }
}
