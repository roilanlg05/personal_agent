import SwiftUI

struct SettingsView: View {
    @Bindable var model: HarnessModel
    @State private var draft: GenerationSettings
    @FocusState private var promptFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: HarnessModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
    }

    private let contextChoices = [1024, 2048, 4096, 8192]

    var body: some View {
        NavigationStack {
            TabView {
                parametersTab
                    .tabItem { Label("Parameters", systemImage: "slider.horizontal.3") }
                systemPromptTab
                    .tabItem { Label("System Prompt", systemImage: "text.bubble") }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task {
                            await model.saveSettings(draft)
                            dismiss()
                        }
                    }
                    .bold()
                }
            }
        }
    }

    private var parametersTab: some View {
        Form {
            Section("Engine (reload to apply)") {
                Picker("Backend", selection: $draft.backend) {
                    Text("GPU").tag(ComputeBackend.gpu)
                    Text("CPU").tag(ComputeBackend.cpu)
                }
                Picker("Context (KV cache)", selection: $draft.contextLength) {
                    ForEach(contextChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Speculative decoding (MTP)", isOn: $draft.useSpeculativeDecoding)
                if engineLevelChanged {
                    Text("Changing these reloads the model on Save.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Section("Sampler (live)") {
                LabeledContent("Temperature: \(draft.temperature, specifier: "%.2f")") {
                    Slider(value: $draft.temperature, in: 0...2, step: 0.05)
                }
                LabeledContent("Top-P: \(draft.topP, specifier: "%.2f")") {
                    Slider(value: $draft.topP, in: 0...1, step: 0.01)
                }
                Stepper("Top-K: \(draft.topK)", value: $draft.topK, in: 1...128)
                Stepper("Max output tokens: \(draft.maxOutputTokens)", value: $draft.maxOutputTokens, in: 16...2048, step: 16)
            }
            Section("Memory (S5a)") {
                Toggle("Enable memory", isOn: Binding(
                    get: { draft.memoryEnabled ?? true },
                    set: { draft.memoryEnabled = $0 }
                ))
            }
        }
    }

    private var systemPromptTab: some View {
        Form {
            Section("System Prompt") {
                TextEditor(text: $draft.systemPrompt)
                    .frame(minHeight: 200)
                    .focused($promptFocused)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { promptFocused = false }
            }
        }
    }

    private var engineLevelChanged: Bool {
        draft.engineLevelDiffers(from: model.settings)
    }
}

#Preview {
    SettingsView(model: HarnessModel())
}
