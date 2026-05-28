import Foundation

public struct DeviceCapability: Sendable, Equatable {
    public let totalRAMBytes: UInt64
    public let freeDiskBytes: UInt64

    public init(totalRAMBytes: UInt64, freeDiskBytes: UInt64) {
        self.totalRAMBytes = totalRAMBytes
        self.freeDiskBytes = freeDiskBytes
    }

    public static func current() -> DeviceCapability {
        DeviceCapability(
            totalRAMBytes: ProcessInfo.processInfo.physicalMemory,
            freeDiskBytes: freeDiskBytesAtHome()
        )
    }

    public enum FitDecision: Sendable, Equatable {
        case ok
        case insufficient(reasons: [FitReason])
    }

    public enum FitReason: Sendable, Equatable, Hashable {
        case insufficientRAM(requiredGB: Int, actualGB: Int)
        case insufficientDisk(requiredBytes: Int64, actualBytes: Int64)
    }

    public func fits(_ descriptor: ModelDescriptor) -> FitDecision {
        var reasons: [FitReason] = []
        let actualRAMGB = Int(totalRAMBytes / (1024 * 1024 * 1024))
        if actualRAMGB < descriptor.minDeviceMemoryGB {
            reasons.append(.insufficientRAM(
                requiredGB: descriptor.minDeviceMemoryGB,
                actualGB: actualRAMGB
            ))
        }
        // Demand at least 1.5× the model size in free disk to accommodate the
        // .partial download file plus the final atomic rename.
        let requiredDisk = Int64(Double(descriptor.sizeInBytes) * 1.5)
        if Int64(freeDiskBytes) < requiredDisk {
            reasons.append(.insufficientDisk(
                requiredBytes: requiredDisk,
                actualBytes: Int64(freeDiskBytes)
            ))
        }
        return reasons.isEmpty ? .ok : .insufficient(reasons: reasons)
    }

    private static func freeDiskBytesAtHome() -> UInt64 {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else {
            return 0
        }
        return free.uint64Value
    }
}
