import SwiftUI

/// Hosts the memory inspector with a List / Graph / Transcript segmented toggle.
struct MemoryView: View {
    let store: MemoryStore?

    private enum Mode: String, CaseIterable { case lista = "Lista", grafo = "Grafo", transcript = "Transcript" }
    @State private var mode: Mode = .grafo

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
            case .lista: MemoryInspectorView(store: store)
            case .grafo: MemoryGraphView(store: store)
            case .transcript: TranscriptInspectorView(store: store)
            }
        }
    }
}
