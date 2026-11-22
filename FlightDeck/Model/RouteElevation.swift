import Foundation
import CoreLocation

/// The height profile of the planned route: ground elevation sampled at even
/// intervals along the route geometry, from a digital elevation model. This is
/// what the vertical display plots ahead of the aircraft — the road's climbs
/// and descents — in place of the terrain database an airliner carries.
struct ElevationProfile {
    struct Sample {
        /// Distance from the start of the route.
        let alongMeters: Double
        let elevationFt: Double
    }

    /// Sorted by `alongMeters`.
    let samples: [Sample]

    /// Ground elevation at an along-route distance, linearly interpolated;
    /// clamped to the profile's ends.
    func elevationFt(atMeters meters: Double) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if meters <= first.alongMeters { return first.elevationFt }
        if meters >= last.alongMeters { return last.elevationFt }
        // Binary search for the sample just past `meters`.
        var low = 0, high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].alongMeters <= meters { low = mid } else { high = mid }
        }
        let a = samples[low], b = samples[high]
        let t = (meters - a.alongMeters) / max(b.alongMeters - a.alongMeters, 1e-6)
        return a.elevationFt + (b.elevationFt - a.elevationFt) * t
    }

    /// The profile from `fromMeters` out to `fromMeters + spanMeters` (or the
    /// end of the route), as distance ahead / elevation pairs. The first and
    /// last points are interpolated, so the strip always begins exactly at
    /// the aircraft and ends at the range edge.
    func ahead(fromMeters: Double, spanMeters: Double) -> [(distanceMeters: Double, elevationFt: Double)] {
        guard let last = samples.last, spanMeters > 0 else { return [] }
        let end = min(fromMeters + spanMeters, last.alongMeters)
        guard end > fromMeters, let start = elevationFt(atMeters: fromMeters),
              let finish = elevationFt(atMeters: end) else { return [] }

        var result: [(distanceMeters: Double, elevationFt: Double)] = [(0, start)]
        for sample in samples where sample.alongMeters > fromMeters && sample.alongMeters < end {
            result.append((sample.alongMeters - fromMeters, sample.elevationFt))
        }
        result.append((end - fromMeters, finish))
        return result
    }
}

/// Ground elevation for a route, from the same terrain tiles the flight
/// packs carry (AWS Open Data "Terrain Tiles", see ``TerrainStore``),
/// fetched as needed into ``TerrainStore/onDemand`` at z12 (~38 m pixels).
/// Tiles already cached are reused, so a route planned again — or driven
/// later without a connection — needs no download.
enum ElevationService {
    static let zoom = 12
    /// A long route is read at a coarser zoom rather than fetching more
    /// tiles than this.
    static let maximumTiles = 400

    /// Ground elevation in metres for each coordinate, in order; below sea
    /// level reads 0 (the tiles carry the sea floor).
    static func elevationsMeters(for coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        var zoom = Self.zoom
        var tiles = Set(coordinates.map { TileID.containing($0, zoom: zoom) })
        while tiles.count > maximumTiles, zoom > 8 {
            zoom -= 1
            tiles = Set(coordinates.map { TileID.containing($0, zoom: zoom) })
        }
        let store = TerrainStore.onDemand
        try await TerrainDownloader.download(tiles, into: store.directory) { _, _, _ in }
        try Task.checkCancellation()

        var missing = 0
        let heights = coordinates.map { coordinate -> Double in
            guard let meters = store.elevationMeters(at: coordinate, maxZoom: zoom) else {
                missing += 1
                return 0
            }
            return max(0, meters)
        }
        // A profile mostly made of gaps would mislead more than none at all.
        guard missing * 2 < coordinates.count else { throw URLError(.resourceUnavailable) }
        return heights
    }
}
