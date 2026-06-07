import Foundation
import AVFoundation
import Observation

/// Drives one voice turn: record -> POST to the i3 -> append transcript+reply to the chat -> play.
/// `appendLine` and `threadId` are injected by HarnessModel (avoids an Observable retain cycle).
@MainActor
@Observable
final class VoiceController: NSObject, AVAudioPlayerDelegate {
    enum State: Equatable { case idle, recording, sending, playing }
    private(set) var state: State = .idle

    @ObservationIgnored private let recorder: Recording
    @ObservationIgnored var client: VoiceTurning?
    @ObservationIgnored var appendLine: (String) -> Void = { _ in }
    @ObservationIgnored var threadId: () -> String = { "voice" }
    @ObservationIgnored private var player: AVAudioPlayer?

    init(recorder: Recording) {
        self.recorder = recorder
        super.init()
    }

    /// Build the real client from settings (called by HarnessModel.ensureVoice()).
    func configure(baseURL: URL, token: String) {
        client = VoiceClient(baseURL: baseURL, bearerToken: token)
    }

    /// The single UI entry point (mic button).
    func toggleRecording() {
        switch state {
        case .idle:
            // Flip to .recording SYNCHRONOUSLY so a second tap during the async permission
            // await can't spawn a second recording; beginRecording reverts to .idle on failure.
            state = .recording
            Task { await beginRecording() }
        case .recording: finishRecording()
        case .sending, .playing: break   // ignore taps mid-flight
        }
    }

    func beginRecording() async {
        guard await recorder.requestPermission() else {
            appendLine("voice: micrófono denegado (Ajustes → Privacidad → Micrófono).")
            state = .idle
            return
        }
        do {
            try recorder.start()
            state = .recording
        } catch {
            appendLine("voice: no pude iniciar la grabación (\(error.localizedDescription))")
            state = .idle
        }
    }

    private func finishRecording() {
        guard let wav = recorder.stop() else { state = .idle; return }
        state = .sending
        Task { await send(wav) }
    }

    func send(_ wav: Data) async {
        guard let client else {
            appendLine("voice: configura la URL del servicio de voz en Ajustes.")
            state = .idle
            return
        }
        do {
            let reply = try await client.turn(wav: wav, threadId: threadId(),
                                              timezone: TimeZone.current.identifier)
            appendLine("you: \(reply.sttText)")
            appendLine("gemma: \(reply.replyText)")
            play(reply.audio)
        } catch VoiceError.silence {
            state = .idle   // nothing heard — don't clutter the chat
        } catch {
            appendLine("voice: \(error)")
            state = .idle
        }
    }

    private func play(_ audio: Data) {
        do {
            let p = try AVAudioPlayer(data: audio)
            p.delegate = self
            player = p
            state = .playing
            p.play()
        } catch {
            state = .idle   // reply text is already shown; nothing to play
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.state = .idle
        }
    }
}
