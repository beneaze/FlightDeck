import CoreLocation
import SwiftUI

/// Geometry of the A320 ND in ARC mode, in the display's own coordinate system.
///
/// The real ND is authored as a 768 × 768 SVG. The compass rose rotates about
/// (384, 620), the aircraft symbol sits just below it at (384, 626), and
/// 498 px of map represent the selected range. Drawing in those units — then
/// scaling the whole canvas once — keeps every element in the exact
/// relationship the real display has.
///
/// Coordinates follow the FlyByWire A32NX ND, which is the reference
/// implementation for this instrument.
enum ND {

    /// Side of the square display.
    static let canvas: CGFloat = 768

    /// Centre of the compass rose and of every range arc.
    static let center = CGPoint(x: 384, y: 620)

    /// The aircraft symbol / map origin — six units below the rose centre,
    /// exactly as on the reference display.
    static let planeCenter = CGPoint(x: 384, y: 626)

    /// Radius of the heading ring.
    static let ringRadius: CGFloat = 492

    /// Pixels representing the full selected range on the map.
    static let mapRadius: CGFloat = 498

    // MARK: Type sizes (px in canvas units, from the A32NX style sheet)

    static let fontLarge: CGFloat = 32.5
    static let fontIntermediate: CGFloat = 27.5
    static let fontSmall: CGFloat = 25
    static let fontSmallest: CGFloat = 22.5
    /// Waypoint idents on the map layer.
    static let fontMap: CGFloat = 21

    // MARK: Derived geometry

    /// The reference display is square; a phone's ND area rarely is. The
    /// sector therefore fills the available width — the ring reaching the
    /// sides at up to `maxHalfSpanDeg` either side of the lubber line — and
    /// the vertical band from the rose's top labels down to just below the
    /// aircraft (`bandTop`…`bandBottom`) is what must fit the height.
    static let maxHalfSpanDeg = 60.0
    static let bandTop: CGFloat = 55
    static let bandBottom: CGFloat = 685

    /// The ring itself is drawn a little past the last graduation.
    static let ringSpanDeg = 75.0
    /// Graduations and labels stop here.
    static let tickSpanDeg = 70.0

    /// Point at a bearing (degrees from straight up) and radius from ``center``.
    static func point(bearingDeg: Double, radius: CGFloat) -> CGPoint {
        let a = bearingDeg * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(a)),
                       y: center.y - radius * CGFloat(cos(a)))
    }

    /// The ARC-mode map region: everything under the heading ring's arc,
    /// stretched sideways and down to whatever the display edges are.
    static func mapClip(in bounds: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: bounds.minX, y: 312))
        // The ring arc from (0, 312) over the top to (768, 312).
        let sweep = atan2(384.0, 308.0) * 180 / .pi
        for step in stride(from: -sweep, through: sweep, by: 1.5) {
            p.addLine(to: point(bearingDeg: step, radius: ringRadius))
        }
        p.addLine(to: CGPoint(x: 768, y: 312))
        p.addLine(to: CGPoint(x: bounds.maxX, y: 312))
        p.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        p.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        p.closeSubpath()
        return p
    }

    /// The dashed inner range arcs at ¼, ½ and ¾ of the selected range. Each
    /// is a full circle cut by a wedge-shaped clip, so the dashes vanish in a
    /// V around the aircraft instead of ending abruptly. The wedge is defined
    /// by the V's bottom and the slopes of its arms (from the reference
    /// display's fixed clip polygons), extended out to the display edges.
    struct RangeArc {
        let radius: CGFloat
        let dash: [CGFloat]
        let dashPhase: CGFloat
        let apexY: CGFloat
        let leftSlope: CGFloat
        let rightSlope: CGFloat

        func clip(in bounds: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: bounds.minX,
                               y: apexY - leftSlope * (ND.center.x - bounds.minX)))
            p.addLine(to: CGPoint(x: ND.center.x, y: apexY))
            p.addLine(to: CGPoint(x: bounds.maxX,
                                  y: apexY - rightSlope * (bounds.maxX - ND.center.x)))
            p.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
            p.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY))
            p.closeSubpath()
            return p
        }
    }

    static let rangeArcs: [RangeArc] = [
        RangeArc(radius: 369, dash: [15, 10.5], dashPhase: 15,
                 apexY: 709, leftSlope: 0.3776, rightSlope: 0.3776),
        RangeArc(radius: 246, dash: [15, 10], dashPhase: -6,
                 apexY: 687, leftSlope: 0.4036, rightSlope: 0.3802),
        RangeArc(radius: 123, dash: [15, 10], dashPhase: -4.2,
                 apexY: 664, leftSlope: 0.3776, rightSlope: 0.2240),
    ]
}

/// Maps geographic positions onto the ND's ARC-mode canvas.
///
/// In ARC mode the aircraft sits near the bottom edge, `radius` represents the
/// full selected range, and the whole picture is rotated so the current
/// heading points straight up.
struct NDGeometry {
    /// Aircraft symbol position, near the bottom edge.
    let apex: CGPoint
    /// Radius representing the full selected range, in points.
    let radius: CGFloat
    /// Nautical miles represented by `radius`.
    let rangeNm: Double
    /// Present position — the origin of the local projection.
    let origin: CLLocationCoordinate2D
    /// Display orientation. Heading-up, so the lubber line is the heading.
    let headingDeg: Double

    var pointsPerNm: CGFloat { radius / CGFloat(rangeNm) }

    /// Screen position of a point at a given bearing and distance from the aircraft.
    func point(bearingDeg: Double, distanceNm: Double) -> CGPoint {
        let a = (bearingDeg - headingDeg) * .pi / 180
        let r = CGFloat(distanceNm) * pointsPerNm
        return CGPoint(x: apex.x + r * sin(a), y: apex.y - r * cos(a))
    }

    /// Screen position of a coordinate.
    ///
    /// Uses a local flat-earth approximation about the present position, which
    /// is accurate to well under a pixel at every selectable ND range.
    func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        let northNm = (coordinate.latitude - origin.latitude) * 60
        let eastNm = (coordinate.longitude - origin.longitude) * 60
            * cos(origin.latitude * .pi / 180)

        let t = headingDeg * .pi / 180
        let x = eastNm * cos(t) - northNm * sin(t)
        let y = northNm * cos(t) + eastNm * sin(t)

        return CGPoint(x: apex.x + CGFloat(x) * pointsPerNm,
                       y: apex.y - CGFloat(y) * pointsPerNm)
    }

    /// Great-circle bearing and distance from the aircraft to a coordinate.
    func vector(to coordinate: CLLocationCoordinate2D) -> (bearingDeg: Double, distanceNm: Double) {
        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let to = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distanceNm = from.distance(from: to) / 1852

        let lat1 = origin.latitude * .pi / 180, lat2 = coordinate.latitude * .pi / 180
        let dLon = (coordinate.longitude - origin.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (normalizedHeading(atan2(y, x) * 180 / .pi), distanceNm)
    }
}
