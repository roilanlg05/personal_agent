import SwiftUI
import AVFoundation

struct WakeWordEnrollmentView: View {
    let detector: WakeDetecting
    @Environment(\.dismiss) private var dismiss

    @State private var step: Int = 1 // 1, 2, 3, or 4 (done)
    @State private var isRecording: Bool = false
    @State private var recordings: [Data] = []
    @State private var errorMessage: String? = nil
    @State private var audioRecorder = AudioRecorder()
    @State private var phraseText: String = "Hey Gemma"

    var body: some View {
        VStack(spacing: 20) {
            Text("Entrenamiento de Voz")
                .font(.title2).bold()

            Text("Para activar Gemma con tu voz, necesitamos registrar tu frase y timbre de voz de forma segura en este dispositivo.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 8) {
                Text("Di claramente:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\"\(phraseText)\"")
                    .font(.largeTitle).bold()
                    .foregroundStyle(.blue)
            }
            .padding()
            .background(Color.blue.opacity(0.08))
            .cornerRadius(12)

            // Steps indicator
            HStack(spacing: 12) {
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .fill(step > i ? Color.green : (step == i ? Color.blue : Color.gray.opacity(0.3)))
                        .frame(width: 24, height: 24)
                        .overlay {
                            if step > i {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(i)")
                                    .font(.caption2).bold()
                                    .foregroundStyle(step == i ? .white : .secondary)
                            }
                        }
                }
            }
            .padding(.vertical)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if step <= 3 {
                Button(action: toggleRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        Text(isRecording ? "Detener Grabación" : "Grabar Intento \(step)")
                    }
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .blue)
                .padding(.horizontal, 40)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("¡Configuración Completada!")
                        .font(.headline)
                    Text("Gemma ahora responderá únicamente a tu voz y a la frase registrada.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Finalizar") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top)
                }
            }

            Spacer()
        }
        .padding(.vertical, 30)
        .frame(width: 400, height: 420)
        .onDisappear {
            if isRecording {
                _ = audioRecorder.stop()
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            isRecording = false
            if let data = audioRecorder.stop() {
                recordings.append(data)
                errorMessage = nil
                if step < 3 {
                    step += 1
                } else {
                    // Process enrollment
                    do {
                        try detector.enroll(recordings: recordings)
                        step = 4
                    } catch {
                        errorMessage = error.localizedDescription
                        recordings = []
                        step = 1
                    }
                }
            } else {
                errorMessage = "No se pudo obtener el audio de la grabación."
            }
        } else {
            errorMessage = nil
            do {
                try audioRecorder.start()
                isRecording = true
                // Auto-stop after 2.2 seconds to keep templates uniform
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    if self.isRecording {
                        self.toggleRecording()
                    }
                }
            } catch {
                errorMessage = "Error al iniciar el micrófono: \(error.localizedDescription)"
            }
        }
    }
}
