import Foundation
import OnnxRuntimeBindings

// MARK: - Protocol

protocol WakeDetecting: AnyObject {
    /// Process one 80 ms audio frame (1280 samples at 16 kHz, float32 in [-1, 1]).
    /// Returns the current wake-word score in [0, 1]. Returns 0 until enough context
    /// has accumulated (≥ 16 embeddings, each requiring a full 76-frame mel window).
    func process(frame: [Float]) -> Float
    /// Clear all rolling buffers (mel frames + embeddings).
    func reset()
}

// MARK: - WakeWordDetector

/// Streaming openWakeWord pipeline ported from the Python reference:
/// https://github.com/dscripka/openWakeWord (openwakeword/utils.py)
///
/// Pipeline per 1280-sample chunk:
///   1. Run melspectrogram.onnx on the raw PCM → raw mel frames [N × 32]
///   2. Normalize: mel = mel / 10 + 2
///   3. Append to rolling mel buffer (max 970 frames)
///   4. Extract the last 76 frames → run embedding_model.onnx → 96-dim vector
///   5. Append embedding to rolling buffer (max 120)
///   6. When ≥ 16 embeddings, feed last 16 → hey_jarvis_v0.1.onnx → score
///
final class WakeWordDetector: WakeDetecting {

    // MARK: ONNX runtime + sessions
    // All stored as plain `let` — the project's SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
    // affects `var` mutable state; `let` constants on a class are fine from any thread.
    private let ortEnv:      ORTEnv
    private let melSession:  ORTSession
    private let embSession:  ORTSession
    private let wakeSession: ORTSession

    // MARK: Rolling buffers
    /// Mel spectrogram buffer: rows of 32 mel bins, oldest-first. Starts EMPTY and fills from
    /// real melspec inference — not pre-seeded with zeros (fake-silence rows would pollute the
    /// early embedding context, since real silence mel ≈ -8 after the /10+2 scaling).
    private var melBuffer: [[Float]]
    private let melBufferMaxLen = 970   // ~10 s worth of frames
    private let embWindowSize   = 76    // frames per embedding inference

    /// Embedding buffer: each row is 96-dim.
    private var embBuffer: [[Float]]
    private let embBufferMaxLen = 120
    private let wakeWindowSize  = 16    // embeddings fed to wake model

    // MARK: - init

    init() throws {
        // Keep env alive as a stored property — sessions reference it internally.
        let env = try ORTEnv(loggingLevel: .warning)
        ortEnv = env

        func load(_ name: String) throws -> ORTSession {
            // Each session gets its own ORTSessionOptions (don't share across sessions).
            let opts = try ORTSessionOptions()
            // Try the class bundle first (unit tests), then the app bundle.
            let bundles: [Bundle] = [Bundle(for: WakeWordDetector.self), .main]
            for bundle in bundles {
                if let url = bundle.url(forResource: name, withExtension: "onnx") {
                    return try ORTSession(env: env, modelPath: url.path, sessionOptions: opts)
                }
            }
            throw WakeWordError.modelNotFound(name)
        }

        melSession  = try load("melspectrogram")
        embSession  = try load("embedding_model")
        wakeSession = try load("hey_jarvis_v0.1")

        // Start with empty buffers — they fill up through actual mel processing.
        // (Pre-seeding with zeros produces wrong embedding context; silence mel ≈ -8.0)
        melBuffer = []
        embBuffer = []
    }

    // MARK: - WakeDetecting

