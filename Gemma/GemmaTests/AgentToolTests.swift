import XCTest
@testable import Gemma

final class AgentToolTests: XCTestCase {
    struct EchoTool: AgentTool {
        static let name = "echo"
        static let description = "Echoes the 'text' argument."
        static let parameters: [AgentToolParam] = [
            AgentToolParam(name: "text", type: .string, description: "what to echo", required: true)
        ]
        func run(argsJSON: String) async -> String {
            let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]
            return (obj?["text"] as? String) ?? "(none)"
        }
    }

    func testJSONSchema() {
        let schema = EchoTool.jsonSchema
        XCTAssertEqual(schema["type"] as? String, "object")
        let props = schema["properties"] as? [String: Any]
        XCTAssertNotNil(props?["text"])
        XCTAssertEqual((schema["required"] as? [String])?.first, "text")
    }

    func testRunParsesArgs() async {
        let out = await EchoTool().run(argsJSON: #"{"text":"hi"}"#)
        XCTAssertEqual(out, "hi")
    }
}
