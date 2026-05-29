import XCTest
@testable import Gemma
import LiteRTLM

final class MultimodalBackendsTests: XCTestCase {

    func test_gpuAttempt_requestsMainBackendForSupportedModalities() {
        let r = multimodalBackends(image: true, audio: true, attempt: .primary, main: .gpu)
        XCTAssertEqual(r.vision, .gpu)
        XCTAssertEqual(r.audio, .gpu)
    }

    func test_unsupportedModality_isNilInEveryAttempt() {
        for attempt in MMAttempt.allCases {
            let r = multimodalBackends(image: false, audio: true, attempt: attempt, main: .gpu)
            XCTAssertNil(r.vision, "vision must stay nil when image unsupported (attempt \(attempt))")
        }
    }

    func test_cpuAttempt_pinsSupportedModalitiesToCPU() {
        let r = multimodalBackends(image: true, audio: false, attempt: .cpu, main: .gpu)
        XCTAssertEqual(r.vision, .cpu())
        XCTAssertNil(r.audio)
    }

    func test_textOnlyAttempt_requestsNothing() {
        let r = multimodalBackends(image: true, audio: true, attempt: .textOnly, main: .gpu)
        XCTAssertNil(r.vision)
        XCTAssertNil(r.audio)
    }

    func test_attemptPlan_neitherSupported_isTextOnlyOnly() {
        XCTAssertEqual(multimodalAttemptPlan(image: false, audio: false), [.textOnly])
    }

    func test_attemptPlan_anySupported_isFullCascade() {
        XCTAssertEqual(multimodalAttemptPlan(image: true, audio: false), [.primary, .cpu, .textOnly])
    }
}
