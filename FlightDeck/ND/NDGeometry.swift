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

    // MARK: Selected heading

    /// The cyan selected-heading triangle, standing outward from the ring.
    static let selectedHeadingHeight: CGFloat = 30
    static let selectedHeadingHalfWidth: CGFloat = 14
    /// How far in from the display side the arc counts as visible.
    static let selectedHeadingEdgeMargin: CGFloat = 30

    // MARK: Flight-plan symbols

    /// The flight plan's dashes while a heading is selected.
    static let routeDash: [CGFloat] = [18, 12]
    /// Half-diagonal of the waypoint diamond.
    static let waypointHalf: CGFloat = 8.5
    /// The altitude-constraint circle round a waypoint diamond.
    static var constraintCircleRadius: CGFloat { waypointHalf * 2.2 }
    /// Arm length of the level-off / top-of-descent arrows.
    static let profileSymbolSize: CGFloat = 22
    static let decelRadius: CGFloat = 14
    static let airportStarRadius: CGFloat = 11

    /// Selected runways are drawn to scale up to this range; further out
    /// the airport symbol stands for them.
    static let runwayMaxRangeNm = 40.0
    /// The outline is never thinner than this, so it reads as a rectangle.
    static let runwayMinWidth: CGFloat = 9
    /// Length and dash pattern of the extended centreline.
    static let runwayCentrelineNm = 10.0
    static let runwayCentrelineDash: [CGFloat] = [14, 12]
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

// MARK: - Flight-plan symbols

/// One thing the ND draws for the flight plan ahead: a waypoint, a pseudo
/// waypoint of the vertical profile, or the destination's runway or airport.
/// Both NDs build the same list and draw it in their own symbology.
struct NDPlanPoint {
    enum Kind {
        /// An ordinary fix: entered, SID/STAR/approach, or "(2900)".
        case fix
        /// Top of climb: where the climb reaches the cruise level.
        case topOfClimb
        /// Top of descent.
        case topOfDescent
        /// Where the deceleration for the approach begins.
        case decel
        /// The destination runway threshold, drawn by the runway symbol.
        case runway
        /// The destination airport, when no runway is selected.
        case airport
    }

    let ident: String
    let coordinate: CLLocationCoordinate2D
    let kind: Kind
    /// The leg's altitude constraint, for fixes that carry one.
    let constraintFt: Double?
    /// The TO (Airbus) / active (Boeing) waypoint.
    let isActive: Bool
}

extension RoutePlanner {
    /// The waypoint the display calls TO / active: the first real fix still
    /// ahead. Pseudo waypoints (T/C, T/D) sequence in the plan but are never
    /// the TO waypoint on the real units.
    var toWaypointIndex: Int? {
        waypoints.indices.first { $0 >= activeWaypointIndex && !Self.isPseudoIdent(waypoints[$0].ident) }
            ?? (waypoints.indices.contains(activeWaypointIndex) ? activeWaypointIndex : nil)
    }

    var toWaypoint: Waypoint? { toWaypointIndex.map { waypoints[$0] } }

    static func isPseudoIdent(_ ident: String) -> Bool { ident == "T/C" || ident == "T/D" }

    /// The plan from the TO waypoint on, classified for drawing.
    var ndPlanPoints: [NDPlanPoint] {
        let plan = flightPlan
        let legs = plan?.legs ?? []
        let active = toWaypointIndex
        var points: [NDPlanPoint] = []
        for (index, waypoint) in waypoints.enumerated() where index >= activeWaypointIndex {
            let fix = legs.first {
                $0.ident == waypoint.ident && GreatCircle.distanceNm($0.coordinate, waypoint.coordinate) < 0.5
            }
            let kind: NDPlanPoint.Kind
            switch waypoint.ident {
            case "T/C": kind = .topOfClimb
            case "T/D": kind = .topOfDescent
            default:
                if fix?.kind == .destination || waypoint.ident == plan?.approachRunway?.fixIdent {
                    kind = plan?.approachRunway != nil ? .runway : .airport
                } else {
                    kind = .fix
                }
            }
            // Constraints belong to the procedures' and the generated
            // approach's fixes. The runway fixes carry the field elevation,
            // and an altitude fix "(2900)" is its own altitude.
            var constraint: Double?
            if kind == .fix, let fix, [.departure, .arrival, .approach].contains(fix.kind),
               !fix.ident.hasPrefix("(") {
                constraint = fix.altitudeFt
            }
            points.append(NDPlanPoint(ident: waypoint.ident, coordinate: waypoint.coordinate, kind: kind,
                                      constraintFt: constraint, isActive: index == active))
        }
        if let decel = decelPoint { points.append(decel) }
        return points
    }

    /// Our FMS computes no speed profile, so the deceleration point is
    /// estimated: a few miles before the approach's first fix, where an
    /// airliner leaves its descent speed to arrive configured. Shown until
    /// passed, and never before the top of descent.
    private var decelPoint: NDPlanPoint? {
        guard let plan = flightPlan else { return nil }
        let legs = plan.legs, distances = plan.legDistancesNm
        guard let first = legs.firstIndex(where: { $0.kind == .approach }) else { return nil }
        let along = max(plan.topOfDescentNm, distances[first] - Self.decelBeforeApproachNm)
        guard along > alongTrackNm, along < plan.totalDistanceNm else { return nil }
        return NDPlanPoint(ident: "DECEL", coordinate: plan.coordinate(atNm: along), kind: .decel,
                           constraintFt: nil, isActive: false)
    }

