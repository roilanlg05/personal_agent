import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var isActive: Bool
    public var error: String?

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesDownloaded) / Double(totalBytes))
    }

    public init(bytesDownloaded: Int64 = 0, totalBytes: Int64 = 0, isActive: Bool = false, error: String? = nil) {
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.isActive = isActive
        self.error = error
    }
}
