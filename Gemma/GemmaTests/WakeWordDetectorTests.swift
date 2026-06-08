import XCTest
import AVFoundation
@testable import Gemma

@MainActor
final class WakeWordDetectorTests: XCTestCase {

    // MARK: - Helpers

    private func samples(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: name, withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        if let f = buf.floatChannelData {
            return Array(UnsafeBufferPointer(start: f[0], count: Int(buf.frameLength)))
        }
        // PCM16 path
        let i = buf.int16ChannelData![0]
        return (0..<Int(buf.frameLength)).map { Float(i[$0]) / 32768.0 }
    }

    private func maxScore(_ audio: [Float], _ d: WakeWordDetector) -> Float {
        var best: Float = 0, i = 0
        while i + 1280 <= audio.count {
            best = max(best, d.process(frame: Array(audio[i..<i+1280])))
            i += 1280
        }
        return best
    }

    // MARK: - Tests

    func test_detects_hey_jarvis_above_threshold() async throws {
        let d = try WakeWordDetector()
        let s = maxScore(try samples("hey_jarvis"), d)
        print("hey_jarvis max score = \(s)")
        XCTAssertGreaterThan(s, 0.5, "hey_jarvis should score > 0.5, got \(s)")
    }

    func test_silence_scores_low() async throws {
        let d = try WakeWordDetector()
        let s = maxScore([Float](repeating: 0, count: 16000), d)
        print("silence max score = \(s)")
        XCTAssertLessThan(s, 0.3)
    }

    /// Discriminating negative: ~5 s of non-wake speech (long enough to fill the 16-embedding
    /// window) must NOT trigger — guards against a detector that scores high on any speech.
    func test_non_wake_speech_scores_low() async throws {
        let d = try WakeWordDetector()
        let s = maxScore(try samples("non_wake"), d)
        print("non_wake max score = \(s)")
        XCTAssertLessThan(s, 0.3, "non-wake speech should not trigger, got \(s)")
    }
}
