import Foundation
import CoreLocation

public enum SpatialResolutionResult {
    case certain(place: KnownPlace, distanceMeters: Double)
    case ambiguous(candidates: [(place: KnownPlace, distanceMeters: Double)])
    case unknown(coordinate: CLLocationCoordinate2D, nearestPlace: (KnownPlace, Double)?)
}

public final class SpatialResolver: Sendable {
    private let placeStore: PlaceStore

    public init(placeStore: PlaceStore) {
        self.placeStore = placeStore
    }

    public func resolve(
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracy: Double = 10.0
    ) -> SpatialResolutionResult {
        let places = placeStore.list()
        let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var scoredPlaces: [(place: KnownPlace, distance: Double)] = []

        for p in places {
            let placeLoc = CLLocation(latitude: p.latitude, longitude: p.longitude)
            let distance = userLocation.distance(from: placeLoc)
            scoredPlaces.append((place: p, distance: distance))
        }

        scoredPlaces.sort { $0.distance < $1.distance }

        // Filtrar candidatos dentro del radio de incertidumbre + margen de error GPS
        let matchingCandidates = scoredPlaces.filter { item in
            let allowedDistance = item.place.uncertaintyRadiusMeters + max(horizontalAccuracy, 5.0)
            return item.distance <= allowedDistance
        }

        if matchingCandidates.isEmpty {
            let nearest = scoredPlaces.first
            return .unknown(coordinate: coordinate, nearestPlace: nearest)
        } else if matchingCandidates.count == 1 {
            let only = matchingCandidates[0]
            return .certain(place: only.place, distanceMeters: only.distance)
        } else {
            // Múltiples candidatos dentro del radio de tolerancia
            let first = matchingCandidates[0]
            let second = matchingCandidates[1]
            // Si el primero está a menos de 5m y el segundo a más de 30m, es prácticamente seguro
            if first.distance < 5.0 && second.distance > 30.0 {
                return .certain(place: first.place, distanceMeters: first.distance)
            }
            let labeled = matchingCandidates.map { (place: $0.place, distanceMeters: $0.distance) }
            return .ambiguous(candidates: labeled)
        }
    }
}
