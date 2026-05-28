import Foundation

public actor ModelDownloader {
    private let session: URLSession
    private let destinationDir: URL
    private let fileManager: FileManager

    public init(
        session: URLSession = .shared,
        destinationDir: URL,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.destinationDir = destinationDir
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
    }

    /// Streams progress events until the file is fully downloaded or an error is thrown.
    /// Resumes from an existing `<filename>.partial` if present.
    public nonisolated func download(from url: URL, filename: String) -> AsyncThrowingStream<DownloadEvent, Error> {
        let finalURL = destinationDir.appendingPathComponent(filename)
        let partialURL = destinationDir.appendingPathComponent(filename + ".partial")
        let session = self.session
        let fm = self.fileManager

        return AsyncThrowingStream { continuation in
            let task = Task {
                let existingBytes = Self.fileSize(at: partialURL, fileManager: fm)
                var request = URLRequest(url: url)
                if existingBytes > 0 {
                    request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
                }

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: DownloadError.unexpectedResponse)
                        return
                    }
                    guard http.statusCode == 200 || http.statusCode == 206 else {
                        continuation.finish(throwing: DownloadError.httpError(statusCode: http.statusCode))
                        return
                    }

                    let contentLength = http.expectedContentLength
                    // Only resume when the server honored Range with 206. A 200 means
                    // it's sending the whole file, so any existing partial is stale and
                    // must be overwritten — appending would corrupt and bloat the file.
                    let resuming = existingBytes > 0 && http.statusCode == 206
                    let totalBytes: Int64 = resuming ? existingBytes + contentLength : contentLength

                    if !fm.fileExists(atPath: partialURL.path) {
                        fm.createFile(atPath: partialURL.path, contents: nil)
                    }
                    let handle = try FileHandle(forWritingTo: partialURL)
                    if resuming {
                        try handle.seekToEnd()
                    } else {
                        try handle.truncate(atOffset: 0)
                    }

                    var downloaded: Int64 = resuming ? existingBytes : 0
                    var buffer = Data()
                    buffer.reserveCapacity(64 * 1024)
                    let flushThreshold = 64 * 1024
                    var lastReport: Date = .distantPast

                    for try await byte in bytes {
                        if Task.isCancelled {
                            try? handle.close()
                            continuation.finish(throwing: DownloadError.cancelled)
                            return
                        }
                        buffer.append(byte)
                        if buffer.count >= flushThreshold {
                            try handle.write(contentsOf: buffer)
                            downloaded += Int64(buffer.count)
                            buffer.removeAll(keepingCapacity: true)
                            // throttle progress events
                            let now = Date()
                            if now.timeIntervalSince(lastReport) > 0.1 {
                                continuation.yield(.progress(bytesDownloaded: downloaded, totalBytes: totalBytes))
                                lastReport = now
                            }
                        }
                    }
                    if !buffer.isEmpty {
                        try handle.write(contentsOf: buffer)
                        downloaded += Int64(buffer.count)
                    }
                    try handle.close()

                    // Atomic rename
                    if fm.fileExists(atPath: finalURL.path) {
                        try fm.removeItem(at: finalURL)
                    }
                    try fm.moveItem(at: partialURL, to: finalURL)

                    continuation.yield(.progress(bytesDownloaded: downloaded, totalBytes: totalBytes))
                    continuation.yield(.completed(finalURL))
                    continuation.finish()
                } catch let urlErr as URLError where urlErr.code == .cancelled {
                    continuation.finish(throwing: DownloadError.cancelled)
                } catch let dlErr as DownloadError {
                    continuation.finish(throwing: dlErr)
                } catch {
                    continuation.finish(throwing: DownloadError.io("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
}
