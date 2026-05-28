import XCTest
import UIKit
@testable import Gemma

final class ImageTempFileTests: XCTestCase {
    func test_write_producesReadableJPEG() throws {
        let img = UIImage(named: "bench-image-1")!
        let url = try ImageTempFile.writeJPEG(img)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "jpg")
        // file is a valid JPEG: starts with FFD8
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 2)!
        XCTAssertEqual(head[0], 0xFF)
        XCTAssertEqual(head[1], 0xD8)
    }

    func test_write_nilDataThrows() {
        // Build a UIImage with no underlying data — using a 0x0 size produces nil jpegData.
        let blank = UIGraphicsImageRenderer(size: .zero).image { _ in }
        XCTAssertThrowsError(try ImageTempFile.writeJPEG(blank))
    }
}
