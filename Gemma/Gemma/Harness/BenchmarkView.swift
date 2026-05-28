import SwiftUI

struct BenchmarkView: View {
    @Bindable var model: BenchmarkModel
    let modelURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Parameters") {
                    Picker("Backend", selection: $model.config.backend) {
                        Text("GPU").tag(ComputeBackend.gpu)
                        Text("CPU").tag(ComputeBackend.cpu)
                    }
                    Stepper("Prefill tokens: \(model.config.prefillTokens)", value: $model.config.prefillTokens, in: 64...2048, step: 64)
                    Stepper("Decode tokens: \(model.config.decodeTokens)", value: $model.config.decodeTokens, in: 64...2048, step: 64)
                    Stepper("Runs: \(model.config.runCount)", value: $model.config.runCount, in: 1...20)
                }
                Section {
                    Button {
                        if let url = modelURL { Task { await model.run(modelURL: url) } }
                    } label: {
                        if let p = model.progress, model.isRunning {
                            Text("Running… \(p.completed)/\(p.total)")
                        } else {
                            Text("Run benchmark")
                        }
                    }
                    .disabled(model.isRunning || modelURL == nil)
                }
                if let r = model.result {
                    Section("Results (avg of \(r.runs.count) run\(r.runs.count == 1 ? "" : "s"))") {
                        resultRow("First init", String(format: "%.2f s", r.firstInitSeconds))
                        resultRow("Warm init (avg)", String(format: "%.2f s", r.avgWarmInitSeconds))
                        resultRow("TTFT (avg)", String(format: "%.2f s", r.avgTTFTSeconds))
                        resultRow("Prefill (avg)", String(format: "%.1f tok/s", r.avgPrefillTokPerSec))
                        resultRow("Decode (avg)", String(format: "%.1f tok/s", r.avgDecodeTokPerSec))
                    }
                }
                if let err = model.errorMessage {
                    Section { Text("Error: \(err)").font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Benchmark")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(model.isRunning)
                }
            }
        }
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospaced() }
    }
}

#Preview {
    BenchmarkView(model: BenchmarkModel(), modelURL: nil)
}
