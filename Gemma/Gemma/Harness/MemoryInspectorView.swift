import SwiftUI

/// Debug/verification view: lists stored memory nodes with their layer, salience and
/// mention count. Reloads on appear and via the toolbar button.
struct MemoryInspectorView: View {
    let store: MemoryStore?
    @State private var nodes: [Node] = []

    var body: some View {
        List(nodes) { n in
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(n.kind.rawValue)/\(n.layer.rawValue)] \(n.label)")
                    .font(.subheadline).bold()
                if !n.body.isEmpty, n.body != n.label {
                    Text(n.body).font(.caption)
                }
                Text("salience \(String(format: "%.2f", n.salience)) · ×\(n.mentionCount) · \(n.confidence.rawValue)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Memory")
        .overlay {
            if nodes.isEmpty {
                ContentUnavailableView("No memories yet", systemImage: "brain",
                                       description: Text("Talk to the agent with memory enabled, then reload."))
            }
        }
        .task { reload() }
        .toolbar { Button("Reload") { reload() } }
    }

    private func reload() { nodes = (try? store?.allNodes()) ?? [] }
}
