import Foundation
import CoreGraphics
import CoreLocation

/// Builds the ND's terrain picture the way an EGPWS terrain display paints
/// it: colour bands set by height, each band a fine, regular dot pattern of
/// its own density, the dots small and of a fixed size on the screen,
/// whatever the range.
///
/// Two steps per picture:
/// 1. **Elevations** on a coarse grid of a few points a cell, from the
///    flight pack.
/// 2. **Dots**: the picture has one pixel per dot cell of the screen (about
///    a point square). Each pixel takes the height interpolated from the
///    grid, finds its band, and lights only if the band's pattern has a dot
///    there. So band edges run smoothly between grid nodes and the pattern
///    period is a pixel or two, never a grid cell. (Lighting whole grid
///    cells in a pattern, as before, turned the patterns into a chessboard
///    of cells several points across.)
///
/// The bands follow the published EGPWS terrain display (Honeywell MK V /
/// MK VII EGPWS Pilot Guide, 060-4241-000, "Terrain Alerting and Display";
/// the Airbus TAWS and 737NG displays use the same scheme), relative to a
/// reference altitude (the aircraft's, projected 30 s ahead when
/// descending at more than 1000 fpm):
///
/// | band                         | display           |
/// |------------------------------|-------------------|
/// | ≥ 2000 ft above              | red, 50 %         |
/// | 1000 to 2000 ft above        | yellow, 50 %      |
/// | 500 (250 gear down) below to 1000 above | yellow, 25 % |
/// | 1000 to 500 (250) below      | green, 50 %       |
/// | 2000 to 1000 below           | green, 16 %       |
/// | more than 2000 below         | black             |
/// | within 400 ft of the nearest runway's elevation | black |
/// | no data                      | magenta, 16 %     |
/// | sea level (no other band)    | cyan, 16 %        |
///
/// **Peaks**: when the aircraft is more than 500 ft (250 gear down) above
/// all terrain in view, so nothing is yellow or red, extra green bands are
/// laid over the range of elevations in view: solid green for the highest,
/// then 50 % and 16 %, black for the low ground. The band limits are our
/// own (fractions of the elevation span in view); the guide only says they
/// follow the highest and lowest terrain.
enum NDTerrainRenderer {

    /// What to draw: the picture covers ±`halfSideNm` around `center` in a
    /// square of `resolution` pixels, `upDeg` (true) at the top.
    struct Request: Sendable {
        var center: CLLocationCoordinate2D
        var upDeg: Double
        var halfSideNm: Double
        var resolution: Int
        /// The ND range: the area the readout and the Peaks bands consider.
        var viewRangeNm: Double
        /// The aircraft altitude the bands are measured from.
        var referenceAltitudeFt: Double
        var gearDown: Bool
        /// Elevation of the nearest runway; terrain within 400 ft of it is
        /// left black, so the airport's surroundings do not light up on
        /// approach.
        var runwayElevationFt: Double?
    }

    /// The colours the display paints in.
    enum Hue: Sendable { case red, amber, green, cyan, magenta }

    /// The elevation numbers the terrain display shows beside the picture:
    /// highest terrain in view and lowest terrain painted, in feet, each in
    /// the colour of its band. `lowestFt` is nil on flat ground.
    struct Readout: Equatable, Sendable {
        var highestFt: Double
        var highestHue: Hue
        var lowestFt: Double?
        var lowestHue: Hue
    }

    struct Picture {
        let image: CGImage
        let readout: Readout?
    }

    // MARK: Bands

    /// A band: its colour and its dot density.
    private enum Band: UInt8 {
        case none, red50, amber50, amber25, green50, green16, greenSolid, cyan16, magenta16

        var hue: Hue? {
            switch self {
            case .none: return nil
            case .red50: return .red
            case .amber50, .amber25: return .amber
            case .green50, .green16, .greenSolid: return .green
            case .cyan16: return .cyan
            case .magenta16: return .magenta
            }
        }

        /// Green bands, densest last, so Peaks can keep the denser one.
        var greenRank: Int {
            switch self {
            case .green16: return 1
            case .green50: return 2
            case .greenSolid: return 3
            default: return 0
            }
        }
    }

    private struct RGB { let r, g, b: UInt8 }