    func process(frame: [Float]) -> Float {
        // ── Step 1: melspectrogram ─────────────────────────────────────────────
        guard let rawMel = runMelspec(frame) else { return 0 }
        // rawMel is flat [frames × 32]; frame count is read from the model output (normMel.count/32),
        // not hardcoded — a 1280-sample chunk yields 5 mel frames with this melspectrogram model.

        // ── Step 2: normalize mel (/10 + 2) ───────────────────────────────────
        let normMel = rawMel.map { $0 / 10.0 + 2.0 }

        // ── Step 3: append new frames to mel buffer ───────────────────────────
        let frameCount = normMel.count / 32
        for r in 0..<frameCount {
            melBuffer.append(Array(normMel[(r * 32)..<(r * 32 + 32)]))
        }
        if melBuffer.count > melBufferMaxLen {
            melBuffer.removeFirst(melBuffer.count - melBufferMaxLen)
        }

        // ── Step 4: extract last 76 frames → embedding ────────────────────────
        guard melBuffer.count >= embWindowSize else { return 0 }
        let window = Array(melBuffer.suffix(embWindowSize))  // 76 × 32
        guard let emb = runEmbedding(window) else { return 0 }  // 96-dim

        // ── Step 5: append embedding ──────────────────────────────────────────
        embBuffer.append(emb)
        if embBuffer.count > embBufferMaxLen {
            embBuffer.removeFirst(embBuffer.count - embBufferMaxLen)
        }

        // ── Step 6: run wake model when we have ≥ 16 embeddings ───────────────
        guard embBuffer.count >= wakeWindowSize else { return 0 }
        let lastEmbs = Array(embBuffer.suffix(wakeWindowSize))  // 16 × 96
        return runWake(lastEmbs) ?? 0
    }

    func reset() {
        melBuffer = []
        embBuffer = []
    }

    // MARK: - Private inference helpers

    /// Run melspectrogram.onnx on `samples` (1280 float32 PCM samples).
    /// Input: `input` [1, N]; Output: `output` [1, 1, frames, 32]
    /// Returns a flat [frames × 32] float array, or nil on error.
    private func runMelspec(_ samples: [Float]) -> [Float]? {
        do {
            let inTensor = try makeTensor(samples, shape: [1, samples.count])
            let outs = try melSession.run(
                withInputs: ["input": inTensor],
                outputNames: ["output"],
                runOptions: nil)
            guard let outVal = outs["output"] else { return nil }
            return try readFloats(outVal)
        } catch {
            return nil
        }
    }

    /// Run embedding_model.onnx on a [76 × 32] mel window.
    /// Input: `input_1` [1, 76, 32, 1]; Output: `conv2d_19` [1, 1, 1, 96]
    /// Returns a 96-element float array, or nil on error.
    private func runEmbedding(_ window: [[Float]]) -> [Float]? {
        do {
            var flat: [Float] = []
            flat.reserveCapacity(76 * 32)
            for row in window { flat.append(contentsOf: row) }
            let inTensor = try makeTensor(flat, shape: [1, embWindowSize, 32, 1])
            let outs = try embSession.run(
                withInputs: ["input_1": inTensor],
                outputNames: ["conv2d_19"],
                runOptions: nil)
            guard let outVal = outs["conv2d_19"] else { return nil }
            return try readFloats(outVal)   // 96 floats
        } catch {
            return nil
        }
    }

    /// Run hey_jarvis_v0.1.onnx on a [16 × 96] embedding window.
    /// Input: `x.1` [1, 16, 96]; Output: `53` [1, 1]
    /// Returns the scalar score, or nil on error.
    private func runWake(_ embeddings: [[Float]]) -> Float? {
        do {
            var flat: [Float] = []
            flat.reserveCapacity(wakeWindowSize * 96)
            for row in embeddings { flat.append(contentsOf: row) }
            let inTensor = try makeTensor(flat, shape: [1, wakeWindowSize, 96])
            let outs = try wakeSession.run(
                withInputs: ["x.1": inTensor],
                outputNames: ["53"],
                runOptions: nil)
            guard let outVal = outs["53"] else { return nil }
            let scores = try readFloats(outVal)
            return scores.first
        } catch {
            return nil
        }
    }

    // MARK: - ORTValue utilities

    private func makeTensor(_ floats: [Float], shape: [Int]) throws -> ORTValue {
        let data = NSMutableData(bytes: floats, length: floats.count * MemoryLayout<Float>.size)
        return try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: shape.map { NSNumber(value: $0) })
    }

    private func readFloats(_ value: ORTValue) throws -> [Float] {
        let d = try value.tensorData() as Data
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

// MARK: - Errors

enum WakeWordError: Error {
    case modelNotFound(String)
}
