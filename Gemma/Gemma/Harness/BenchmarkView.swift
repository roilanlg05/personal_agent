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
                    .disabled(model.isRunning || model.isComparing || modelURL == nil)
                    Button {
                        if let url = modelURL { Task { await model.compareMTP(modelURL: url) } }
                    } label: {
                        if let p = model.progress, model.isComparing {
                            Text("Comparing MTP… \(p.completed)/\(p.total)")
                        } else {
                            Text("Compare MTP on/off")
                        }
                    }
                    .disabled(model.isRunning || model.isComparing || modelURL == nil)
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
                if let c = model.comparison {
                    Section("MTP off vs on (avg of \(c.mtpOff.runs.count) run\(c.mtpOff.runs.count == 1 ? "" : "s"))") {
                        comparisonRow("", "MTP off", "MTP on")
                        comparisonRow("Prefill tok/s",
                                      String(format: "%.1f", c.mtpOff.avgPrefillTokPerSec),
                                      String(format: "%.1f", c.mtpOn.avgPrefillTokPerSec))
                        comparisonRow("Decode tok/s",
                                      String(format: "%.1f", c.mtpOff.avgDecodeTokPerSec),
                                      String(format: "%.1f", c.mtpOn.avgDecodeTokPerSec))
                        comparisonRow("TTFT s",
                                      String(format: "%.2f", c.mtpOff.avgTTFTSeconds),
                                      String(format: "%.2f", c.mtpOn.avgTTFTSeconds))
                        comparisonRow("First init s",
                                      String(format: "%.2f", c.mtpOff.firstInitSeconds),
                                      String(format: "%.2f", c.mtpOn.firstInitSeconds))
                        HStack {
                            Text("Decode speedup").bold()
                            Spacer()
                            Text(String(format: "×%.2f", c.decodeSpeedup)).monospaced().bold()
                        }
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

    private func comparisonRow(_ label: String, _ off: String, _ on: String) -> some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(off).monospaced().frame(maxWidth: .infinity, alignment: .trailing)
            Text(on).monospaced().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

#Preview {
    BenchmarkView(model: BenchmarkModel(), modelURL: nil)
}
