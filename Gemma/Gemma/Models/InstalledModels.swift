import Foundation

public struct InstalledModels: Sendable {
    public enum Status: Sendable, Equatable {
        case notInstalled
        case installed(at: URL)
        case corrupted(actualSize: Int64, expectedSize: Int64)
    }

    public let rootDir: URL
    private let fileManager: FileManager

    public init(rootDir: URL, fileManager: FileManager = .default) {
        self.rootDir = rootDir
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    /// `Documents/Models/` for the running app. Used in production.
    public static func defaultInDocuments() -> InstalledModels {
        let docs = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return InstalledModels(rootDir: docs.appendingPathComponent("Models", isDirectory: true))
    }

    public func fileURL(for descriptor: ModelDescriptor) -> URL {
        rootDir.appendingPathComponent(descriptor.modelFile)
    }

    public func status(of descriptor: ModelDescriptor) -> Status {
        let url = fileURL(for: descriptor)
        guard fileManager.fileExists(atPath: url.path) else { return .notInstalled }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return .corrupted(actualSize: 0, expectedSize: descriptor.sizeInBytes)
        }
        let actual = size.int64Value
        if actual == descriptor.sizeInBytes {
            return .installed(at: url)
        } else {
            return .corrupted(actualSize: actual, expectedSize: descriptor.sizeInBytes)
        }
    }

    /// Size in bytes of a leftover `<modelFile>.partial` from an interrupted
    /// download, or nil if none. status() ignores partials, so this is the only
    /// way to see the disk they occupy.
    public func partialSize(for descriptor: ModelDescriptor) -> Int64? {
        let partialURL = fileURL(for: descriptor).appendingPathExtension("partial")
        guard fileManager.fileExists(atPath: partialURL.path),
              let attrs = try? fileManager.attributesOfItem(atPath: partialURL.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    public func remove(_ descriptor: ModelDescriptor) throws {
        let url = fileURL(for: descriptor)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        // Also reclaim any leftover `.partial` from an interrupted download; it can
        // be multiple GB and is invisible to status()/allInstalled().
        let partialURL = url.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
    }

    public func allInstalled(from catalog: [ModelDescriptor]) -> [ModelDescriptor] {
        catalog.filter {
            if case .installed = status(of: $0) { return true } else { return false }
        }
    }
}
