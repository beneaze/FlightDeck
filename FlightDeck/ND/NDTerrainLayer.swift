import SwiftUI
import CoreLocation

/// The ND's terrain picture in plane mode, painted the way the real displays
/// paint it: each new picture sweeps in from the aircraft's heading line
/// outward to both sides, replacing the previous one only where the sweep
/// has passed. Terrain sweeps from the centre out so it is never mistaken
/// for weather radar, whose returns sweep from side to side.
///
/// The pictures themselves are rendered off the main thread: the next one
/// is prepared while the current sweep runs, so a new sweep starts as soon
/// as the last one ends. Each picture is drawn at the position and
/// orientation it was rendered for, so terrain stays put on the map as the
/// map moves and turns between pictures.
@MainActor
final class NDTerrainLayer: ObservableObject {
    struct Snapshot {
        let image: CGImage
        let center: CLLocationCoordinate2D
        let upDeg: Double
        /// Half the side of the picture, in NM.
        let halfSideNm: Double
        /// The ND range it was rendered for.
        let rangeNm: Double
        let readout: NDTerrainRenderer.Readout?
    }

    /// One sweep, centre to both edges.
    static let sweepDuration: TimeInterval = 4

    /// The side of one dot cell on the screen, in points: the dot patterns
    /// keep this size at every range. Rounded to whole device pixels.
    static let dotCellPoints: CGFloat = 1

    /// The fully painted picture.
    private var painted: Snapshot?
    /// The picture being swept in, and when its sweep began.
    private var sweeping: (snapshot: Snapshot, start: Date)?
    /// A rendered picture waiting for the current sweep to finish.
    private var pending: Snapshot?
    private var isRendering = false
    private var rangeNm: Double?
    /// Screen size of the map, learned when drawing: screen points per NM
    /// at the current range, and the device's pixels per point. The
    /// pictures are rendered at one pixel per dot cell of the screen.
    private var screenPointsPerNm: CGFloat?
    private var displayScale: CGFloat = 3
    /// Bumped whenever a picture is replaced, so the ND redraws.
    @Published private(set) var revision = 0

    /// The elevation numbers of the picture on the display.
    var readout: NDTerrainRenderer.Readout? { (sweeping?.snapshot ?? painted)?.readout }

    /// Call on every position update: advances the sweep and keeps the next
    /// picture coming. A nil `store` (no pack, or terrain switched off)
    /// clears the terrain.
    func update(store: TerrainStore?, location: CLLocation?, upDeg: Double,
                rangeNm: Double, altitudeFt: Double, verticalSpeedFpm: Double) {
        guard let store, let location else {
            if painted != nil || sweeping != nil || pending != nil { clear() }
            return
        }
        // A range change blanks the terrain; the next sweep paints it anew.
        if self.rangeNm != rangeNm {
            clear()
            self.rangeNm = rangeNm
            screenPointsPerNm = nil
        }

        if let sweep = sweeping, Date().timeIntervalSince(sweep.start) >= Self.sweepDuration {
            painted = sweep.snapshot
            sweeping = nil
            revision += 1
        }
        if sweeping == nil, let next = pending {
            sweeping = (next, Date())
            pending = nil
            revision += 1
        }
        guard pending == nil, !isRendering, let pointsPerNm = screenPointsPerNm, pointsPerNm > 0
        else { return }

        // One pixel per dot cell, a whole number of device pixels each, so
        // every dot comes out the same size on the screen.
        var devicePixels = max(1, (Self.dotCellPoints * displayScale).rounded())
        // A margin beyond the range, so the map stays covered as it moves
        // during the sweeps until the next picture.
        let sidePoints = 2 * 1.4 * CGFloat(rangeNm) * pointsPerNm
        var resolution = Int((sidePoints / (devicePixels / displayScale)).rounded(.up))
        while resolution > 1_600 {
            devicePixels += 1
            resolution = Int((sidePoints / (devicePixels / displayScale)).rounded(.up))
        }
        let halfSide = Double(CGFloat(resolution) * devicePixels / displayScale / pointsPerNm) / 2

        let center = location.coordinate
        let runway = AirportDatabase.shared.nearest(to: center, withinNm: 30)
        let heightAboveRunwayFt = runway.map { altitudeFt - $0.elevationFt }
        // There is no gear to read on a phone: take it as down on a final
        // descent, within 12 NM and 3000 ft of the nearest airport.
        let gearDown = runway.map {
            GreatCircle.distanceNm(center, $0.coordinate) < 12 && (heightAboveRunwayFt ?? .infinity) < 3_000
                && verticalSpeedFpm < 200
        } ?? false
        // Descending faster than 1000 fpm, the bands are measured from the
        // altitude 30 s ahead, as on the real display.
        let referenceFt = verticalSpeedFpm < -1_000 ? altitudeFt + verticalSpeedFpm / 2 : altitudeFt
        let request = NDTerrainRenderer.Request(
            center: center, upDeg: upDeg, halfSideNm: halfSide, resolution: resolution,
            viewRangeNm: rangeNm, referenceAltitudeFt: referenceFt, gearDown: gearDown,
            runwayElevationFt: runway?.elevationFt)

        isRendering = true
        Task.detached(priority: .userInitiated) {
            let picture = NDTerrainRenderer.picture(store: store, request)
            await MainActor.run {
                self.isRendering = false
                guard self.rangeNm == rangeNm, let picture else { return }
                self.pending = Snapshot(image: picture.image, center: center, upDeg: upDeg,
                                        halfSideNm: halfSide, rangeNm: rangeNm, readout: picture.readout)
            }
        }
    }

