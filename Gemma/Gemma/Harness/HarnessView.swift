import SwiftUI
import UIKit

@MainActor
struct HarnessView: View {
    @State private var prompt: String = "Hola, ¿cómo estás?"
    @State private var streamedOutput: String = ""
    @State private var isGenerating: Bool = false
    @State private var isLoadingModel: Bool = false
    @State private var modelLoaded: Bool = false
    @State private var lastMetrics: RuntimeMetrics?
    @State private var benchReportPath: String?
    @State private var pickedImage: UIImage?
    @State private var showImagePicker: Bool = false
    @State private var statusMessage: String = "Runtime: dummy (not loaded)"

    private let runtime: ModelRuntime = DummyRuntime()
    private let runner = BenchRunner()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                statusBar
                Divider()
                promptArea
                Divider()
                outputArea
                Divider()
                metricsBar
                if let path = benchReportPath {
                    Text("Bench report: \(path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .padding()
            .navigationTitle("Gemma Harness")
            .sheet(isPresented: $showImagePicker) {
                ImagePickerView(image: $pickedImage)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(modelLoaded ? "Unload" : "Load") {
                Task { await toggleLoad() }
            }
            .disabled(isLoadingModel || isGenerating)
        }
    }

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt").font(.headline)
            TextEditor(text: $prompt).frame(minHeight: 80).border(.quaternary)
            HStack {
                Button(pickedImage == nil ? "Attach image" : "Replace image") {
                    showImagePicker = true
                }
                if let img = pickedImage {
                    Image(uiImage: img).resizable().scaledToFit().frame(height: 32)
                    Button("Clear") { pickedImage = nil }
                }
                Spacer()
                Button("Generate") {
                    Task { await runSingle() }
                }
                .disabled(!modelLoaded || isGenerating)

                Button("Run Bench") {
                    Task { await runBench() }
                }
                .disabled(!modelLoaded || isGenerating)
            }
        }
    }

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output").font(.headline)
            ScrollView {
                Text(streamedOutput.isEmpty ? "—" : streamedOutput)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
            .background(Color.secondary.opacity(0.08))
        }
    }

    private var metricsBar: some View {
        HStack(spacing: 16) {
            if let m = lastMetrics {
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

    // MARK: - Actions

    private func toggleLoad() async {
        if modelLoaded {
            await runtime.unload()
            modelLoaded = false
            statusMessage = "Runtime: dummy (unloaded)"
            return
        }
        isLoadingModel = true
        statusMessage = "Loading…"
        do {
            try await runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
            modelLoaded = true
            statusMessage = "Runtime: dummy (loaded)"
        } catch {
            statusMessage = "Load failed: \(error)"
        }
        isLoadingModel = false
    }

    private func runSingle() async {
        isGenerating = true
        streamedOutput = ""
        defer { isGenerating = false }
        do {
            let result = try await runtime.generate(
                prompt: prompt,
                image: pickedImage,
                options: GenerationOptions(maxTokens: 128),
                onToken: { piece in
                    Task { @MainActor in streamedOutput += piece }
                }
            )
            lastMetrics = result.metrics
        } catch {
            streamedOutput += "\n[error: \(error)]"
        }
    }

    private func runBench() async {
        isGenerating = true
        streamedOutput = "Running bench…"
        defer { isGenerating = false }
        do {
            let report = try await runner.run(
                runtime: runtime,
                modelDescription: "DummyRuntime (Plan 1 scaffold)",
                useSpeculativeDecoding: false,
                useMmap: true,
                prompts: PromptSet.all.filter { $0.category != .image }
            )
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = try report.writeToDocuments(filename: "bench-\(stamp).json")
            benchReportPath = url.path
            streamedOutput = "Bench done: \(report.results.count) prompts. Report at \(url.lastPathComponent)."
            lastMetrics = report.results.last?.metrics
        } catch {
            streamedOutput = "Bench failed: \(error)"
        }
    }
}

#Preview {
    HarnessView()
}
