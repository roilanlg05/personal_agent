import Foundation
import Speech
import AVFoundation

@Observable
@MainActor
final class SpeechDictationManager: NSObject, SFSpeechRecognizerDelegate, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case recording
        case processing
    }

    var state: State = .idle
    var lastError: String?

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    override init() {
        super.init()
        let locale = Locale.preferredLanguages.first.map { Locale(identifier: $0) } ?? Locale(identifier: "es-ES")
        speechRecognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        speechRecognizer?.delegate = self
    }

    func requestAuthorization() async -> Bool {
        #if os(iOS)
        let audioStatus = await AVCaptureDevice.requestAccess(for: .audio)
        guard audioStatus else {
            lastError = "Permiso de micrófono denegado."
            return false
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus == .authorized)
            }
        }
        #else
        return false
        #endif
    }

    func startDictation(existingText: String, onUpdate: @escaping @MainActor (String) -> Void) async -> Bool {
        guard state == .idle else { return false }
        lastError = nil

        guard await requestAuthorization() else {
            lastError = "Permiso de reconocimiento de voz no disponible."
            return false
        }

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            lastError = "Error al configurar audio: \(error.localizedDescription)"
            return false
        }
        #endif

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode

        let req = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = req
        req.shouldReportPartialResults = true

        let prefix = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseText = prefix.isEmpty ? "" : prefix + " "

        recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                if let result {
                    let speechText = result.bestTranscription.formattedString
                    let combined = baseText + speechText
                    onUpdate(combined)
                }
                if let error {
                    // Ignore normal cancellation errors
                    let nsErr = error as NSError
                    if nsErr.domain == "kAFAssistantErrorDomain" && (nsErr.code == 203 || nsErr.code == 216) {
                        return
                    }
                    if nsErr.domain == "kLSRErrorDomain" && nsErr.code == 102 {
                        return
                    }
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            req.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            state = .recording
            return true
        } catch {
            lastError = "No se pudo iniciar el motor de audio: \(error.localizedDescription)"
            stopDictation()
            return false
        }
    }

    func stopDictation() {
        guard state != .idle else { return }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        audioEngine = nil

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        state = .idle
    }
}
