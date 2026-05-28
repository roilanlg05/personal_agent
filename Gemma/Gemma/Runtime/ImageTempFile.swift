import Foundation
import UIKit

public enum ImageTempFile {
    public enum WriteError: Error, Equatable {
        case encodingFailed
    }

    /// Writes a UIImage to a unique temp .jpg path and returns the URL. Caller deletes when done.
    public static func writeJPEG(_ image: UIImage, quality: CGFloat = 0.9) throws -> URL {
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw WriteError.encodingFailed
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemma-img-\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }
}
