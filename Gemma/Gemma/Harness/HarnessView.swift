import SwiftUI
import UIKit

struct HarnessView: View {
    @State private var model = HarnessModel()
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                statusBar
                Divider()
                runtimePicker
                Divider()
                promptArea
                Divider()
                outputArea
                Divider()
                metricsBar
                if let path = model.benchReportPath {
                    Text("Bench report: \(path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .padding()
            .navigationTitle("Gemma Harness")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { promptFocused = false }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $model.showImagePicker) {
                ImagePickerView(image: $model.pickedImage)
            }
            .sheet(isPresented: $model.showCatalog) {
                CatalogView(model: model)
            }
            .sheet(isPresented: $model.showBenchmark) {
                BenchmarkView(model: model.benchmark, modelURL: model.benchmarkModelURL)
            }
            .sheet(isPresented: $model.showSettings) {
                SettingsView(model: model)
            }
            .sheet(isPresented: $model.showAgent) {
                AgentView(model: model)
            }
            .sheet(isPresented: $model.showMemory) {
                NavigationStack { MemoryInspectorView(store: model.inspectorStore()) }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                .disabled(model.isGenerating)
            Button("Models") { model.showCatalog = true }
                .disabled(model.isGenerating)
            Button("Agent") { model.showAgent = true }
                .disabled(model.isGenerating)
            Button("Memory") { model.showMemory = true }
                .disabled(model.isGenerating)
            Button(model.modelLoaded ? "Unload" : "Load") {
                Task { await model.toggleLoad() }
            }
            .disabled(model.isLoadingModel || model.isGenerating)
        }
    }

    private var runtimePicker: some View {
        Picker("Runtime", selection: $model.runtimeKind) {
            ForEach(RuntimeKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.isLoadingModel || model.isGenerating)
    }

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt").font(.headline)
            TextEditor(text: $model.prompt)
                .frame(minHeight: 80)
                .border(.quaternary)
                .focused($promptFocused)
            HStack {
                Button(model.pickedImage == nil ? "Attach image" : "Replace image") {
                    model.showImagePicker = true
                }
                if let img = model.pickedImage {
                    Image(uiImage: img).resizable().scaledToFit().frame(height: 32)
                    Button("Clear") { model.pickedImage = nil }
                }
                Spacer()
                Button("Generate") {
                    Task { await model.runSingle() }
                }
                .disabled(!model.modelLoaded || model.isGenerating)

                Button("Benchmark") {
                    Task { await model.presentBenchmark() }
                }
                .disabled(model.isGenerating)
            }
        }
    }

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output").font(.headline)
            ScrollView {
                Text(model.streamedOutput.isEmpty ? "—" : model.streamedOutput)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
            .background(Color.secondary.opacity(0.08))
        }
    }

    private var metricsBar: some View {
        HStack(spacing: 16) {
            if let m = model.lastMetrics {
                Text(String(format: "tok/s: %.1f", m.tokensPerSecond))
                Text(String(format: "TTFT: %.2fs", m.timeToFirstTokenSeconds))
                Text("RAM: \(byteString(m.peakResidentMemoryBytes))")
            } else {
                Text("No metrics yet.").foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospaced())
    }

    private func byteString(_ b: UInt64) -> String {
        let mb = Double(b) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}

#Preview {
    HarnessView()
}
