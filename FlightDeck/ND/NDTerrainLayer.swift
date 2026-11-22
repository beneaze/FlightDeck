import SwiftUI
import CoreLocation

/// The ND's terrain picture in plane mode. Rendering the raster takes a few
/// milliseconds, so it is redone off the main thread at most once a second
/// (or at once on a range change); between renders the last picture is kept
/// in place on the map by drawing it at the position and orientation it was
/// rendered for, so it moves and turns with the map at the full frame rate.
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
    }

    @Published private(set) var snapshot: Snapshot?
    private var lastRender = Date.distantPast
    private var isRendering = false

    func update(store: TerrainStore?, location: CLLocation?, upDeg: Double,
                rangeNm: Double, altitudeFt: Double) {
        guard let store, let location else {
            if snapshot != nil { snapshot = nil }
            return
        }
        let rangeChanged = snapshot.map { $0.rangeNm != rangeNm } ?? true
        guard !isRendering, rangeChanged || Date().timeIntervalSince(lastRender) >= 1 else { return }
        isRendering = true
        lastRender = Date()
        let center = location.coordinate
        // A margin beyond the range, so the corners of the map stay covered
        // while the picture waits for its next render.
        let halfSide = rangeNm * 1.25
        Task.detached(priority: .userInitiated) {
            let image = NDTerrainRenderer.image(store: store, center: center, upDeg: upDeg,
                                                rangeNm: halfSide, aircraftAltitudeFt: altitudeFt,
                                                resolution: 112)
            await MainActor.run {
                self.isRendering = false
                self.snapshot = image.map {
                    Snapshot(image: $0, center: center, upDeg: upDeg, halfSideNm: halfSide, rangeNm: rangeNm)
                }
            }
        }
    }

    /// Draw the picture under the map, placed by the map's own projection,
    /// inside the circle of radius `clipRadius` around `clipCenter` (the
    /// compass ring), as terrain is shown on the real displays.
    func draw(in context: GraphicsContext, geometry g: NDGeometry, clipCenter: CGPoint, clipRadius: CGFloat) {
        guard let snapshot, snapshot.rangeNm == g.rangeNm else { return }
        let at = g.project(snapshot.center)
        let side = CGFloat(snapshot.halfSideNm * 2) * g.pointsPerNm
        var ctx = context
        ctx.clip(to: Path(ellipseIn: CGRect(x: clipCenter.x - clipRadius, y: clipCenter.y - clipRadius,
                                            width: 2 * clipRadius, height: 2 * clipRadius)))
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
