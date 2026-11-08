import SwiftUI

/// Lo que dice una fila de herramienta plegada.
///
/// Regla del usuario: contar es honesto, interpretar no; y cuando la herramienta
/// devuelve un dato concreto (un precio, un host), ese dato sí se ve.
public nonisolated enum ToolRowSummary: Equatable {
    case ok
    case value(String)
    case count(Int, String)
    case failure(String)
}

/// Fila del registro de chat para una llamada a herramienta. Plegada enseña el
/// estado, el nombre y un resumen; abierta, el resultado recortado.
public struct ToolLogRow: View {
    @Binding var entry: ChatLogEntry

    public init(entry: Binding<ChatLogEntry>) {
        self._entry = entry
    }

    /// Tope de caracteres que se pintan al abrir la fila. Un `browser_get html`
    /// de una página real son cientos de kB y un `Text` de ese tamaño cuelga la
    /// interfaz (sobre todo en el teléfono); 4000 caben en varias pantallas de
    /// lectura y se pintan al instante.
    public nonisolated static let detailLimit = 4_000

    // MARK: - Lógica pura

    /// Tope del mensaje de un estado no fallido: el resumen es una línea.
    public nonisolated static let messageLimit = 120

    /// Los únicos estados que pintan la fila en rojo. Medido sobre el repositorio
    /// el 2026-11-08: las herramientas devuelven 68 estados distintos y solo 11 de
    /// ellos son "success", así que tratar «no success» como fallo pinta en rojo la
    /// mayoría de los retornos correctos ("ok", "created", "deleted", "found"…).
    /// La polaridad va al revés: se enumera el fallo, no el éxito. Además, todo
    /// estado con prefijo `invalid_` es fallo.
    private nonisolated static let failureStatuses: Set<String> = [
        "failed", "error", "timeout", "unavailable", "memory_unavailable",
        "permission_denied", "rejected", "not_found", "contact_not_found",
        "place_not_found", "not_in_catalog", "unknown_topic", "unsupported",
        "unsupported_kind", "limit_reached", "missing_fields", "name_taken",
        "no_phone_number", "period_in_past",
    ]

    /// Cierra la fila de una herramienta: rellena el `toolDetail` de la última
    /// fila abierta con ese nombre. Se busca de atrás hacia delante porque puede
    /// haber dos llamadas a la misma herramienta en el mismo turno y la que se
    /// cierra es la última abierta. Si no hay ninguna (un `finished` sin su
    /// `started`), se añade una fila nueva para no perder el resultado.
    public nonisolated static func closeRow(in log: inout [ChatLogEntry], toolName: String, result: String) {
        if let i = log.lastIndex(where: { $0.role == "tool" && $0.toolName == toolName && $0.toolDetail == nil }) {
            log[i].toolDetail = result
        } else {
            log.append(ChatLogEntry(role: "tool", text: "", toolName: toolName, toolDetail: result))
        }
    }

    /// Qué herramientas devuelven un dato. Es el único sitio donde se decide;
    /// las que no aparecen aquí se resumen como `.ok`.
    private nonisolated enum Kind { case host, lines, valueOrCount, chars, count }
    private nonisolated static let table: [String: Kind] = [
        "browser_open": .host,
        "browser_snapshot": .lines,
        "browser_get": .valueOrCount,
        "read_webpage": .chars,
        "web_search": .count,
    ]

    public nonisolated static func summarize(toolName: String, resultJSON: String) -> ToolRowSummary {
        guard let data = resultJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            let t = resultJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(t.isEmpty ? "resultado vacío o ilegible" : String(t.prefix(120)))
        }
        let status = obj["status"] as? String
        let message = (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let status, failureStatuses.contains(status) || status.hasPrefix("invalid_") {
            return .failure(message.isEmpty ? status : message)
        }
        switch table[toolName] {
        case .host:
            if let s = obj["url"] as? String, let host = URL(string: s)?.host { return .value(host) }
            return .ok
        case .lines:
            guard let s = obj["snapshot"] as? String else { return .ok }
            let n = s.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
            return .count(n, "objetos")
        case .valueOrCount:
            if let v = obj["value"] as? String { return .value(v) }
            if let n = obj["count"] as? Int { return .count(n, "elementos") }
            return .ok
        case .chars:
            guard let s = obj["content"] as? String else { return .ok }
            return .count(s.count, "caracteres")
        case .count:
            guard let n = obj["count"] as? Int else { return .ok }
            return .count(n, "resultados")
        case nil:
            // Herramienta sin dato propio: si trae un mensaje corto y útil
            // (p. ej. «no_content»), se enseña en vez de un «listo» mudo.
            guard !message.isEmpty else { return .ok }
            return .value(message.count > messageLimit ? String(message.prefix(messageLimit)) + "…" : message)
        }
    }

    /// Texto que se ve al abrir la fila, recortado a `detailLimit`.
    public nonisolated static func detail(resultJSON: String) -> String {
        guard resultJSON.count > detailLimit else { return resultJSON }
        return String(resultJSON.prefix(detailLimit - 1)) + "…"
    }

    // MARK: - Vista

    private var summary: ToolRowSummary? {
        guard let name = entry.toolName, let detail = entry.toolDetail else { return nil }
        return Self.summarize(toolName: name, resultJSON: detail)
    }

    private var summaryText: String {
        switch summary {
        case nil: return "…"
        case .ok: return "listo"
        case .value(let v): return v
        case .count(let n, let what): return "\(n) \(what)"
        case .failure(let m): return m
        }
    }

    private var isFailure: Bool {
        if case .failure = summary { return true }
        return false
    }

    public var body: some View {
        let hasDetail = entry.toolDetail != nil
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    guard hasDetail else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { entry.isToolExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: summary == nil ? "ellipsis.circle"
                              : (isFailure ? "xmark.circle.fill" : "checkmark.circle.fill"))
                            .foregroundStyle(isFailure ? Color.red : Color.secondary)
                        Text(entry.toolName ?? "tool").font(.caption.monospaced())
                        Text(summaryText)
                            .font(.caption)
                            .foregroundStyle(isFailure ? Color.red : Color.secondary)
                            .lineLimit(entry.isToolExpanded ? nil : 2)
                        if hasDetail {
                            Image(systemName: entry.isToolExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                if entry.isToolExpanded, let d = entry.toolDetail {
                    Text(Self.detail(resultJSON: d))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }
}
