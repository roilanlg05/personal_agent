import XCTest
@testable import Gemma

final class ServerProcessTests: XCTestCase {
    func test_serverArguments_baseShape_noDraft() {
        let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_vlm.server"),
                               modelId: "some/model", host: "127.0.0.1", port: 8080)
        XCTAssertEqual(serverArguments(for: cfg),
                       ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080"])
    }

    func test_serverArguments_appendsDraftFlags_whenConfigured() {
        let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_vlm.server"),
                               modelId: "some/model", host: "127.0.0.1", port: 8080,
                               draftModelId: "some/assistant", draftKind: "mtp", draftBlockSize: 3)
        XCTAssertEqual(serverArguments(for: cfg),
                       ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080",
                        "--draft-model", "some/assistant", "--draft-kind", "mtp", "--draft-block-size", "3"])
    }

    func test_default_config_targets_mlx_vlm_server_with_mtp_draft() {
        let c = ServerConfig.default
        XCTAssertTrue(c.venvBinURL.path.hasSuffix("mlx_vlm.server"), "default must launch mlx_vlm.server, got \(c.venvBinURL.path)")
        XCTAssertEqual(c.draftKind, "mtp")
        XCTAssertNotNil(c.draftModelId)
        XCTAssertEqual(c.draftBlockSize, 3)
    }

    func test_watchdogScript_contains_guardrails() {
        let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_vlm.server"),
                               modelId: "some/model", host: "127.0.0.1", port: 8080)
        let script = watchdogScript(binPath: cfg.venvBinURL.path,
                                    args: serverArguments(for: cfg),
                                    parentPID: 4242)
        XCTAssertTrue(script.contains("/x/mlx_vlm.server"), "missing bin path:\n\(script)")
        XCTAssertTrue(script.contains("some/model"), "missing model id:\n\(script)")
        XCTAssertTrue(script.contains("trap"), "missing trap:\n\(script)")
        XCTAssertTrue(script.contains("kill -0 4242"), "missing parent-pid guard:\n\(script)")
        XCTAssertTrue(script.contains("sleep"), "missing sleep poll:\n\(script)")
    }
}
