import Foundation
import OnnxRuntimeBindings

// MARK: - Protocol

protocol WakeDetecting: AnyObject {
    /// Process one 80 ms audio frame (1280 samples at 16 kHz, float32 in [-1, 1]).
    /// Returns the current wake-word score in [0, 1].
    func process(frame: [Float]) -> Float
    /// Clear all rolling buffers.
    func reset()
    /// Enroll a custom wake phrase from a set of PCM16 WAV audio samples.
    func enroll(recordings: [Data]) throws
    /// Reload custom templates and signature from UserDefaults.
    func loadCustomWakeWord()
    /// Reset custom wake settings to go back to standard "Hey Jarvis".
    func clearCustomWakeWord()
    /// True if a custom voice signature is enrolled and active.
    var useCustomWakeWord: Bool { get }
}

// MARK: - WakeWordDetector

final class WakeWordDetector: WakeDetecting {

    // MARK: ONNX runtime + sessions
    private let ortEnv:      ORTEnv
    private let melSession:  ORTSession
    private let embSession:  ORTSession
    private let wakeSession: ORTSession

    // MARK: Rolling buffers
    private var melBuffer: [[Float]]
    private let melBufferMaxLen = 970
    private let embWindowSize   = 76

    private var embBuffer: [[Float]]
    private let embBufferMaxLen = 120
    private let wakeWindowSize  = 16

    // MARK: Custom Wake Word & Speaker Profile
    private(set) var useCustomWakeWord: Bool = false
    private var enrolledTemplates: [[[Float]]] = []
    private var voiceSignature: [Float] = []

    // MARK: - init

