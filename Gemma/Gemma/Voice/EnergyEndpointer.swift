import Foundation

/// RMS-energy silence endpointer for the post-wake utterance. Pure logic — feed one audio frame
/// at a time; returns true once `silenceMs` of trailing sub-threshold audio follows >= `minSpeechMs`
/// of speech.
final class EnergyEndpointer {
    private let silenceNeeded: Int
    private let minSpeech: Int
    private let threshold: Float
    private var speechFrames = 0
    private var trailingSilence = 0
    private var started = false

    init(frameMs: Int = 80, silenceMs: Int = 800, minSpeechMs: Int = 300, energyThreshold: Float = 0.01) {
        self.silenceNeeded = max(1, silenceMs / frameMs)
        self.minSpeech = max(1, minSpeechMs / frameMs)
        self.threshold = energyThreshold
    }

    static func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(frame.count)).squareRoot()
    }

    func update(frame: [Float]) -> Bool {
        let voiced = Self.rms(frame) >= threshold
        if voiced {
            speechFrames += 1
            trailingSilence = 0
            if speechFrames >= minSpeech { started = true }
        } else if started {
            trailingSilence += 1
        }
        return started && trailingSilence >= silenceNeeded
    }
}
