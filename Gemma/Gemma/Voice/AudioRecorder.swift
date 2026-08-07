import Foundation
import AVFoundation

/// Mic capture abstraction. Real impl records 16 kHz mono PCM16 WAV; a fake backs VoiceController tests.
protocol Recording: AnyObject, Sendable {
    func requestPermission() async -> Bool
    func start() throws
    func stop() -> Data?
}

/// Records the microphone to a temp 16 kHz mono PCM16 WAV (the format the i3 STT requires — it
/// assumes 16 kHz; sending 44.1/48 kHz would garble transcription). macOS needs no AVAudioSession.
final class AudioRecorder: Recording, @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma-voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.record()
        recorder = rec
        fileURL = url
    }

    func stop() -> Data? {
        recorder?.stop()
        recorder = nil
        defer { fileURL = nil }
        guard let url = fileURL else { return nil }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }
}
