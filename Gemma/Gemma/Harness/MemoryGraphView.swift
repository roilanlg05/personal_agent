import SwiftUI

/// Force-directed graph visualization of memory nodes and their edges.
/// Nodes are colored by `kind`, sized by `salience`; edges are drawn behind.
/// Drag a node to reposition it; tap a node to select it and inspect details.
struct MemoryGraphView: View {
    let store: MemoryStore?

    @State private var nodes: [Node] = []
    @State private var edges: [Edge] = []
    @State private var positions: [String: CGPoint] = [:]
    @State private var selectedID: String?
    @State private var canvasSize: CGSize = .zero

    private var nodeByID: [String: Node] { Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

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
        .task { reload() }
        .toolbar { Button("Reload") { reload() } }
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
            .onChange(of: geo.size) { _, newSize in
                if canvasSize == .zero { canvasSize = newSize; recomputeLayout() }
            }
            .onAppear {
                if canvasSize == .zero { canvasSize = geo.size }
                if positions.isEmpty { recomputeLayout() }
            }
        }
    }

    // MARK: Edges (drawn behind nodes)
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

    // MARK: Nodes (on top, draggable + tappable)
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

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(NodeKind.allCases, id: \.self) { kind in
                if nodes.contains(where: { $0.kind == kind }) {
                    HStack(spacing: 4) {
                        Circle().fill(MemoryNodeMarker.color(for: kind)).frame(width: 8, height: 8)
                        Text(kind.rawValue).font(.caption2)
                    }
                }
            }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func reload() {
        nodes = (try? store?.allNodes()) ?? []
        edges = (try? store?.allEdges()) ?? []
        if let sel = selectedID, !nodes.contains(where: { $0.id == sel }) { selectedID = nil }
        recomputeLayout()
    }

    private func recomputeLayout() {
        let size = canvasSize == .zero ? CGSize(width: 600, height: 400) : canvasSize
        let ids = nodes.map(\.id)
        let pairs = edges.map { ($0.srcId, $0.dstId) }
        positions = ForceDirectedLayout.layout(nodeIDs: ids, edges: pairs, in: size)
    }
}

/// A single node marker: a circle sized by salience, filled by kind, with a label caption.
private struct MemoryNodeMarker: View {
    let node: Node
    let isSelected: Bool

    static func color(for kind: NodeKind) -> Color {
        switch kind {
        case .person: return .blue
        case .place: return .green
        case .fact: return .orange
        case .preference: return .pink
        case .topic: return .purple
        case .day: return .teal
        case .episode: return .indigo
        case .conversation: return .gray
        }
    }

    private var radius: CGFloat {
        // salience is typically small (≈0–10); clamp to a reasonable pixel range.
        let r = 6 + CGFloat(node.salience) * 1.5
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
        // Enlarge hit area for easier tap/drag.
        .contentShape(Rectangle())
    }
}

/// Side panel showing the selected node's details.
private struct MemoryGraphDetailPanel: View {
    let node: Node
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
                detailRow("Kind", node.kind.rawValue)
                detailRow("Layer", node.layer.rawValue)
                detailRow("Salience", String(format: "%.2f", node.salience))
                detailRow("Mentions", "\(node.mentionCount)")
                detailRow("Confidence", node.confidence.rawValue)
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
