import Foundation

public enum DownloadEvent: Sendable {
    /// Bytes transferred so far / total bytes (total may be 0 if server didn't send Content-Length).
    case progress(bytesDownloaded: Int64, totalBytes: Int64)
    /// Final file URL on disk. Always the last event on success.
    case completed(URL)
    /// Stream finishes with `throw error` if cancelled or failed.
}

public enum DownloadError: Error, Sendable, Equatable {
    case cancelled
    case httpError(statusCode: Int)
    case unexpectedResponse
    case insufficientDisk
    case io(String)
}
