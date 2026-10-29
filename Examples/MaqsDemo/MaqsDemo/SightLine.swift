import CoreLocation
import Foundation
import MaqsData
import MaqsTerrain
import MaqsUI
import SwiftUI
import UIKit

/// A great-circle line from an observer along a bearing: which stretches of ground the observer sees, and the places
/// near the line with whether each can be seen. The maths here is the app's; the package gives the profile, the places
/// and the line-of-sight answers.
struct SightLine {
    /// How far the line reaches, in metres.
    static let length = 30_000.0
    /// How far either side of the line a place may lie, in degrees.
    static let halfAngle = 3.0
    /// The most places shown, the most notable first.
    static let placeLimit = 15
    /// The observer's eye above the ground, in metres.
    static let eyeHeight = 1.7

    /// One sample of the profile, for the chart.
    struct Sample: Identifiable {
        let id: Int
        /// Metres from the observer.
        let distance: Double
        /// Metres above sea level.
        let elevation: Double
        /// Whether the observer sees the ground here.
        let inSight: Bool
        /// The run of samples with the same `inSight` this one belongs to, so the chart draws each run on its own.
        let stretch: Int
    }

    /// A place near the line and whether the observer can see it.
    struct Sight: Identifiable {
        let found: PlaceInCone
        let visible: Bool
        var id: String { "place-\(found.place.region)-\(found.place.featureID)" }
    }

    let origin: CLLocationCoordinate2D
    let bearing: Double
    let samples: [Sample]
    let sights: [Sight]
    /// The line's coordinates split where the ground goes in or out of sight; neighbouring stretches share a point.
    private let stretches: [(coordinates: [CLLocationCoordinate2D], inSight: Bool)]

    /// Samples the terrain along the line, finds the places near it and asks which of them the observer sees.
    static func compute(from origin: CLLocationCoordinate2D, bearing: Double, terrain: Terrain,
                        places: Places) async throws -> SightLine {
        let end = destination(from: origin, bearing: bearing, distance: length)
        let profile = try await terrain.profile(from: origin, to: end)
        try Task.checkCancellation()
        let cone = try BearingCone(origin: origin, bearing: bearing, halfAngle: halfAngle, maxDistance: length)
        let found = try await places.places(in: cone, limit: placeLimit)
        let targets = found.map { SightTarget(coordinate: $0.place.coordinate, elevation: $0.place.elevation) }
        let observer = Observer(coordinate: origin, height: .aboveGround(eyeHeight))
        let looks = try await terrain.visibility(of: targets, from: observer)
        try Task.checkCancellation()
        let sights = zip(found, looks).map { place, look in
            if case .visible = look { Sight(found: place, visible: true) } else { Sight(found: place, visible: false) }
        }
        return SightLine(origin: origin, bearing: bearing, profile: profile, sights: sights)
    }

    private init(origin: CLLocationCoordinate2D, bearing: Double, profile: ElevationProfile, sights: [Sight]) {
        self.origin = origin
        self.bearing = bearing
        self.sights = sights
        let inSight = Self.inSight(profile)
        var samples: [Sample] = []
        var stretches: [(coordinates: [CLLocationCoordinate2D], inSight: Bool)] = []
        for (index, point) in profile.points.enumerated() {
            let seen = inSight[index]
            if let last = stretches.indices.last, stretches[last].inSight == seen {
                stretches[last].coordinates.append(point.coordinate)
            } else {
                // The new stretch starts where the last one ends, so the line has no gap.
                let joint = stretches.last?.coordinates.last.map { [$0] } ?? []
                stretches.append((joint + [point.coordinate], seen))
            }
            if case .elevation(let metres) = point.ground {
                samples.append(Sample(id: index, distance: point.distance, elevation: metres, inSight: seen,
                                      stretch: stretches.count - 1))
            }
        }
        self.samples = samples
        self.stretches = stretches
    }

    /// For each profile point, whether the observer's eye sees the ground there: no nearer ground rises above the line
    /// from the eye to it by more than the margin `MaqsTerrain`'s line of sight uses, so a metre of terrain noise next
    /// to the eye does not hide the view. The profile's apparent elevations already include the Earth's curvature and
    /// refraction. A point with no elevation counts as out of sight, and so does the whole line when the observer's own
    /// ground is missing.
    private static func inSight(_ profile: ElevationProfile) -> [Bool] {
        guard case .elevation(let ground)? = profile.points.first?.ground else {
            return profile.points.map { _ in false }
        }
        let eye = ground + eyeHeight
        let margin = VisibilityOptions().margin
        // The steepest slope from the eye that nearer ground, lowered by the margin, reaches.
        var steepest = -Double.infinity
        return profile.points.map { point in
            guard point.distance > 0 else { return true }
            guard let apparent = point.apparentElevation else { return false }
            defer { steepest = max(steepest, (apparent - margin - eye) / point.distance) }
            return (apparent - eye) / point.distance >= steepest
        }
    }

    /// The point `distance` metres from `start` along the great circle that leaves it at `bearing` degrees.
    static func destination(from start: CLLocationCoordinate2D, bearing: Double,
                            distance: Double) -> CLLocationCoordinate2D {
        let radius = 6_371_008.8
        let angle = distance / radius
        let heading = bearing * .pi / 180
        let latitude = start.latitude * .pi / 180
        let longitude = start.longitude * .pi / 180
        let endLatitude = asin(sin(latitude) * cos(angle) + cos(latitude) * sin(angle) * cos(heading))
        let endLongitude = longitude + atan2(sin(heading) * sin(angle) * cos(latitude),
                                             cos(angle) - sin(latitude) * sin(endLatitude))
        let degrees = endLongitude * 180 / .pi
        return CLLocationCoordinate2D(latitude: endLatitude * 180 / .pi,
                                      longitude: (degrees + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    // MARK: On the map

    /// The stretches in sight as solid lines, those out of sight as hidden ones.
    var mapLines: [MapLine] {
        stretches.enumerated().map { index, stretch in
            MapLine(id: "sight-\(index)", coordinates: stretch.coordinates, style: stretch.inSight ? .solid : .hidden)
        }
    }

    /// The observer as a dot, and each place as a marker with its pictogram, muted when it cannot be seen.
    var mapMarkers: [MapMarker] {
        let observer = MapMarker(id: "observer", coordinate: origin, content: .dot)
        return [observer] + sights.map { sight in
            let place = sight.found.place
            return MapMarker(id: sight.id, coordinate: place.coordinate, content: Self.content(for: place.kind),
                             label: place.name, isHidden: !sight.visible)
        }
    }

    private static func content(for kind: PlaceKind) -> MarkerContent {
        let symbol = switch kind {
        case .peak, .volcano: "mountain.2.fill"
        case .saddle, .pass: "arrow.left.and.right"
        case .alpineHut, .wildernessHut, .shelter: "house.fill"
        case .village, .hamlet, .isolatedDwelling: "building.2.fill"
        case .other: "mappin"
        }
        // A symbol image draws as it is given, so it is tinted white for the brown disc.
        guard let image = UIImage(systemName: symbol)?.withTintColor(.white, renderingMode: .alwaysOriginal) else {
            return .dot
        }
        return .symbol(image, fill: .brown)
    }
}
