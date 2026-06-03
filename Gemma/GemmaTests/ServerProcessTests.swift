import XCTest
@testable import Gemma

final class ServerProcessTests: XCTestCase {
    /// 16 GiB — the "keep model resident" wired limit (see spec §2).
    private static let sixteenGiB: UInt64 = 17_179_869_184

    private func cfg(wired: UInt64 = 0, draft: Bool = false) -> ServerConfig {
        ServerConfig(pythonBinURL: URL(fileURLWithPath: "/x/.venv-vlm/bin/python3.12"),
                     launcherScriptURL: URL(fileURLWithPath: "/x/spike-mlx/serve_mlx_vlm.py"),
                     modelId: "some/model", host: "127.0.0.1", port: 8080,
                     draftModelId: draft ? "some/assistant" : nil,
                     draftKind: draft ? "mtp" : nil,
                     draftBlockSize: draft ? 3 : nil,
                     wiredLimitBytes: wired)
    }

    func test_serverArguments_baseShape_noDraft() {
        XCTAssertEqual(serverArguments(for: cfg()),
                       ["--model", "some/model", "--host", "0.0.0.0", "--port", "8080"])
    }

    func test_serverArguments_appendsDraftFlags_whenConfigured() {
        XCTAssertEqual(serverArguments(for: cfg(draft: true)),
                       ["--model", "some/model", "--host", "0.0.0.0", "--port", "8080",
                        "--draft-model", "some/assistant", "--draft-kind", "mtp", "--draft-block-size", "3"])
    }

    /// The server must bind all interfaces (`0.0.0.0`) so the remote Memory Service (i3) can
    /// reach the model for consolidation — but the app's own client URL must stay loopback
    /// (`127.0.0.1`), since connecting a client to `0.0.0.0` is not portable. Regression guard:
    /// binding to `127.0.0.1` silently breaks remote consolidation (model unreachable from LAN).
    func test_serverArguments_bindAllInterfaces_butClientStaysLoopback() {
        let c = cfg()
        XCTAssertEqual(serverArguments(for: c)[2...3].map { $0 }, ["--host", "0.0.0.0"],
                       "server must bind 0.0.0.0 so the i3 can reach it")
        XCTAssertEqual(c.baseURL.absoluteString, "http://127.0.0.1:8080",
                       "the app's client URL must stay loopback")
    }

    func test_wiringArguments_emptyWhenPageable() {
        XCTAssertEqual(wiringArguments(for: cfg(wired: 0)), [])
    }

    func test_wiringArguments_setsFlagWhenWired() {
        XCTAssertEqual(wiringArguments(for: cfg(wired: Self.sixteenGiB)),
                       ["--wired-limit-bytes", "17179869184"])
    }

    func test_launchArguments_pageable_scriptFirst_noWiringFlag() {
        let a = launchArguments(for: cfg(wired: 0, draft: true))
        XCTAssertEqual(a.first, "/x/spike-mlx/serve_mlx_vlm.py", "launcher script must be python's argv[1] (first arg after the interpreter)")
        XCTAssertFalse(a.contains("--wired-limit-bytes"))
        XCTAssertEqual(Array(a.suffix(12)),
                       ["--model", "some/model", "--host", "0.0.0.0", "--port", "8080",
                        "--draft-model", "some/assistant", "--draft-kind", "mtp", "--draft-block-size", "3"])
    }

    func test_launchArguments_wired_insertsFlagBetweenScriptAndServerArgs() {
        let a = launchArguments(for: cfg(wired: Self.sixteenGiB))
        XCTAssertEqual(Array(a.prefix(3)),
                       ["/x/spike-mlx/serve_mlx_vlm.py", "--wired-limit-bytes", "17179869184"])
        XCTAssertEqual(a[3], "--model")
    }

    func test_default_config_targets_launcher_and_python_pageable() {
        let c = ServerConfig.default
        XCTAssertTrue(c.pythonBinURL.path.hasSuffix("python3.12"), "default must run the venv python, got \(c.pythonBinURL.path)")
        XCTAssertTrue(c.launcherScriptURL.path.hasSuffix("serve_mlx_vlm.py"), "default must use the wiring launcher, got \(c.launcherScriptURL.path)")
        XCTAssertEqual(c.wiredLimitBytes, 0, "default must be pageable (toggle off)")
        XCTAssertEqual(c.draftKind, "mtp")
        XCTAssertNotNil(c.draftModelId)
        XCTAssertEqual(c.draftBlockSize, 2, "tuned: bs=2 measured ~+13-15% decode vs 3 (see docs/spikes/2026-06-02)")
    }

    func test_watchdogScript_contains_guardrails() {
        let c = cfg()
        let script = watchdogScript(binPath: c.pythonBinURL.path,
                                    args: launchArguments(for: c),
                                    parentPID: 4242)
        XCTAssertTrue(script.contains("/x/.venv-vlm/bin/python3.12"), "missing python path:\n\(script)")
        XCTAssertTrue(script.contains("serve_mlx_vlm.py"), "missing launcher:\n\(script)")
        XCTAssertTrue(script.contains("some/model"), "missing model id:\n\(script)")
        XCTAssertTrue(script.contains("trap"), "missing trap:\n\(script)")
        XCTAssertTrue(script.contains("kill -0 4242"), "missing parent-pid guard:\n\(script)")
        XCTAssertTrue(script.contains("sleep"), "missing sleep poll:\n\(script)")
    }
}
