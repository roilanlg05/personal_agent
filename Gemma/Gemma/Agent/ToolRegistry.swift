import Foundation
import LiteRTLM

/// Extensible registry of LiteRT-LM tools (CC2: "we'll keep adding capabilities").
/// S6 registers the real iOS tools here. The held instances are used for schema generation;
/// LiteRT-LM's ToolManager instantiates fresh copies per call.
@MainActor
final class ToolRegistry {
    private(set) var tools: [Tool] = []

    init() {}

    func register(_ tool: Tool) { tools.append(tool) }

    /// The default tool set for the first slice.
    static func withDefaults() -> ToolRegistry {
        let r = ToolRegistry()
        r.register(CurrentTimeTool())
        return r
    }
}
