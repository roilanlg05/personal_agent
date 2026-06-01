import SwiftUI

/// Read-only view of the raw conversation log (the N4 substrate), newest-first. Separate from
/// the knowledge graph/list tabs (which show distilled memory only).
struct TranscriptInspectorView: View {
    let store: MemoryStore?
    @State private var rows: [TranscriptRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView("Sin conversación", systemImage: "text.bubble",
                                       description: Text("Aún no hay turnos guardados en el transcript."))
            } else {
                List(rows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.role == "assistant" ? "Gemma" : "Tú")
                            .font(.caption).foregroundStyle(row.role == "assistant" ? .blue : .secondary)
                        Text(row.text).textSelection(.enabled)
                    }
                }
            }
        }
        .task {
            guard let store else { return }
            rows = (try? TranscriptStore(dbQueue: store.dbQueue).allRecent(limit: 200)) ?? []
        }
    }
}
