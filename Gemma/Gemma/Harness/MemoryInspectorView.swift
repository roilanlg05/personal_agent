import SwiftUI

/// Debug/verification view: lists stored memory nodes (kind / label / body / extra).
/// Reloads on appear and via the toolbar button. Reads from the Memory Service over HTTP
/// (`/v1/nodes`). Salience / mention count / layer aren't exposed by the inspector
/// endpoint yet — they remain only in the service DB.
/// TODO(m3a-follow-up): extend `/v1/nodes` to surface layer + salience + mentionCount.
struct MemoryInspectorView: View {
    let client: MemoryClient?
    @State private var nodes: [MemoryClient.Node] = []

    var body: some View {
        List(nodes) { n in
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(n.kind)] \(n.label)")
                    .font(.subheadline).bold()
                if !n.body.isEmpty, n.body != n.label {
                    Text(n.body).font(.caption)
                }
                if let extra = n.extra, !extra.isEmpty {
                    Text(extra).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Memory")
        .overlay {
            if nodes.isEmpty {
                ContentUnavailableView("No memories yet", systemImage: "brain",
                                       description: Text("Talk to the agent with memory enabled, then reload."))
            }
        }
        .task { await reload() }
        .toolbar { Button("Reload") { Task { await reload() } } }
    }

    private func reload() async {
        guard let client else { nodes = []; return }
        let listed = (try? await client.nodes(limit: 200)) ?? .init(nodes: [], total: 0)
        nodes = listed.nodes
    }
}
