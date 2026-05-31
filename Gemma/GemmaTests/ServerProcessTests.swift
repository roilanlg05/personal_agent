import XCTest
@testable import Gemma

final class ServerProcessTests: XCTestCase {
    func test_serverArguments_shape() {
        let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_lm.server"),
                               modelId: "some/model", host: "127.0.0.1", port: 8080)
        XCTAssertEqual(serverArguments(for: cfg),
                       ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080"])
    }
}
