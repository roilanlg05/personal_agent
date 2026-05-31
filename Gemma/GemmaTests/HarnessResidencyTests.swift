import XCTest
@testable import Gemma

final class HarnessResidencyTests: XCTestCase {
    func test_wiredLimitBytes_pageableWhenOff() {
        XCTAssertEqual(HarnessModel.wiredLimitBytes(keepResident: false), 0)
    }

    func test_wiredLimitBytes_residentValueWhenOn() {
        XCTAssertEqual(HarnessModel.wiredLimitBytes(keepResident: true), HarnessModel.residentWiredLimitBytes)
    }

    func test_residentLimit_is_16GiB_underNoSudoCap() {
        // 16 GiB exactly; must stay under the measured no-sudo cap (17.76 GiB ≈ 19_069_665_280 B).
        XCTAssertEqual(HarnessModel.residentWiredLimitBytes, 17_179_869_184)
        XCTAssertLessThan(HarnessModel.residentWiredLimitBytes, 19_069_665_280)
    }
}
