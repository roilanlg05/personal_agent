import SwiftUI

/// Force-directed graph visualization of memory nodes and their edges.
/// Nodes are colored by `kind`, sized by `salience`; edges are drawn behind.
/// Drag a node to reposition it; tap a node to select it and inspect details.
///
/// Restored after M3a: consumes `MemoryClient.graph()` over HTTP instead of
/// reading the in-process `MemoryStore`.
struct MemoryGraphView: View {
    let client: MemoryClient?

    @State private var nodes: [MemoryClient.Node] = []
    @State private var edges: [MemoryClient.Edge] = []
    @State private var positions: [String: CGPoint] = [:]
    @State private var selectedID: String?
    @State private var canvasSize: CGSize = .zero

    private var nodeByID: [String: MemoryClient.Node] {
        Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        HStack(spacing: 0) {
            graphArea
            if let sel = selectedID, let node = nodeByID[sel] {
                Divider()
                MemoryGraphDetailPanel(node: node) { selectedID = nil }
                    .frame(width: 240)
                    .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle("Memory Graph")
        .task { await reload() }
        .toolbar { Button("Reload") { Task { await reload() } } }
    }

    private var graphArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if nodes.isEmpty {
                    ContentUnavailableView("No memories yet", systemImage: "brain",
                                           description: Text("Talk to the agent with memory enabled, then reload."))
                } else {
                    edgeLayer
                    nodeLayer
                    legend.padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { selectedID = nil }
            .onChange(of: geo.size) { oldSize, newSize in
                handleSizeChange(from: oldSize, to: newSize)
            }
            .onAppear {
                handleSizeChange(from: .zero, to: geo.size)
            }
        }
    }

    private var edgeLayer: some View {
        Canvas { ctx, _ in
            for e in edges {
                guard let a = positions[e.srcId], let b = positions[e.dstId] else { continue }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                ctx.stroke(path, with: .color(.secondary.opacity(0.35)),
                           lineWidth: 0.5 + CGFloat(min(e.weight, 4)) * 0.4)
            }
        }
        .allowsHitTesting(false)
    }

    private var nodeLayer: some View {
        ForEach(nodes) { node in
            let pos = positions[node.id] ?? .zero
            MemoryNodeMarker(node: node, isSelected: node.id == selectedID)
                .position(pos)
                .gesture(
                    DragGesture()
                        .onChanged { value in positions[node.id] = value.location }
                )
                .onTapGesture { selectedID = node.id }
        }
    }

    private var presentKinds: [String] {
        Array(Set(nodes.map(\.kind))).sorted()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(presentKinds, id: \.self) { kind in
                HStack(spacing: 4) {
                    Circle().fill(MemoryNodeMarker.color(for: kind)).frame(width: 8, height: 8)
                    Text(kind).font(.caption2)
                }
            }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func reload() async {
        guard let client else { return }
        let snap = (try? await client.graph(nodeLimit: 300))
            ?? MemoryClient.GraphSnapshot(nodes: [], edges: [])
        nodes = snap.nodes
        edges = snap.edges
        if let sel = selectedID, !nodes.contains(where: { $0.id == sel }) { selectedID = nil }
        positions = [:]
        if canvasSize != .zero { recomputeLayout() }
    }

    private func handleSizeChange(from oldSize: CGSize, to newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        let previous = canvasSize
        canvasSize = newSize

        if previous == .zero || positions.isEmpty {
            if !nodes.isEmpty { recomputeLayout() }
        } else if newSize != previous {
            rescalePositions(from: previous, to: newSize)
        }
    }

    private func recomputeLayout() {
        guard canvasSize != .zero else { return }
        let ids = nodes.map(\.id)
        let pairs = edges.map { ($0.srcId, $0.dstId) }
        positions = ForceDirectedLayout.layout(nodeIDs: ids, edges: pairs, in: canvasSize)
    }

    private func rescalePositions(from oldSize: CGSize, to newSize: CGSize) {
        guard oldSize.width > 0, oldSize.height > 0 else { return }
        let margin = ForceDirectedLayout.margin
        let maxX = max(Double(newSize.width) - margin, margin)
        let maxY = max(Double(newSize.height) - margin, margin)
        for (id, p) in positions {
            let x = Double(p.x) / Double(oldSize.width) * Double(newSize.width)
            let y = Double(p.y) / Double(oldSize.height) * Double(newSize.height)
            positions[id] = CGPoint(x: min(max(x, margin), maxX),
                                    y: min(max(y, margin), maxY))
        }
    }
}

/// Single node marker: circle sized by salience, filled by kind, with a label caption.
private struct MemoryNodeMarker: View {
    let node: MemoryClient.Node
    let isSelected: Bool

    // Kinds match what MemoryCore emits (see NodeKind enum in the service). String-keyed so
    // the model can mint extra kinds without us crashing — unknown kinds fall through to gray.
    static func color(for kind: String) -> Color {
        switch kind {
        case "person":       return .blue
        case "place":        return .green
        case "fact":         return .orange
        case "preference":   return .pink
        case "topic":        return .purple
        case "trait":        return .mint
        case "task":         return .red
        case "plan":         return .brown
        case "insight":      return .yellow
        case "day":          return .teal
        case "episode":      return .indigo
        case "conversation": return .gray
        case "summary":      return .cyan
        case "follow_up":    return .orange.opacity(0.7)
        case "clarification": return .pink.opacity(0.7)
        default:             return .secondary
        }
    }

    private var radius: CGFloat {
        let s = node.salience ?? 1.0
        let r = 6 + CGFloat(s) * 1.5
        return min(max(r, 6), 22)
    }

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(Self.color(for: node.kind))
                .frame(width: radius * 2, height: radius * 2)
                .overlay(Circle().stroke(isSelected ? Color.primary : .white.opacity(0.6),
                                         lineWidth: isSelected ? 2.5 : 1))
                .shadow(radius: isSelected ? 3 : 0)
            Text(node.label)
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: 90)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }
}

/// Side panel showing the selected node's details.
struct MemoryGraphDetailPanel: View {
    let node: MemoryClient.Node
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.label).font(.headline).lineLimit(2)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Divider()
            if !node.body.isEmpty, node.body != node.label {
                Text(node.body).font(.callout)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                detailRow("Kind", node.kind)
                if let layer = node.layer { detailRow("Layer", layer) }
                if let s = node.salience { detailRow("Salience", String(format: "%.2f", s)) }
                if let m = node.mentionCount { detailRow("Mentions", "\(m)") }
                if let c = node.confidence { detailRow("Confidence", c) }
            }
            .font(.caption)
            Spacer()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
