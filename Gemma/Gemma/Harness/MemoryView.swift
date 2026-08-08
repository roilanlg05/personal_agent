import SwiftUI

/// Hosts the memory inspector with a Lista / Grafo / Transcript segmented toggle.
/// Grafo restored as M3a follow-up: pulls nodes + edges from `GET /v1/graph`
/// instead of the previous direct GRDB access.
struct MemoryView: View {
    let client: MemoryClient?

    private enum Mode: String, CaseIterable {
        case grafo3d = "Grafo 3D"
        case grafo2d = "Grafo 2D"
        case lista = "Lista"
        case transcript = "Transcript"
    }
    @State private var mode: Mode = .grafo3d

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
            case .grafo3d: MemoryGraph3DView(client: client)
            case .grafo2d: MemoryGraphView(client: client)
            case .lista: MemoryInspectorView(client: client)
            case .transcript: TranscriptInspectorView(client: client)
            }
        }
    }
}
