import Foundation
import CoreLocation

public struct KnownPlace: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var uncertaintyRadiusMeters: Double
    public var visitCount: Int
    public var lastVisitedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        latitude: Double,
        longitude: Double,
        uncertaintyRadiusMeters: Double = 25.0,
        visitCount: Int = 1,
        lastVisitedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.uncertaintyRadiusMeters = uncertaintyRadiusMeters
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
