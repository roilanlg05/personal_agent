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
}