    private func clear() {
        painted = nil
        sweeping = nil
        pending = nil
        revision += 1
    }

    /// Draw the terrain under the map, inside the compass ring (`clipCenter`,
    /// `clipRadius`) and ahead of `sweepOrigin` — the aircraft — with the
    /// sweep in progress.
    func draw(in context: GraphicsContext, geometry g: NDGeometry,
              clipCenter: CGPoint, clipRadius: CGFloat, sweepOrigin: CGPoint) {
        guard g.rangeNm == rangeNm else { return }
        // The map's size on the screen, for the next picture's resolution.
        let t = context.transform
        screenPointsPerNm = g.pointsPerNm * sqrt(t.a * t.a + t.b * t.b)
        displayScale = context.environment.displayScale

        var ctx = context
        ctx.clip(to: Path(ellipseIn: CGRect(x: clipCenter.x - clipRadius, y: clipCenter.y - clipRadius,
                                            width: 2 * clipRadius, height: 2 * clipRadius)))
        // Terrain is shown ahead of the aircraft only.
        let top = clipCenter.y - 2 * clipRadius
        ctx.clip(to: Path(CGRect(x: clipCenter.x - 2 * clipRadius, y: top,
                                 width: 4 * clipRadius, height: sweepOrigin.y - top)))

        guard let sweep = sweeping else {
            if let painted { place(painted, in: ctx, geometry: g) }
            return
        }

        // Half-angle the sweep has reached either side of straight ahead.
        let progress = min(1, Date().timeIntervalSince(sweep.start) / Self.sweepDuration)
        let wedge = Self.wedge(origin: sweepOrigin, halfAngleDeg: 90 * progress, radius: 4 * clipRadius)

        if let painted {
            // The old picture everywhere the sweep has not reached yet: the
            // clip region with the wedge cut out of it.
            var old = ctx
            var outside = Path(CGRect(x: clipCenter.x - 2 * clipRadius, y: top,
                                      width: 4 * clipRadius, height: 4 * clipRadius))
            outside.addPath(wedge)
            old.clip(to: outside, style: FillStyle(eoFill: true))
            place(painted, in: old, geometry: g)
        }
        var new = ctx
        new.clip(to: wedge)
        place(sweep.snapshot, in: new, geometry: g)
    }

    /// A pie slice from `origin`, `halfAngleDeg` either side of straight up.
    private static func wedge(origin: CGPoint, halfAngleDeg: Double, radius: CGFloat) -> Path {
        var p = Path()
        guard halfAngleDeg > 0 else { return p }
        p.move(to: origin)
        // Angles in the canvas: straight up is -90°.
        p.addArc(center: origin, radius: radius,
                 startAngle: .degrees(-90 - halfAngleDeg), endAngle: .degrees(-90 + halfAngleDeg),
                 clockwise: false)
        p.closeSubpath()
        return p
    }

    /// Draw one picture where it belongs on the map.
    private func place(_ snapshot: Snapshot, in context: GraphicsContext, geometry g: NDGeometry) {
        guard snapshot.rangeNm == g.rangeNm else { return }
        let at = g.project(snapshot.center)
        let side = CGFloat(snapshot.halfSideNm * 2) * g.pointsPerNm
        var ctx = context
        ctx.translateBy(x: at.x, y: at.y)
        // The picture has `upDeg` at its top; the map has `headingDeg`.
        ctx.rotate(by: .degrees(snapshot.upDeg - g.headingDeg))
        // Nearest-neighbour scaling keeps the dot patterns crisp.
        ctx.draw(Image(decorative: snapshot.image, scale: 1).interpolation(.none),
                 in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
    }
}

extension NDGeometry {
    /// Airports to show on the map: within the range (plus a margin), only
    /// the large ones at wide ranges, without the airports the plan already
    /// marks.
    func airportsInView(excluding codes: Set<String>) -> [Airport] {
        AirportDatabase.shared.airports(near: origin, withinNm: rangeNm * 1.3)
            .filter { !codes.contains($0.icao) && ($0.isLarge || rangeNm <= 80) }
    }
}