    init() throws {
        let env = try ORTEnv(loggingLevel: .warning)
        ortEnv = env

        func load(_ name: String) throws -> ORTSession {
            let opts = try ORTSessionOptions()
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

        melBuffer = []
        embBuffer = []

        loadCustomWakeWord()
    }

    // MARK: - WakeDetecting

    func process(frame: [Float]) -> Float {
        // ── Step 1: melspectrogram ─────────────────────────────────────────────
        guard let rawMel = runMelspec(frame) else { return 0 }

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
        let window = Array(melBuffer.suffix(embWindowSize))
        guard let emb = runEmbedding(window) else { return 0 }

        // ── Step 5: append embedding ──────────────────────────────────────────
        embBuffer.append(emb)
        if embBuffer.count > embBufferMaxLen {
            embBuffer.removeFirst(embBuffer.count - embBufferMaxLen)
        }

        // ── Step 6: run wake model or custom matching when we have ≥ 16 embeddings
        guard embBuffer.count >= wakeWindowSize else { return 0 }
        let lastEmbs = Array(embBuffer.suffix(wakeWindowSize))

        if useCustomWakeWord {
            return scoreCustomWakeWord(lastEmbs)
        } else {
            return runWake(lastEmbs) ?? 0
        }
    }

    func reset() {
        melBuffer = []
        embBuffer = []
    }

    // MARK: - Custom Wake Word & Speaker Verification Implementation

    func loadCustomWakeWord() {
        if UserDefaults.standard.bool(forKey: "useCustomWakeWord"),
           let data = UserDefaults.standard.data(forKey: "customWakeTemplates"),
           let templates = try? JSONDecoder().decode([[[Float]]].self, from: data),
           let sigData = UserDefaults.standard.data(forKey: "customVoiceSignature"),
           let signature = try? JSONDecoder().decode([Float].self, from: sigData) {
            self.enrolledTemplates = templates
            self.voiceSignature = signature
            self.useCustomWakeWord = true
        } else {
            self.useCustomWakeWord = false
        }
    }

    func clearCustomWakeWord() {
        UserDefaults.standard.removeObject(forKey: "customWakeTemplates")
        UserDefaults.standard.removeObject(forKey: "customVoiceSignature")
        UserDefaults.standard.set(false, forKey: "useCustomWakeWord")
        self.enrolledTemplates = []
        self.voiceSignature = []
        self.useCustomWakeWord = false
    }

    func enroll(recordings: [Data]) throws {
        var allTemplates: [[[Float]]] = []
        var allEmbeddings: [[Float]] = []

        for data in recordings {
            let samples = Self.pcm16ToFloat(data)
            let embs = extractEmbeddings(from: samples)
            // Require at least 2 embeddings to avoid failure on quiet or short clips
            guard embs.count >= 2 else {
                throw NSError(domain: "WakeWordDetector", code: 2, userInfo: [NSLocalizedDescriptionKey: "Grabación muy corta o silenciosa. Por favor habla claro y mantén la app abierta."])
            }
            allTemplates.append(embs)
            allEmbeddings.append(contentsOf: embs)
        }

        guard !allEmbeddings.isEmpty else {
            throw NSError(domain: "WakeWordDetector", code: 3, userInfo: [NSLocalizedDescriptionKey: "No se pudieron extraer huellas de voz."])
        }

        // 1. Calculate the voice profile (average of all 96-dim speech Inception embeddings)
        var signature = [Float](repeating: 0, count: 96)
        for emb in allEmbeddings {
            for i in 0..<96 { signature[i] += emb[i] }
        }
        for i in 0..<96 { signature[i] /= Float(allEmbeddings.count) }

        // 2. Save everything to UserDefaults
        let encoder = JSONEncoder()
        if let encTemplates = try? encoder.encode(allTemplates),
           let encSig = try? encoder.encode(signature) {
            UserDefaults.standard.set(encTemplates, forKey: "customWakeTemplates")
            UserDefaults.standard.set(encSig, forKey: "customVoiceSignature")
            UserDefaults.standard.set(true, forKey: "useCustomWakeWord")

            self.enrolledTemplates = allTemplates
            self.voiceSignature = signature
            self.useCustomWakeWord = true
        } else {
            throw NSError(domain: "WakeWordDetector", code: 4, userInfo: [NSLocalizedDescriptionKey: "No se pudieron guardar las huellas de voz."])
        }
    }

    /// Extract a continuous stream of 96-dim embeddings from Float samples.
    private func extractEmbeddings(from samples: [Float]) -> [[Float]] {
        var mels: [[Float]] = []
        var embs: [[Float]] = []

        var i = 0
        while i + 1280 <= samples.count {
            let chunk = Array(samples[i..<i+1280])
            i += 1280

            // Skip low-energy silence frames (RMS threshold)
            let sumSq = chunk.reduce(0) { $0 + $1 * $1 }
            let rms = sqrt(sumSq / Float(chunk.count))
            guard rms >= 0.001 else { continue }

            if let rawMel = runMelspec(chunk) {
                let normMel = rawMel.map { $0 / 10.0 + 2.0 }
                let frameCount = normMel.count / 32
                for r in 0..<frameCount {
                    mels.append(Array(normMel[(r * 32)..<(r * 32 + 32)]))
                }
            }
        }

        guard mels.count >= embWindowSize else { return [] }
        var start = 0
        while start + embWindowSize <= mels.count {
            let window = Array(mels[start..<start+embWindowSize])
            start += 5 // Shift by 80 ms (5 frames)
            if let emb = runEmbedding(window) {
                embs.append(emb)
            }
        }

        return embs
    }

    private func scoreCustomWakeWord(_ embeddings: [[Float]]) -> Float {
        guard !enrolledTemplates.isEmpty, !voiceSignature.isEmpty else { return 0 }

        // 1. Voice Signature Match (Speaker Verification)
        // Average embedding of the current sliding window
        var currentAvg = [Float](repeating: 0, count: 96)
        for emb in embeddings {
            for i in 0..<96 { currentAvg[i] += emb[i] }
        }
        for i in 0..<96 { currentAvg[i] /= Float(embeddings.count) }

        let speakerSim = cosineSimilarity(currentAvg, voiceSignature)
        // Require similarity >= 0.83 to match user's voice (prevents other people/TV triggering)
        guard speakerSim >= 0.83 else { return 0 }

        // 2. Phrase Match (Dynamic Time Warping)
        var minDistance: Float = Float.infinity
        for template in enrolledTemplates {
            let dist = dtwDistance(embeddings, template)
            if dist < minDistance { minDistance = dist }
        }

        // Map DTW distance (average cost per frame) to score in [0, 1]
        // Cosine distance range is [0, 2]. Distance <= 0.40 is a high quality match.
        let maxAcceptableDistance: Float = 0.45
        let phraseScore = max(0.0, 1.0 - (minDistance / maxAcceptableDistance))

        // Return combined score
        return phraseScore * speakerSim
    }

    // MARK: - Dynamic Time Warping (DTW) & Cosine Math

    private func dtwDistance(_ s: [[Float]], _ t: [[Float]]) -> Float {
        let n = s.count
        let m = t.count
        guard n > 0 && m > 0 else { return Float.infinity }

        var dp = [[Float]](repeating: [Float](repeating: Float.infinity, count: m), count: n)

        dp[0][0] = cosineDistance(s[0], t[0])

        for i in 1..<n {
            dp[i][0] = dp[i-1][0] + cosineDistance(s[i], t[0])
        }
        for j in 1..<m {
            dp[0][j] = dp[0][j-1] + cosineDistance(s[0], t[j])
        }

        for i in 1..<n {
            for j in 1..<m {
                let cost = cosineDistance(s[i], t[j])
                dp[i][j] = cost + min(dp[i-1][j], min(dp[i][j-1], dp[i-1][j-1]))
            }
        }

        return dp[n-1][m-1] / Float(n + m)
    }

    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        return 1.0 - cosineSimilarity(a, b)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0 && normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }

    /// Converts standard 16-bit mono PCM bytes to Float samples.
    static func pcm16ToFloat(_ data: Data) -> [Float] {
        guard data.count > 44 else { return [] }
        let pcmData = data.subdata(in: 44..<data.count)
        var floats = [Float]()
        floats.reserveCapacity(pcmData.count / 2)

        pcmData.withUnsafeBytes { rawBuffer in
            guard let pointer = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            let count = pcmData.count / 2
            for i in 0..<count {
                floats.append(Float(pointer[i]) / 32768.0)
            }
        }
        return floats
    }

    // MARK: - Private inference helpers

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
            return try readFloats(outVal)
        } catch {
            return nil
        }
    }

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