    static let decelBeforeApproachNm = 3.0

    /// The selected runways, which the ND draws to scale: take-off and
    /// landing.
    var ndRunways: [Runway] {
        guard let plan = flightPlan else { return [] }
        return [plan.departureRunway, plan.approachRunway].compactMap { $0 }
    }

    /// Origin and destination with no runway selected — shown as airports.
    var ndPlanAirports: [Airport] {
        guard let plan = flightPlan else { return [] }
        var airports: [Airport] = []
        if plan.departureRunway == nil { airports.append(plan.origin) }
        if plan.approachRunway == nil { airports.append(plan.destination) }
        return airports
    }
}

// MARK: - Runway geometry

/// A runway as the ND draws it: the outline to scale (made wide enough to
/// read as a rectangle) and the extended centreline out from its threshold
/// — all from the runway's own position, true heading and length, so the
/// heading-up (or track-up) projection turns it correctly.
struct NDRunwayShape {
    /// Outline corners, threshold side first.
    let outline: [CGPoint]
    /// Threshold and far end on the centreline.
    let threshold: CGPoint
    let farEnd: CGPoint
    /// Out from the threshold along the approach course.
    let centrelineEnd: CGPoint

    var outlinePath: Path {
        var p = Path()
        p.addLines(outline)
        p.closeSubpath()
        return p
    }

    var centrelinePath: Path {
        var p = Path()
        p.move(to: threshold)
        p.addLine(to: centrelineEnd)
        return p
    }

    /// Where the ident goes: beside the threshold, off to the screen-right
    /// side of the runway axis, clear of the centreline and the final.
    func labelAnchor(offset: CGFloat) -> CGPoint {
        let dx = farEnd.x - threshold.x, dy = farEnd.y - threshold.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        var nx = -dy / length, ny = dx / length
        if nx < 0 { nx = -nx; ny = -ny }
        let mid = CGPoint(x: (threshold.x + farEnd.x) / 2, y: (threshold.y + farEnd.y) / 2)
        return CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset)
    }
}

extension NDGeometry {
    /// Real runways are 45–60 m wide, well under a point at most ranges;
    /// the outline is drawn at least `minimumWidth` canvas units wide.
    func runwayShape(_ runway: Runway, minimumWidth: CGFloat, centrelineNm: Double) -> NDRunwayShape {
        let start = project(runway.coordinate)
        let end = project(GreatCircle.destination(from: runway.coordinate, courseDeg: runway.headingDeg,
                                                  distanceNm: max(runway.lengthNm, 0.3)))
        let outbound = normalizedHeading(runway.headingDeg + 180)
        let centreline = project(GreatCircle.destination(from: runway.coordinate, courseDeg: outbound,
                                                         distanceNm: centrelineNm))
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let halfWidth = max(minimumWidth, CGFloat(45.0 / 1852) * pointsPerNm) / 2
        let nx = -dy / length * halfWidth, ny = dx / length * halfWidth
        return NDRunwayShape(
            outline: [CGPoint(x: start.x + nx, y: start.y + ny), CGPoint(x: end.x + nx, y: end.y + ny),
                      CGPoint(x: end.x - nx, y: end.y - ny), CGPoint(x: start.x - nx, y: start.y - ny)],
            threshold: start, farEnd: end, centrelineEnd: centreline)
    }

    /// Whether a coordinate falls inside the map, with a margin.
    func isInView(_ coordinate: CLLocationCoordinate2D, margin: Double = 1.2) -> Bool {
        let p = project(coordinate)
        let dx = p.x - apex.x, dy = p.y - apex.y
        return (dx * dx + dy * dy).squareRoot() <= radius * CGFloat(margin)
    }
}

// MARK: - Label placement

/// The real displays set a label in a fixed spot beside its symbol. Where
/// that spot would put an airport's ident across the flight-plan line, the
/// label takes the next candidate spot instead.
enum NDLabels {
    /// The first of `candidates` (label rectangles) that the polyline does
    /// not cross, else the first.
    static func place(_ candidates: [CGRect], avoiding polyline: [CGPoint]) -> CGRect {
        candidates.first { !crosses(polyline, $0) } ?? candidates[0]
    }

    static func crosses(_ polyline: [CGPoint], _ rect: CGRect) -> Bool {
        guard polyline.count > 1 else { return false }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            // Cheap reject: the segment's box clear of the rectangle.
            if max(a.x, b.x) < rect.minX || min(a.x, b.x) > rect.maxX
                || max(a.y, b.y) < rect.minY || min(a.y, b.y) > rect.maxY { continue }
            if rect.contains(a) || rect.contains(b) { return true }
            for i in 0..<4 where segmentsIntersect(a, b, corners[i], corners[(i + 1) % 4]) {
                return true
            }
        }
        return false
    }

    private static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let d1 = cross(p3, p4, p1), d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3), d4 = cross(p1, p2, p4)
        return d1 * d2 < 0 && d3 * d4 < 0
    }
}
