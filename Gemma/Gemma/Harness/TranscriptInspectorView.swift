import SwiftUI

/// Read-only view of the raw conversation log, newest-first.
/// Reads from the Memory Service over HTTP (`/v1/transcript/recent`).
struct TranscriptInspectorView: View {
    let client: MemoryClient?
    @State private var rows: [MemoryClient.TranscriptRow] = []
    @State private var errorMessage: String? = nil

    var body: some View {
        Group {
            if let err = errorMessage {
                ContentUnavailableView("Error de conexión", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else if rows.isEmpty {
                ContentUnavailableView("Sin conversación", systemImage: "text.bubble",
                                       description: Text("Aún no hay turnos guardados en el transcript."))
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.role == "assistant" ? "Gemma" : "Tú")
                            .font(.caption).foregroundStyle(row.role == "assistant" ? .blue : .secondary)
                        Text(row.text).textSelection(.enabled)
                    }
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        guard let client else {
            errorMessage = "Servicio de memoria no inicializado."
            return
        }
        do {
            rows = try await client.transcriptRecent(limit: 200)
            errorMessage = nil
        } catch {
            errorMessage = "No se pudo obtener el transcript de \(client.baseURL.absoluteString): \(error.localizedDescription)"
        }
    }
}
