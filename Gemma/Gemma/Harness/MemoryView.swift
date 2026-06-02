import SwiftUI

/// Hosts the memory inspector with a List / Transcript segmented toggle. The Grafo tab
/// from M2 is removed in M3a: it relied on direct GRDB access to read edges, and the
/// Memory Service does not yet expose `/v1/edges`.
/// TODO(m3a-follow-up): add `/v1/edges` on the service and restore the Grafo tab.
struct MemoryView: View {
    let client: MemoryClient?

    private enum Mode: String, CaseIterable { case lista = "Lista", transcript = "Transcript" }
    @State private var mode: Mode = .lista

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch mode {
            case .lista: MemoryInspectorView(client: client)
            case .transcript: TranscriptInspectorView(client: client)
            }
        }
    }
}
