import SwiftUI

/// Debug/verification view: lists stored memory nodes (kind / label / body / extra).
/// Reloads on appear and via the toolbar button. Reads from the Memory Service over HTTP (`/v1/nodes`).
struct MemoryInspectorView: View {
    let client: MemoryClient?
    @State private var nodes: [MemoryClient.Node] = []
    @State private var errorMessage: String? = nil

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
        .navigationTitle("Memoria")
        .overlay {
            if let err = errorMessage {
                ContentUnavailableView("Error de memoria", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else if nodes.isEmpty {
                ContentUnavailableView("Sin memorias", systemImage: "brain",
                                       description: Text("Habla con el agente con la memoria activada y luego recarga."))
            }
        }
        .task { await reload() }
        .toolbar { Button("Recargar") { Task { await reload() } } }
    }

    private func reload() async {
        guard let client else {
            nodes = []
            errorMessage = "Servicio de memoria no inicializado."
            return
        }
        do {
            let listed = try await client.nodes(limit: 200)
            nodes = listed.nodes
            errorMessage = nil
        } catch {
            errorMessage = "No se pudo conectar a \(client.baseURL.absoluteString): \(error.localizedDescription)"
        }
    }
}
