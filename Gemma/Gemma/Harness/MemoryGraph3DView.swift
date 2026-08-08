import SwiftUI
import SceneKit

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#elseif os(iOS)
import UIKit
typealias PlatformColor = UIColor
#endif

/// Interactive 3D Force-Directed Knowledge Graph visualization using SceneKit.
/// Spheres represent memory nodes (colored by kind, sized by salience),
/// connected by 3D line edges. Allows full 3D rotation, panning, zooming, and node inspection.
struct MemoryGraph3DView: View {
    let client: MemoryClient?

    @State private var scene = SCNScene()
    @State private var nodes: [MemoryClient.Node] = []
    @State private var edges: [MemoryClient.Edge] = []
    @State private var selectedNode: MemoryClient.Node?
    @State private var isLoading = false

    private var nodeByID: [String: MemoryClient.Node] {
        Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SceneView(
                scene: scene,
                options: [.allowsCameraControl, .autoenablesDefaultLighting]
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                    }
                    Spacer()
                    Button {
                        Task { await reload() }
                    } label: {
                        Label("Recargar 3D", systemImage: "arrow.clockwise")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding()

                Spacer()

                if let node = selectedNode {
                    MemoryGraphDetailPanel(node: node) { selectedNode = nil }
                        .frame(maxWidth: 360)
                        .padding()
                        .transition(AnyTransition.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }

        let snap = (try? await client.graph(nodeLimit: 300))
            ?? MemoryClient.GraphSnapshot(nodes: [], edges: [])
        self.nodes = snap.nodes
        self.edges = snap.edges

        build3DScene()
    }

    private func build3DScene() {
        let newScene = SCNScene()
        newScene.background.contents = PlatformColor.windowBackgroundColor

        // 1. Camera Node
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 30)
        newScene.rootNode.addChildNode(cameraNode)

        // 2. Lighting
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 500
        newScene.rootNode.addChildNode(ambientLight)

        let omniLight = SCNNode()
        omniLight.light = SCNLight()
        omniLight.light?.type = .omni
        omniLight.light?.intensity = 1000
        omniLight.position = SCNVector3(10, 20, 30)
        newScene.rootNode.addChildNode(omniLight)

        guard !nodes.isEmpty else {
            self.scene = newScene
            return
        }

        // 3. Compute 3D positions
        let ids = nodes.map(\.id)
        let pairs = edges.map { ($0.srcId, $0.dstId) }
        let positions = ForceDirectedLayout.layout3D(nodeIDs: ids, edges: pairs, boundingRadius: 16.0)

        // 4. Render Edges (3D Lines)
        for edge in edges {
            guard let p1 = positions[edge.srcId], let p2 = positions[edge.dstId] else { continue }
            let lineNode = createLineNode(from: p1, to: p2)
            newScene.rootNode.addChildNode(lineNode)
        }

        // 5. Render Nodes (Spheres + Text)
        for node in nodes {
            guard let pos = positions[node.id] else { continue }
            let sphereNode = createSphereNode(for: node, position: pos)
            newScene.rootNode.addChildNode(sphereNode)
        }

        self.scene = newScene
    }

    private func createSphereNode(for node: MemoryClient.Node, position: SCNVector3) -> SCNNode {
        let salience = node.salience ?? 1.0
        let radius = CGFloat(0.4 + salience * 0.2)

        let sphere = SCNSphere(radius: radius)
        let material = SCNMaterial()
        material.diffuse.contents = colorForKind(node.kind)
        material.specular.contents = PlatformColor.white
        material.shininess = 0.8
        sphere.materials = [material]

        let nodeNode = SCNNode(geometry: sphere)
        nodeNode.position = position
        nodeNode.name = node.id

        // 3D Text Label
        let text = SCNText(string: node.label, extrusionDepth: 0.05)
        #if os(macOS)
        text.font = NSFont.systemFont(ofSize: 0.5, weight: .bold)
        #else
        text.font = UIFont.systemFont(ofSize: 0.5, weight: .bold)
        #endif
        text.firstMaterial?.diffuse.contents = PlatformColor.labelColor

        let textNode = SCNNode(geometry: text)
        textNode.scale = SCNVector3(0.6, 0.6, 0.6)

        #if os(macOS)
        typealias SCNFloat = CGFloat
        #else
        typealias SCNFloat = Float
        #endif

        let (minVec, maxVec) = textNode.boundingBox
        let dx = SCNFloat(maxVec.x - minVec.x) / 2.0
        let offset = SCNFloat(radius) + 0.3
        textNode.position = SCNVector3(position.x - dx * 0.6, position.y + offset, position.z)
        nodeNode.addChildNode(textNode)

        return nodeNode
    }

    private func createLineNode(from p1: SCNVector3, to p2: SCNVector3) -> SCNNode {
        let indices: [Int32] = [0, 1]
        let source = SCNGeometrySource(vertices: [p1, p2])
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let line = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = PlatformColor.secondaryLabelColor
        line.materials = [material]

        return SCNNode(geometry: line)
    }

    private func colorForKind(_ kind: String) -> PlatformColor {
        switch kind {
        case "person":       return .systemBlue
        case "place":        return .systemGreen
        case "fact":         return .systemOrange
        case "preference":   return .systemPink
        case "topic":        return .systemPurple
        case "trait":        return .systemTeal
        case "task":         return .systemRed
        case "plan":         return .systemBrown
        case "insight":      return .systemYellow
        case "day":          return .systemTeal
        case "episode":      return .systemIndigo
        default:             return .systemGray
        }
    }
}
