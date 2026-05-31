import XCTest
@testable import Gemma

final class ServerProcessTests: XCTestCase {
    func test_serverArguments_shape() {
        let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_lm.server"),
                               modelId: "some/model", host: "127.0.0.1", port: 8080)
        XCTAssertEqual(serverArguments(for: cfg),
                       ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080"])
    }

    func test_watchdogScript_contains_guardrails() {
        let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_lm.server"),
                               modelId: "some/model", host: "127.0.0.1", port: 8080)
        let script = watchdogScript(binPath: cfg.venvBinURL.path,
                                    args: serverArguments(for: cfg),
                                    parentPID: 4242)
        XCTAssertTrue(script.contains("/x/mlx_lm.server"), "missing bin path:\n\(script)")
        XCTAssertTrue(script.contains("some/model"), "missing model id:\n\(script)")
        XCTAssertTrue(script.contains("trap"), "missing trap:\n\(script)")
        XCTAssertTrue(script.contains("kill -0 4242"), "missing parent-pid guard:\n\(script)")
        XCTAssertTrue(script.contains("sleep"), "missing sleep poll:\n\(script)")
    }
}