    private static func rgb(_ band: Band) -> RGB {
        switch band {
        case .none: return RGB(r: 0, g: 0, b: 0)
        case .red50: return RGB(r: 255, g: 38, b: 38)
        case .amber50, .amber25: return RGB(r: 255, g: 196, b: 0)
        case .green50, .green16: return RGB(r: 0, g: 214, b: 48)
        // Solid areas are large at cruise: a shade darker than the dots.
        case .greenSolid: return RGB(r: 0, g: 150, b: 36)
        case .cyan16: return RGB(r: 0, g: 186, b: 230)
        case .magenta16: return RGB(r: 236, g: 0, b: 236)
        }
    }

    /// Whether the band's pattern has a dot at pixel (`x`, `y`). Every
    /// pattern is a regular lattice: 50 % a checkerboard, 25 % every other
    /// pixel of every other row, 16 % one in six on an oblique lattice.
    private static func lit(_ band: Band, x: Int, y: Int) -> Bool {
        switch band {
        case .none: return false
        case .greenSolid: return true
        case .red50, .amber50, .green50: return (x + y) & 1 == 0
        case .amber25: return x & 1 == 0 && y & 1 == 0
        case .green16, .cyan16, .magenta16: return y & 1 == 0 && (x + y / 2) % 3 == 0
        }
    }

    /// The band limits for one picture.
    private struct Scheme {
        let referenceFt: Double
        /// 500 ft, 250 with the gear down.
        let lowerYellowFt: Double
        let runwayFt: Double?
        /// Peaks: the bottom of the elevation span in view and its height;
        /// nil when the standard bands apply alone.
        let peaks: (floorFt: Double, spanFt: Double)?

        func band(forFt ft: Double) -> Band {
            var band = Band.none
            let relative = ft - referenceFt
            switch relative {
            case 2_000...: band = .red50
            case 1_000..<2_000: band = .amber50
            case (-lowerYellowFt)..<1_000: band = .amber25
            case -1_000 ..< (-lowerYellowFt): band = .green50
            case -2_000 ..< -1_000: band = .green16
            default: break
            }
            if let peaks {
                let fraction = (ft - peaks.floorFt) / peaks.spanFt
                let peaksBand: Band = fraction >= 0.8 ? .greenSolid
                    : fraction >= 0.6 ? .green50 : fraction >= 0.4 ? .green16 : .none
                if peaksBand.greenRank > band.greenRank { band = peaksBand }
            }
            if let runwayFt, abs(ft - runwayFt) < 400 { band = .none }
            if band == .none, ft <= 0 { band = .cyan16 }      // sea level
            return band
        }
    }

    // MARK: Picture

