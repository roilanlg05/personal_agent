import CoreGraphics
import Foundation

/// One node in the layout simulation. Pure value type — no view dependency.
struct GraphLayoutNode {
    let id: String
    var position: CGPoint
    var velocity: CGPoint
}

/// A deterministic, dependency-free Fruchterman–Reingold-style force-directed
/// layout. Nodes are seeded on a circle (by index) so the same input always
/// produces the same output — making it reproducible and unit-testable.
struct ForceDirectedLayout {
    /// Margin (in points) kept between node positions and the canvas edges.
    static let margin: Double = 8.0

    /// Lay out `nodeIDs` connected by `edges` within `size`.
    /// - Returns: a map of node id -> position, all finite and clamped into `size`.
    /// - Note: O(n²) per iteration (all-pairs repulsion); intended for small graphs
    ///   (≲ ~150 nodes). Larger graphs would need Barnes–Hut approximation or fewer iterations.
    static func layout(nodeIDs: [String],
                       edges: [(String, String)],
                       in size: CGSize,
                       iterations: Int = 300) -> [String: CGPoint] {
        let n = nodeIDs.count
        guard n > 0 else { return [:] }

        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let center = CGPoint(x: width / 2, y: height / 2)

        if n == 1 {
            return [nodeIDs[0]: center]
        }

        // Index lookup for edge resolution.
        var indexOf: [String: Int] = [:]
        for (i, id) in nodeIDs.enumerated() { indexOf[id] = i }

        // Deterministic seeding: nodes evenly spaced on a circle by index.
        let radius = min(width, height) * 0.35
        var nodes: [GraphLayoutNode] = nodeIDs.enumerated().map { i, id in
            let angle = (2 * Double.pi * Double(i)) / Double(n)
            let p = CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                            y: center.y + radius * CGFloat(sin(angle)))
            return GraphLayoutNode(id: id, position: p, velocity: .zero)
        }

        // Resolve edges to index pairs (skip dangling / self edges).
        let edgePairs: [(Int, Int)] = edges.compactMap { e in
            guard let a = indexOf[e.0], let b = indexOf[e.1], a != b else { return nil }
            return (a, b)
        }

        // Ideal edge length k = C * sqrt(area / n).
        let area = Double(width * height)
        let k = sqrt(area / Double(n))
        let kSquared = k * k

        var temperature = Double(min(width, height)) * 0.1
        let cooling = pow(0.01, 1.0 / Double(max(iterations, 1)))

        for _ in 0..<iterations {
            var disp = [CGPoint](repeating: .zero, count: n)

            // Repulsion between all pairs: f = k^2 / dist.
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dx = Double(nodes[i].position.x - nodes[j].position.x)
                    var dy = Double(nodes[i].position.y - nodes[j].position.y)
                    var dist = sqrt(dx * dx + dy * dy)
                    if dist < 0.01 {
                        // Deterministic tiny offset so coincident nodes separate.
                        dx = Double((i % 7) - 3) * 0.01 + 0.001
                        dy = Double((j % 7) - 3) * 0.01 + 0.001
                        dist = max(sqrt(dx * dx + dy * dy), 0.01)
                    }
                    let force = kSquared / dist
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    disp[i].x += CGFloat(fx); disp[i].y += CGFloat(fy)
                    disp[j].x -= CGFloat(fx); disp[j].y -= CGFloat(fy)
                }
            }

            // Attraction along edges: f = dist^2 / k.
            for (a, b) in edgePairs {
                let dx = Double(nodes[a].position.x - nodes[b].position.x)
                let dy = Double(nodes[a].position.y - nodes[b].position.y)
                let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                let force = (dist * dist) / k
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                disp[a].x -= CGFloat(fx); disp[a].y -= CGFloat(fy)
                disp[b].x += CGFloat(fx); disp[b].y += CGFloat(fy)
            }

            // Apply displacement, limited by temperature; mild centering pull.
            for i in 0..<n {
                let dx = Double(disp[i].x)
                let dy = Double(disp[i].y)
                let mag = max(sqrt(dx * dx + dy * dy), 0.01)
                let limited = min(mag, temperature)
                var x = Double(nodes[i].position.x) + (dx / mag) * limited
                var y = Double(nodes[i].position.y) + (dy / mag) * limited

                // Mild centering so disconnected components don't drift away.
                x += (Double(center.x) - x) * 0.01
                y += (Double(center.y) - y) * 0.01

                // Clamp into bounds with a small margin.
                let margin = Self.margin
                x = min(max(x, margin), Double(width) - margin)
                y = min(max(y, margin), Double(height) - margin)

                nodes[i].position = CGPoint(x: x, y: y)
            }

            temperature *= cooling
        }

        var out: [String: CGPoint] = [:]
        for node in nodes {
            // Final safety against any non-finite value.
            let x = node.position.x.isFinite ? node.position.x : center.x
            let y = node.position.y.isFinite ? node.position.y : center.y
            out[node.id] = CGPoint(x: x, y: y)
        }
        return out
    }
}
