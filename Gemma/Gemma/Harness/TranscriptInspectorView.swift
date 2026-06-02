import SwiftUI

/// Read-only view of the raw conversation log (the N4 substrate), newest-first. Separate from
/// the knowledge graph/list tabs (which show distilled memory only). Reads from the Memory
/// Service over HTTP (`/v1/transcript/recent`).
struct TranscriptInspectorView: View {
    let client: MemoryClient?
    @State private var rows: [MemoryClient.TranscriptRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
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
        .task {
            guard let client else { return }
            rows = (try? await client.transcriptRecent(limit: 200)) ?? []
        }
    }
}
