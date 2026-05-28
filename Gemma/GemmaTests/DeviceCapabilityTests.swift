import XCTest
@testable import Gemma

final class DeviceCapabilityTests: XCTestCase {
    func test_current_reportsNonZeroRAMandDisk() {
        let cap = DeviceCapability.current()
        XCTAssertGreaterThan(cap.totalRAMBytes, 0)
        XCTAssertGreaterThan(cap.freeDiskBytes, 0)
    }

    func test_fits_acceptsModelWhenRAMAndDiskAreSufficient() {
        let cap = DeviceCapability(
            totalRAMBytes: UInt64(16) * 1024 * 1024 * 1024,
            freeDiskBytes: UInt64(50) * 1024 * 1024 * 1024
        )
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        let decision = cap.fits(desc)
        switch decision {
        case .ok: break
        case .insufficient(let reasons):
            XCTFail("Expected .ok, got insufficient: \(reasons)")
        }
    }

    func test_fits_rejectsForInsufficientRAM() {
        let cap = DeviceCapability(
            totalRAMBytes: UInt64(4) * 1024 * 1024 * 1024,
            freeDiskBytes: UInt64(50) * 1024 * 1024 * 1024
        )
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        guard case .insufficient(let reasons) = cap.fits(desc) else {
            return XCTFail("Expected .insufficient")
        }
        XCTAssertTrue(reasons.contains(.insufficientRAM(requiredGB: 8, actualGB: 4)))
    }

    func test_fits_rejectsForInsufficientDisk() {
        let cap = DeviceCapability(
            totalRAMBytes: UInt64(16) * 1024 * 1024 * 1024,
            freeDiskBytes: UInt64(2) * 1024 * 1024 * 1024
        )
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        guard case .insufficient(let reasons) = cap.fits(desc) else {
            return XCTFail("Expected .insufficient")
        }
        XCTAssertTrue(reasons.contains(where: {
            if case .insufficientDisk = $0 { return true } else { return false }
        }))
    }
}
