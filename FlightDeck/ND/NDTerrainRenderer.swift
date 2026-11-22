import Foundation
import CoreGraphics
import CoreLocation

/// Builds the ND's terrain picture: a small square image of coloured cells
/// around the aircraft, rotated to the display's up direction, in the style
/// of an airliner's terrain awareness display.
///
/// Two modes, chosen per image:
/// - **Relative** (terrain within 2000 ft below the aircraft, or higher):
///   red at 2000 ft or more above it, yellow from 500 ft below to 2000 ft
///   above (dense from 1000 ft above), green below that in two densities,
///   nothing more than 2000 ft below.
/// - **Peaks** (everything well below, as at cruise): the upper half of the
///   terrain in the picture in dotted dark green, denser for the highest
///   quarter, and the sea in sparse dark cyan, so coastlines and mountain
///   ranges stay readable from altitude without hiding the route.
///
/// Densities are dot patterns, as on the real displays. Cells without data
/// are left clear.
enum NDTerrainRenderer {

    private struct RGBA { let r, g, b: UInt8 }
    private static let red = RGBA(r: 255, g: 30, b: 30)
    private static let yellow = RGBA(r: 255, g: 210, b: 0)
    private static let green = RGBA(r: 0, g: 200, b: 40)
    private static let sea = RGBA(r: 0, g: 80, b: 110)
    /// Peaks mode is background information at cruise: a darker green, so
    /// the route and the symbols drawn over it stay clear.
    private static let peaksGreen = RGBA(r: 0, g: 140, b: 30)

    /// How much of a cell a density fills: solid, dense (3 of 4) or
    /// sparse (1 of 2, chequered), or nothing.
    private enum Density { case none, sparse, dense, solid }

    /// A square image `resolution` pixels a side covering ±`rangeNm` around
    /// `center`, rotated so `upDeg` (true) points to the top. Clear where
    /// there is no data. Safe to call off the main thread.
    static func image(store: TerrainStore, center: CLLocationCoordinate2D, upDeg: Double,
                      rangeNm: Double, aircraftAltitudeFt: Double, resolution: Int) -> CGImage? {
        guard resolution > 1, rangeNm > 0 else { return nil }
        let n = resolution
        let cellNm = 2 * rangeNm / Double(n)
        let zoom = TerrainStore.zoom(forSpacingMeters: cellNm * 1_852, latitude: center.latitude)

        // Sample the grid: metres, NaN where there is no data. The cells are
        // laid out in display axes (x right, y down) and turned to true north
        // here, on a flat-earth approximation that is plenty at ND ranges.
        let up = upDeg * .pi / 180
        let sinUp = sin(up), cosUp = cos(up)
        let cosLat = max(0.05, cos(center.latitude * .pi / 180))
        var heights = [Double](repeating: .nan, count: n * n)
        var highest = -Double.infinity, lowestLand = Double.infinity
        var memo: [TileID: TerrainStore.Heights] = [:]
        var missing: Set<TileID> = []

        for row in 0..<n {
            let dy = rangeNm - (Double(row) + 0.5) * cellNm          // NM up the display
            for column in 0..<n {
                let dx = (Double(column) + 0.5) * cellNm - rangeNm   // NM right on the display
                let north = dy * cosUp - dx * sinUp
                let east = dy * sinUp + dx * cosUp
                let point = CLLocationCoordinate2D(latitude: center.latitude + north / 60,
                                                   longitude: center.longitude + east / (60 * cosLat))
                guard let meters = sample(store, at: point, maxZoom: zoom, memo: &memo, missing: &missing)
                else { continue }
                heights[row * n + column] = meters
                if meters > highest { highest = meters }
                if meters > 0, meters < lowestLand { lowestLand = meters }
            }
        }
        guard highest.isFinite else { return nil }

        let aircraftMeters = aircraftAltitudeFt / 3.28084
        let relativeMode = highest >= aircraftMeters - 2_000 / 3.28084
        let floor = lowestLand.isFinite ? lowestLand : 0
        let span = max(highest - floor, 150)

        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for row in 0..<n {
            for column in 0..<n {
                let meters = heights[row * n + column]
                guard !meters.isNaN else { continue }
                let (color, density) = relativeMode
                    ? relativeColour(meters: meters, aircraftMeters: aircraftMeters)
                    : peaksColour(meters: meters, floor: floor, span: span)
                guard let color, fills(density, row: row, column: column) else { continue }
                let i = (row * n + column) * 4
                pixels[i] = color.r
                pixels[i + 1] = color.g
                pixels[i + 2] = color.b
                pixels[i + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Height at a point, finest zoom on disk up to `maxZoom`, with tiles
    /// memoised for the duration of one image.
    private static func sample(_ store: TerrainStore, at point: CLLocationCoordinate2D, maxZoom: Int,
                               memo: inout [TileID: TerrainStore.Heights],
                               missing: inout Set<TileID>) -> Double? {
        for zoom in TerrainStore.zoomOrder(maxZoom: maxZoom) {
            let tile = TileID.containing(point, zoom: zoom)
            if missing.contains(tile) { continue }
            if let heights = memo[tile] ?? store.heights(for: tile) {
                memo[tile] = heights
                return TerrainStore.sample(heights, tile: tile, at: point)
            }
            missing.insert(tile)
        }
        return nil
    }

    private static func relativeColour(meters: Double, aircraftMeters: Double) -> (RGBA?, Density) {
        guard meters > 0 else { return (nil, .none) }              // water and sea floor
        let relativeFt = (meters - aircraftMeters) * 3.28084
        switch relativeFt {
        case 2_000...: return (red, .dense)
        case 1_000..<2_000: return (yellow, .dense)
        case -500..<1_000: return (yellow, .sparse)
        case -1_000 ..< -500: return (green, .dense)
        case -2_000 ..< -1_000: return (green, .sparse)
        default: return (nil, .none)
        }
    }

    private static func peaksColour(meters: Double, floor: Double, span: Double) -> (RGBA?, Density) {
        guard meters > 0 else { return (sea, .sparse) }
        // Only the upper half of the terrain in view is drawn, as dots: the
        // ridges and high ground stand out, the lowlands stay black.
        let fraction = (meters - floor) / span
        switch fraction {
        case 0.75...: return (peaksGreen, .dense)
        case 0.5..<0.75: return (peaksGreen, .sparse)
        default: return (nil, .none)
        }
    }

    private static func fills(_ density: Density, row: Int, column: Int) -> Bool {
        switch density {
        case .none: return false
        case .solid: return true
        case .dense: return !(row % 2 == 1 && column % 2 == 1)
        case .sparse: return (row + column) % 2 == 0
        }
    }
}
