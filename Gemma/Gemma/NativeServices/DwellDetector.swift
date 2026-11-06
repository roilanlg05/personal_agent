import Foundation
import CoreLocation

public struct DwellEvent: Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let duration: TimeInterval
    public let timestamp: Date

    public init(coordinate: CLLocationCoordinate2D, duration: TimeInterval, timestamp: Date) {
        self.coordinate = coordinate
        self.duration = duration
        self.timestamp = timestamp
    }
}

public final class DwellDetector: @unchecked Sendable {
    public let dwellDurationThreshold: TimeInterval
    public let movementThresholdMeters: Double
    private let onDwell: @Sendable (DwellEvent) -> Void

    private var currentCenter: CLLocationCoordinate2D?
    private var firstSeenAt: Date?
    private var hasTriggered: Bool = false
    private let lock = NSLock()

    public init(
        dwellDurationThreshold: TimeInterval = 900.0,
        movementThresholdMeters: Double = 40.0,
        onDwell: @escaping @Sendable (DwellEvent) -> Void
    ) {
        self.dwellDurationThreshold = dwellDurationThreshold
        self.movementThresholdMeters = movementThresholdMeters
        self.onDwell = onDwell
    }

    public func recordPosition(coordinate: CLLocationCoordinate2D, timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        guard let center = currentCenter, let startTime = firstSeenAt else {
            currentCenter = coordinate
            firstSeenAt = timestamp
            hasTriggered = false
            return
        }

        let locA = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let locB = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distance = locA.distance(from: locB)

        if distance > movementThresholdMeters {
            // Usuario se movió a una nueva zona: resetear ventana y flag anti-spam
            currentCenter = coordinate
            firstSeenAt = timestamp
            hasTriggered = false
        } else {
            // Permanece en la misma zona
            let elapsed = timestamp.timeIntervalSince(startTime)
            if elapsed >= dwellDurationThreshold && !hasTriggered {
                hasTriggered = true
                let event = DwellEvent(coordinate: coordinate, duration: elapsed, timestamp: timestamp)
                onDwell(event)
            }
        }
    }
}
