import XCTest
@testable import Gemma

@MainActor
final class WakeListenerTests: XCTestCase {
    final class FakeDetector: WakeDetecting {
        var nextScore: Float = 0
        private(set) var resetCount = 0
        func process(frame: [Float]) -> Float { nextScore }
        func reset() { resetCount += 1 }
    }

    func test_wake_then_silence_yields_a_wav_and_rearms() async {
        let det = FakeDetector()
        var sent: [Data] = []
        let wl = WakeListener(detector: det, sendWav: { wav in sent.append(wav) })
        wl.beginListeningForTest()                       // enters .listening without a real engine
        XCTAssertEqual(wl.state, .listening)

        det.nextScore = 0.9                              // next frame fires the wake word
        wl.feedFrameForTest(Array(repeating: 0.2, count: 1280))
        XCTAssertEqual(wl.state, .capturing)
        XCTAssertEqual(det.resetCount, 1)                // detector reset on wake

        // speak a bit then go silent -> endpointer fires -> a WAV is produced and sent
        for _ in 0..<5 { wl.feedFrameForTest(Array(repeating: 0.2, count: 1280)) }   // speech
        for _ in 0..<14 { wl.feedFrameForTest(Array(repeating: 0.0, count: 1280)) }  // silence
        XCTAssertEqual(sent.count, 1, "one utterance WAV should be sent")
        XCTAssertEqual(Array(sent.first!.prefix(4)), Array("RIFF".utf8))             // valid WAV
    }
}
