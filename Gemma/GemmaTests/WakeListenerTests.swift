import XCTest
@testable import Gemma

@MainActor
final class WakeListenerTests: XCTestCase {
    final class FakeDetector: WakeDetecting {
        var nextScore: Float = 0
        private(set) var resetCount = 0
        var useCustomWakeWord: Bool = false
        func process(frame: [Float]) -> Float { nextScore }
        func reset() { resetCount += 1 }
        func enroll(recordings: [Data]) throws {}
        func loadCustomWakeWord() {}
        func clearCustomWakeWord() {}
    }

    func test_wake_then_silence_yields_a_wav_and_rearms() async {
        let det = FakeDetector()
        var sent: [Data] = []
        let wl = WakeListener(detector: det, sendWav: { wav, _ in sent.append(wav) })
        wl.beginListeningForTest()                       // enters .listening without a real engine
        XCTAssertEqual(wl.state, WakeListener.WakeState.listening)

        det.nextScore = 0.9                              // next frame fires the wake word
        wl.feedFrameForTest(Array(repeating: 0.2, count: 1280))
        XCTAssertEqual(wl.state, WakeListener.WakeState.capturing)
        XCTAssertEqual(det.resetCount, 1)                // detector reset on wake

        // speak a bit then go silent -> endpointer fires -> a WAV is produced and sent
        for _ in 0..<5 { wl.feedFrameForTest(Array(repeating: 0.2, count: 1280)) }   // speech
        for _ in 0..<20 { wl.feedFrameForTest(Array(repeating: 0.0, count: 1280)) }  // silence (>1500ms = 18+ frames)
        XCTAssertEqual(sent.count, 1, "one utterance WAV should be sent")
        XCTAssertEqual(Array(sent.first!.prefix(4)), Array("RIFF".utf8))             // valid WAV
        XCTAssertEqual(wl.state, WakeListener.WakeState.busy)                         // busy until playback done
        wl.notePlaybackFinished()                                                   // owner re-arms after playback
        XCTAssertEqual(wl.state, WakeListener.WakeState.listening)
    }

    func test_does_not_detect_while_voice_busy() async {
        let det = FakeDetector()
        det.nextScore = 0.9                                  // would fire if processed
        let wl = WakeListener(detector: det, sendWav: { _, _ in })
        wl.isVoiceBusy = { true }                            // a manual turn is in progress
        wl.beginListeningForTest()
        wl.feedFrameForTest(Array(repeating: 0.2, count: 1280))
        XCTAssertEqual(wl.state, WakeListener.WakeState.listening, "must not start capturing while a voice turn is active")
        XCTAssertEqual(det.resetCount, 0)
    }
}