    /// The picture for `request`, clear where there is no terrain to show.
    /// Safe to call off the main thread.
    static func picture(store: TerrainStore, _ request: Request) -> Picture? {
        let n = request.resolution
        guard n > 8, request.halfSideNm > 0 else { return nil }
        let half = request.halfSideNm

        // 1. Elevations at the nodes of a coarse grid, about 4 pixels a cell,
        // in display axes (x right, y down) turned to true north on a
        // flat-earth approximation that is plenty at ND ranges.
        let m = max(48, min(400, n / 2))
        let cellNm = 2 * half / Double(m)
        let nodes = m + 1
        let zoom = TerrainStore.zoom(forSpacingMeters: cellNm * 1_852, latitude: request.center.latitude)
        let up = request.upDeg * .pi / 180
        let sinUp = sin(up), cosUp = cos(up)
        let cosLat = max(0.05, cos(request.center.latitude * .pi / 180))
        var feet = [Double](repeating: .nan, count: nodes * nodes)
        var memo: [TileID: TerrainStore.Heights] = [:]
        var missing: Set<TileID> = []
        // In view: ahead of the aircraft, within the range.
        var inView: [Int] = []
        let rangeSquared = request.viewRangeNm * request.viewRangeNm

        for row in 0..<nodes {
            let dy = half - Double(row) * cellNm                 // NM up the display
            for column in 0..<nodes {
                let dx = Double(column) * cellNm - half          // NM right on the display
                guard dy > -0.45 * half, dx * dx + dy * dy <= half * half * 1.05 else { continue }
                let north = dy * cosUp - dx * sinUp
                let east = dy * sinUp + dx * cosUp
                let point = CLLocationCoordinate2D(latitude: request.center.latitude + north / 60,
                                                   longitude: request.center.longitude + east / (60 * cosLat))
                guard let meters = sample(store, at: point, maxZoom: zoom, memo: &memo, missing: &missing)
                else { continue }
                let index = row * nodes + column
                feet[index] = max(0, meters) * 3.28084
                if dy >= 0, dx * dx + dy * dy <= rangeSquared { inView.append(index) }
            }
        }
        guard !memo.isEmpty else { return nil }                  // no pack data anywhere near

        // 2. The scheme: Peaks bands when all terrain in view is well below.
        var highest = -Double.infinity, lowest = Double.infinity
        for index in inView {
            highest = max(highest, feet[index])
            lowest = min(lowest, feet[index])
        }
        let lowerYellow = request.gearDown ? 250.0 : 500.0
        var peaks: (floorFt: Double, spanFt: Double)?
        if highest.isFinite, highest < request.referenceAltitudeFt - lowerYellow, highest - lowest >= 500 {
            peaks = (lowest, highest - lowest)
        }
        let scheme = Scheme(referenceFt: request.referenceAltitudeFt, lowerYellowFt: lowerYellow,
                            runwayFt: request.runwayElevationFt, peaks: peaks)

        // 3. Dots.
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let gridPerPixel = Double(m) / Double(n)
        let halfPixels = Double(n) / 2
        let lastRow = min(n, Int(halfPixels * 1.4) + 1)          // a little behind the aircraft
        let radiusSquared = halfPixels * halfPixels
        feet.withUnsafeBufferPointer { grid in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 0..<lastRow {
                    let py = Double(y) + 0.5 - halfPixels
                    let gy = (Double(y) + 0.5) * gridPerPixel
                    let row0 = min(m - 1, Int(gy))
                    let fy = gy - Double(row0)
                    for x in 0..<n {
                        let px = Double(x) + 0.5 - halfPixels
                        guard px * px + py * py <= radiusSquared else { continue }
                        let gx = (Double(x) + 0.5) * gridPerPixel
                        let column0 = min(m - 1, Int(gx))
                        let fx = gx - Double(column0)
                        let i00 = row0 * nodes + column0
                        let a = grid[i00], b = grid[i00 + 1]
                        let c = grid[i00 + nodes], d = grid[i00 + nodes + 1]
                        let ft: Double
                        if a.isNaN || b.isNaN || c.isNaN || d.isNaN {
                            // At the edge of the data: the nearest node.
                            ft = fy < 0.5 ? (fx < 0.5 ? a : b) : (fx < 0.5 ? c : d)
                        } else {
                            ft = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                        }
                        let band = ft.isNaN ? Band.magenta16 : scheme.band(forFt: ft)
                        guard lit(band, x: x, y: y) else { continue }
                        let colour = rgb(band)
                        let i = (y * n + x) * 4
                        out[i] = colour.r
                        out[i + 1] = colour.g
                        out[i + 2] = colour.b
                        out[i + 3] = 255
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return nil }
        return Picture(image: image, readout: readout(feet: feet, inView: inView, scheme: scheme))
    }

    /// Highest terrain in view and lowest terrain painted, each with the
    /// colour of its band.
    private static func readout(feet: [Double], inView: [Int], scheme: Scheme) -> Readout? {
        var highest = -Double.infinity
        var lowestPainted = Double.infinity
        for index in inView {
            let ft = feet[index]
            highest = max(highest, ft)
            if ft < lowestPainted, let hue = scheme.band(forFt: ft).hue, hue != .cyan {
                lowestPainted = ft
            }
        }
        guard highest.isFinite else { return nil }
        let highestHue = scheme.band(forFt: highest).hue.flatMap { $0 == .cyan ? nil : $0 } ?? .green
        // On flat ground only the highest value shows.
        let lowest = lowestPainted.isFinite && highest - lowestPainted >= 200 ? lowestPainted : nil
        let lowestHue = lowest.flatMap { scheme.band(forFt: $0).hue } ?? .green
        return Readout(highestFt: highest, highestHue: highestHue, lowestFt: lowest, lowestHue: lowestHue)
    }

    /// An elevation as the terrain display writes it: hundreds of feet,
    /// three digits ("045" for 4500 ft).
    static func hundredsOfFeet(_ ft: Double) -> String {
        String(format: "%03d", max(0, Int((ft / 100).rounded())))
    }

    /// Height at a point, finest zoom on disk up to `maxZoom`, with tiles
    /// memoised for the duration of one picture.
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
}
