import Foundation
import AVFoundation
import Observation

/// Always-listening orchestrator. When enabled, one AVAudioEngine 16 kHz mono tap feeds frames to
/// the wake detector; on "Hey Jarvis" it auto-captures the utterance (EnergyEndpointer) and hands a
/// WAV to `sendWav` (wired to VoiceController.send). Re-arms after. Detection is paused while busy.
/// All detector access is on the MainActor (the detector is not thread-safe).
@MainActor
@Observable
final class WakeListener {
    enum WakeState: Equatable { case off, listening, capturing, busy }
    private(set) var state: WakeState = .off

    @ObservationIgnored private let detector: WakeDetecting
    @ObservationIgnored private let sendWav: (Data) -> Void
    /// Injected by the owner: true while a voice turn (manual tap-to-talk OR a reply playing) is in
    /// progress. While true we don't act on the wake word — keeps wake + manual mic mutually exclusive
    /// and avoids detecting Gemma's own speech.
    @ObservationIgnored var isVoiceBusy: () -> Bool = { false }
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var frameTask: Task<Void, Never>?           // drains the tap stream on MainActor, in order
    @ObservationIgnored private var frameContinuation: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var busyWatchdog: Task<Void, Never>?        // fallback re-arm if playback never reports done
    @ObservationIgnored private var endpointer: EnergyEndpointer?
    @ObservationIgnored private var captured: [Float] = []
    @ObservationIgnored private var pending: [Float] = []
    @ObservationIgnored private let sampleRate = 16000.0
    @ObservationIgnored private let frameSamples = 1280
    @ObservationIgnored private let maxUtteranceSamples = 16000 * 15   // 15 s cap

    init(detector: WakeDetecting, sendWav: @escaping (Data) -> Void) {
        self.detector = detector
        self.sendWav = sendWav
    }

    func enable() async {
        guard state == .off else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return }
        do { try startEngine(); state = .listening } catch { state = .off }
    }
    func disable() {
        busyWatchdog?.cancel(); busyWatchdog = nil
        frameContinuation?.finish(); frameContinuation = nil
        frameTask?.cancel(); frameTask = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        pending = []; captured = []; endpointer = nil      // clear capture state so re-enable starts clean
        state = .off
    }

    /// Re-arm after the reply finished playing (called by the owner when VoiceController playback ends).
    func notePlaybackFinished() {
        busyWatchdog?.cancel(); busyWatchdog = nil
        if state == .busy { state = .listening }
    }

    /// Fallback: if the owner never calls notePlaybackFinished (send threw / playback stalled), re-arm
    /// after 30 s so the listener can never get permanently stuck in .busy.
    private func startBusyWatchdog() {
        busyWatchdog?.cancel()
        busyWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.state == .busy else { return }
            self.state = .listening
        }
    }

    // MARK: state machine (shared by the live tap and tests)
    private func handle(frame: [Float]) {
        switch state {
        case .listening:
            guard !isVoiceBusy() else { return }   // a manual turn / playback is active — don't detect
            if detector.process(frame: frame) > 0.5 {
                detector.reset()
                captured = []
                endpointer = EnergyEndpointer(frameMs: 80, silenceMs: 800, minSpeechMs: 300)
                state = .capturing
            }
        case .capturing:
            captured.append(contentsOf: frame)
            let done = endpointer?.update(frame: frame) ?? true
            if done || captured.count >= maxUtteranceSamples {
                if captured.count >= frameSamples * 4 {        // discard too-short captures
                    let wav = Self.makeWav(captured, sampleRate: Int(sampleRate))
                    state = .busy
                    startBusyWatchdog()
                    sendWav(wav)
                } else {
                    state = .listening
                }
                captured = []
                endpointer = nil
            }
        case .off, .busy:
            break                                              // ignore frames while off / sending / playing
        }
    }

    // MARK: live audio
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: target) else {
            throw NSError(domain: "WakeListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "audio converter unavailable"])
        }
        // Ordered hand-off from the background tap to the MainActor: yields preserve FIFO order
        // (fire-and-forget Tasks would not), so the streaming detector sees frames in sequence.
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        frameContinuation = continuation
        frameTask = Task { @MainActor [weak self] in
            for await samples in stream { self?.pump(samples) }
        }
        let sr = sampleRate, fs = frameSamples
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [continuation] buffer, _ in
            let ratio = sr / hwFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + AVAudioFrameCount(fs)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var err: NSError?
            var consumed = false   // one-shot: feed `buffer` once, then signal no-more-data
            converter.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
            continuation.yield(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func pump(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        while pending.count >= frameSamples {
            let frame = Array(pending.prefix(frameSamples))
            pending.removeFirst(frameSamples)
            handle(frame: frame)
        }
    }

    /// Minimal 16-bit PCM mono WAV from float samples.
    static func makeWav(_ samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d.append(le32(UInt32(36 + pcm.count)))
        d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.append(le32(16)); d.append(le16(1)); d.append(le16(1))
        d.append(le32(UInt32(sampleRate))); d.append(le32(UInt32(sampleRate * 2))); d.append(le16(2)); d.append(le16(16))
        d.append(Data("data".utf8)); d.append(le32(UInt32(pcm.count))); d.append(pcm)
        return d
    }

    // MARK: test hooks
    func beginListeningForTest() { state = .listening }
    func feedFrameForTest(_ frame: [Float]) { handle(frame: frame) }
}
