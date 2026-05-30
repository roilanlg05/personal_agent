import Foundation

/// Parameter declaration for an AgentTool, used to build the JSON schema sent to the model.
public struct AgentToolParam {
    public enum ParamType: String { case string, integer, number, boolean }
    public let name: String
    public let type: ParamType
    public let description: String
    public let required: Bool

    public init(name: String, type: ParamType, description: String, required: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

/// A tool the agent can call. Replaces LiteRT-LM's `Tool`/`@ToolParam`: the model's chosen
/// arguments arrive as a JSON object string (from the OpenAI-style server), and the tool
/// parses what it needs. Tools read shared deps from `MemoryToolbox.shared` / emit via
/// `ToolActivityRelay.shared` (unchanged). Instances are created by the app (not the model).
public protocol AgentTool {
    static var name: String { get }
    static var description: String { get }
    static var parameters: [AgentToolParam] { get }
    func run(argsJSON: String) async -> String
}

extension AgentTool {
    public static var parameters: [AgentToolParam] { [] }

    /// OpenAI-style JSON Schema for this tool's parameters.
    public static var jsonSchema: [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in parameters {
            props[p.name] = ["type": p.type.rawValue, "description": p.description]
            if p.required { required.append(p.name) }
        }
        return ["type": "object", "properties": props, "required": required]
    }

    /// The full function spec for the OpenAI `tools` array.
    public static var functionSpec: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": jsonSchema]]
    }
}
