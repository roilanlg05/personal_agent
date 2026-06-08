import XCTest
@testable import Gemma

final class EnergyEndpointerTests: XCTestCase {
    private func make() -> EnergyEndpointer {
        EnergyEndpointer(frameMs: 80, silenceMs: 320, minSpeechMs: 160, energyThreshold: 0.01)
    }
    private let loud = [Float](repeating: 0.2, count: 1280)     // RMS 0.2 > threshold
    private let quiet = [Float](repeating: 0.0, count: 1280)    // RMS 0 < threshold

    func test_triggers_after_trailing_silence() async throws {
        let ep = make()
        for _ in 0..<3 { XCTAssertFalse(ep.update(frame: loud)) }   // speech, never ends mid-speech
        let r = (0..<4).map { _ in ep.update(frame: quiet) }
        XCTAssertTrue(r.last!)                                       // ends on the 4th silent frame (320ms)
        XCTAssertFalse(r.dropLast().contains(true))
    }

    func test_ignores_short_blip() async throws {
        // needs 320ms (4 frames) of speech to "start"; a 160ms blip never triggers an end.
        let ep = EnergyEndpointer(frameMs: 80, silenceMs: 320, minSpeechMs: 320, energyThreshold: 0.01)
        for _ in 0..<2 { _ = ep.update(frame: loud) }               // 160ms speech -> not started
        XCTAssertFalse((0..<10).map { _ in ep.update(frame: quiet) }.contains(true))
    }
}
