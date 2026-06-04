import XCTest
@testable import Gemma

@MainActor
final class RuntimeFactoryTests: XCTestCase {
    func test_dummy_returnsDummyRuntime() async {
        let r = RuntimeFactory.dummy()
        XCTAssertEqual(r.identifier, "dummy")
    }

    func test_make_localProvider_returnsServerRuntime() async {
        let r = RuntimeFactory.make(ModelProvider(kind: .local))
        XCTAssertEqual(r.identifier, "mlx-server")
    }
}
