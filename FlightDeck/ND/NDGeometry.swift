import CoreLocation
import SwiftUI

/// Layout of the A320-style ND in ARC mode, in our own 1000 × 1000 unit
/// canvas.
///
/// Everything hangs off a handful of design parameters: where the compass
/// rose is centred, how big its ring is, and how far the aircraft symbol sits
/// below the rose centre. Graduations, labels, the map circle, the range
/// arcs and the band that has to fit on screen are all derived from those, so
/// the display keeps its proportions when one of them is changed. The whole
/// canvas is scaled once to fit the screen.
enum ND {

    // MARK: Design parameters

    /// Side of the square canvas.
    static let canvas: CGFloat = 1000

    /// Centre of the compass rose and of every range arc. Low on the canvas:
    /// in ARC mode the aircraft looks forward across most of the display.
    static let center = CGPoint(x: 500, y: 810)

    /// Radius of the heading ring.
    static let ringRadius: CGFloat = 640

    /// How far the aircraft symbol sits below the rose centre.
    static let planeOffset: CGFloat = 8

    /// Graduation lengths, standing outward of the ring.
    static let majorTick: CGFloat = 38
    static let minorTick: CGFloat = 20
    /// Gap between the end of a major graduation and its label.
    static let labelGap: CGFloat = 10

    /// Rose labels: large at the cardinal-ish 30° marks, small otherwise.
    static let roseLabelLarge: CGFloat = 44
    static let roseLabelSmall: CGFloat = 29

    /// Half-length of the lubber line, centred on the top of the ring.
    static let lubberHalfLength: CGFloat = 26

    /// Stroke widths.
    static let lineWidth: CGFloat = 2.6
    static let routeWidth: CGFloat = 2.3
    static let symbolWidth: CGFloat = 6.5

    // MARK: Type sizes

    static let fontLarge: CGFloat = 42
    static let fontIntermediate: CGFloat = 36
    static let fontSmall: CGFloat = 32
    static let fontSmallest: CGFloat = 29
    /// Waypoint idents on the map layer.
    static let fontMap: CGFloat = 27

    /// Horizontal advance of one character of the monospaced display face,
    /// for laying out the data blocks column by column.
    static func advance(_ size: CGFloat) -> CGFloat { size * 0.6 }

    // MARK: Derived geometry

    /// The aircraft symbol / map origin.
    static var planeCenter: CGPoint { CGPoint(x: center.x, y: center.y + planeOffset) }

    /// Distance representing the full selected range. Measured from the
    /// aircraft, so the full range lands exactly on the ring dead ahead.
    static var mapRadius: CGFloat { ringRadius + planeOffset }

    /// Radius at which the rose labels are centred.
    static var labelRadius: CGFloat { ringRadius + majorTick + labelGap + roseLabelLarge / 2 }

    /// The canvas is square; a phone's ND area rarely is. The sector
    /// therefore fills the available width — the ring reaching the sides at
    /// up to `maxHalfSpanDeg` either side of the lubber line — and the band
    /// from the top of the rose labels to just below the aircraft
    /// (`bandTop`…`bandBottom`) is what must fit the height.
    static let maxHalfSpanDeg = 60.0
    static var bandTop: CGFloat { center.y - labelRadius - roseLabelLarge * 0.7 }
    static var bandBottom: CGFloat { planeCenter.y + Airplane.tail + 20 }

    /// The ring is drawn a little past the last graduation.
    static let ringSpanDeg = 75.0
    /// Graduations and labels stop here.
    static let tickSpanDeg = 70.0

    /// Aircraft symbol proportions, from its centre (where the wings cross
    /// the fuselage).
    enum Airplane {
        static let wingHalfSpan: CGFloat = 54
        static let nose: CGFloat = 38
        static let tail: CGFloat = 52
        static let tailplaneAt: CGFloat = 40
        static let tailplaneHalfSpan: CGFloat = 15
    }

    /// Point at a bearing (degrees from straight up) and radius from ``center``.
    static func point(bearingDeg: Double, radius: CGFloat) -> CGPoint {
        let a = bearingDeg * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(a)),
                       y: center.y - radius * CGFloat(cos(a)))
    }

    /// The ARC-mode map region: everything under the heading ring's arc,
    /// stretched sideways and down to whatever the display edges are. The
    /// arc is followed to where it leaves the square canvas.
    static func mapClip(in bounds: CGRect) -> Path {
        let halfWidth = canvas / 2
        let sweep = asin(halfWidth / ringRadius) * 180 / .pi
        let sideY = center.y - (ringRadius * ringRadius - halfWidth * halfWidth).squareRoot()

        var p = Path()
        p.move(to: CGPoint(x: bounds.minX, y: sideY))
        for step in stride(from: -sweep, through: sweep, by: 1.5) {
            p.addLine(to: point(bearingDeg: step, radius: ringRadius))
        }
        p.addLine(to: point(bearingDeg: sweep, radius: ringRadius))
        p.addLine(to: CGPoint(x: bounds.maxX, y: sideY))
        p.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        p.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        p.closeSubpath()
        return p
    }

    // MARK: Range arcs

    /// The dashed inner range arcs sit at these fractions of the selected
    /// range.
    static let rangeArcFractions: [CGFloat] = [0.25, 0.5, 0.75]
    static let rangeArcDash: [CGFloat] = [20, 13]

    /// The arcs stop short of the aircraft in a V: one wedge, opening upward
    /// from a point just below the aircraft with its arms rising at this
    /// angle, hides them all. Small arcs therefore end level with the rose
    /// centre and large ones progressively higher.
    static var rangeArcGapApex: CGPoint { CGPoint(x: center.x, y: planeCenter.y + 28) }
    static let rangeArcGapArmDeg = 12.5

    /// Everything above the V, out to the display edges.
    static func rangeArcClip(in bounds: CGRect) -> Path {
        let apex = rangeArcGapApex
        let slope = CGFloat(tan(rangeArcGapArmDeg * .pi / 180))
        var p = Path()
        p.move(to: CGPoint(x: bounds.minX, y: apex.y - slope * (apex.x - bounds.minX)))
        p.addLine(to: apex)
        p.addLine(to: CGPoint(x: bounds.maxX, y: apex.y - slope * (bounds.maxX - apex.x)))
        p.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        p.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY))
        p.closeSubpath()
        return p
    }

    /// Range labels sit on their arc at this bearing either side of the
    /// lubber line, inset horizontally into the arc.
    static let rangeLabelBearingDeg = 66.0
    static let rangeLabelInset: CGFloat = 20
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
