import CoreLocation
import Foundation
import MaqsCore

/// Picks the catalog region the app can offer to download for the map's centre.
enum RegionOffer {
    /// The smallest not-installed region whose box contains `centre`, or `nil`.
    ///
    /// `nil` too when any installed region (installed, update available or partially installed) covers the centre,
    /// when the centre is not a valid coordinate, or when every candidate is queued or downloading. Only regions
    /// are offered, never base packs, and an update is not an offer.
    static func region(
        at centre: CLLocationCoordinate2D, catalog: Catalog?, packs: [PackID: PackState]
    ) -> PackSummary? {
        guard let catalog, centre.latitude.isFinite, centre.longitude.isFinite,
            (-90...90).contains(centre.latitude), (-180...180).contains(centre.longitude)
        else { return nil }
        func covers(_ region: PackSummary) -> Bool {
            region.bbox?.contains(longitude: centre.longitude, latitude: centre.latitude) ?? false
        }
        let here = catalog.regions.filter(covers)
        for region in here {
            switch region.status {
            case .installed, .updateAvailable, .partiallyInstalled: return nil
            case .notInstalled: break
            }
        }
        return here
            .filter { region in
                guard case .notInstalled = region.status else { return false }
                switch packs[region.id] {
                case .queued, .downloading, .verifying: return false
                default: return true
                }
            }
            .min { area($0) < area($1) }
    }

    private static func area(_ region: PackSummary) -> Double {
        guard let box = region.bbox else { return .infinity }
        return (box.maxLon - box.minLon) * (box.maxLat - box.minLat)
    }
}
