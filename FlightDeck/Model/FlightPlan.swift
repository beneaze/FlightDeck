import Foundation
import CoreLocation

/// Great-circle geometry on a spherical Earth — plenty for a display.
enum GreatCircle {
    static let earthRadiusNm = 3_440.065

    static func distanceNm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1, dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadiusNm * asin(min(1, sqrt(h)))
    }

    /// Initial course from `a` to `b`, degrees true.
    static func initialCourse(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return normalizedHeading(atan2(y, x) * 180 / .pi)
    }

    /// The point a `fraction` (0…1) of the way along the great circle.
    static func intermediate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                             fraction f: Double) -> CLLocationCoordinate2D {
        let δ = distanceNm(a, b) / earthRadiusNm
        guard δ > 1e-9 else { return a }
        let φ1 = a.latitude * .pi / 180, λ1 = a.longitude * .pi / 180
        let φ2 = b.latitude * .pi / 180, λ2 = b.longitude * .pi / 180
        let wa = sin((1 - f) * δ) / sin(δ), wb = sin(f * δ) / sin(δ)
        let x = wa * cos(φ1) * cos(λ1) + wb * cos(φ2) * cos(λ2)
        let y = wa * cos(φ1) * sin(λ1) + wb * cos(φ2) * sin(λ2)
        let z = wa * sin(φ1) + wb * sin(φ2)
        return CLLocationCoordinate2D(latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
                                      longitude: atan2(y, x) * 180 / .pi)
    }

    /// The point `distanceNm` from `start` along `courseDeg`.
    static func destination(from start: CLLocationCoordinate2D, courseDeg: Double,
                            distanceNm: Double) -> CLLocationCoordinate2D {
        let δ = distanceNm / earthRadiusNm, θ = courseDeg * .pi / 180
        let φ1 = start.latitude * .pi / 180, λ1 = start.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        let lon = (λ2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: φ2 * 180 / .pi, longitude: lon)
    }

    /// Points along the great circle from `a` to `b`, no more than
    /// `spacingNm` apart, both ends included.
    static func points(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D,
                       spacingNm: Double) -> [CLLocationCoordinate2D] {
        let total = distanceNm(a, b)
        let count = max(1, Int(ceil(total / spacingNm)))
        return (0...count).map { intermediate(a, b, fraction: Double($0) / Double(count)) }
    }
}

/// The flight the passenger is on: where from, where to, the path it is
/// expected to take, and the vertical profile — prepared on the ground and
/// carried offline in a flight pack.
struct FlightPlan: Codable, Identifiable, Hashable {
    struct RoutePoint: Codable, Hashable {
        let latitude: Double
        let longitude: Double
        /// Altitude at this point when the path comes from a flown track.
        let altitudeFt: Double?

        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    /// Where the lateral path came from.
    enum RouteSource: Codable, Hashable {
        /// Straight great circle between the airports.
        case greatCircle
        /// The track this flight actually flew on an earlier day, from the
        /// open ADS-B archive (date as yyyy-MM-dd).
        case archive(flownOn: String)
        /// Entered on the MCDU: runways, departure, waypoints, approach.
        case entered
    }

    /// A point of an entered flight plan.
    struct Fix: Codable, Hashable {
        enum Kind: String, Codable {
            /// The departure airport, or its runway.
            case origin
            /// The end of the runway-heading climb after take-off.
            case departure
            /// A waypoint entered by the crew.
            case enroute
            /// The approach: intercept and final approach fix.
            case approach
            /// The arrival airport, or its runway threshold.
            case destination
        }

        let ident: String
        let latitude: Double
        let longitude: Double
        let kind: Kind
        /// Altitude constraint, where the leg has one.
        let altitudeFt: Double?

        init(ident: String, coordinate: CLLocationCoordinate2D, kind: Kind, altitudeFt: Double? = nil) {
            self.ident = ident
            latitude = coordinate.latitude
            longitude = coordinate.longitude
            self.kind = kind
            self.altitudeFt = altitudeFt
        }

        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    let id: UUID
    /// As entered, e.g. "LH400"; nil for a flight planned by airports alone.
    var flightNumber: String?
    /// The ICAO callsign looked up, e.g. "DLH400".
    var callsign: String?
    /// Day of departure.
    var date: Date
    let origin: Airport
    let destination: Airport
    var cruiseAltitudeFt: Double
    let route: [RoutePoint]
    let source: RouteSource
    /// Take-off runway, approach runway and waypoints entered on the MCDU.
    /// Optional so packs saved before they existed still load.
    let departureRunway: Runway?
    let approachRunway: Runway?
    let enroute: [Fix]?

    init(id: UUID = UUID(), flightNumber: String?, callsign: String?, date: Date,
         origin: Airport, destination: Airport, cruiseAltitudeFt: Double? = nil,
         route: [RoutePoint]? = nil, source: RouteSource = .greatCircle,
         departureRunway: Runway? = nil, approachRunway: Runway? = nil, enroute: [Fix] = []) {
        self.id = id
        self.flightNumber = flightNumber
        self.callsign = callsign
        self.date = date
        self.origin = origin
        self.destination = destination
        self.departureRunway = departureRunway
        self.approachRunway = approachRunway
        self.enroute = enroute.isEmpty ? nil : enroute
        let isEntered = departureRunway != nil || approachRunway != nil || !enroute.isEmpty
        let points: [RoutePoint]
        if isEntered {
            let fixes = Self.legs(origin: origin, destination: destination, departureRunway: departureRunway,
                                  approachRunway: approachRunway, enroute: enroute)
            points = Self.densified(fixes.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude,
                                                           altitudeFt: nil) })
            self.source = .entered
        } else {
            points = route.map(Self.densified)
                ?? GreatCircle.points(from: origin.coordinate, to: destination.coordinate, spacingNm: 5)
                    .map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude, altitudeFt: nil) }
            self.source = route == nil ? .greatCircle : source
        }
        self.route = points
        let distance = Self.length(of: points)
        self.cruiseAltitudeFt = cruiseAltitudeFt
            ?? points.compactMap(\.altitudeFt).max().map { ($0 / 1_000).rounded() * 1_000 }
            ?? Self.defaultCruiseAltitudeFt(distanceNm: distance)
    }

    /// A path with no leg longer than 5 NM: long legs (an archived track
    /// across a gap in receiver coverage, say) get great-circle points in
    /// between, with altitudes interpolated. The plan is then the same
    /// curve wherever it is used — flown by the demo, projected onto for
    /// progress, drawn on the ND — instead of a great circle in one place
    /// and a straight map line in another.
    static func densified(_ points: [RoutePoint]) -> [RoutePoint] {
        guard var previous = points.first else { return points }
        var result = [previous]
        for point in points.dropFirst() {
            let legNm = GreatCircle.distanceNm(previous.coordinate, point.coordinate)
            let pieces = Int(ceil(legNm / 5))
            if pieces > 1 {
                for i in 1..<pieces {
                    let f = Double(i) / Double(pieces)
                    let c = GreatCircle.intermediate(previous.coordinate, point.coordinate, fraction: f)
                    let alt: Double? = previous.altitudeFt.flatMap { a in point.altitudeFt.map { a + ($0 - a) * f } }
                    result.append(RoutePoint(latitude: c.latitude, longitude: c.longitude, altitudeFt: alt))
                }
            }
            result.append(point)
            previous = point
        }
        return result
    }

    /// Display name: the flight number, or the city pair.
    var title: String { flightNumber ?? "\(origin.icao)–\(destination.icao)" }

    /// One line for lists: "SK455  OSL → CPH", or just "OSL → CPH" when the
    /// flight was planned by airports alone.
    var summary: String {
        let pair = "\(origin.icao) → \(destination.icao)"
        return flightNumber.map { "\($0)  \(pair)" } ?? pair
    }

    // MARK: Legs

    /// The plan as the MCDU lists it: origin (or its runway), the
    /// departure, the entered waypoints, the approach and the destination
    /// (or its runway). A plan with nothing entered is just the two
    /// airports.
    var legs: [Fix] {
        Self.legs(origin: origin, destination: destination, departureRunway: departureRunway,
                  approachRunway: approachRunway, enroute: enroute ?? [])
    }

    /// Climb straight ahead after take-off to 1500 ft above the runway.
    static let departureClimbFt = 1_500.0
    /// The generated approach: a 3° final from a final approach fix 5 NM
    /// out, intercepted 12 NM out.
    static let finalApproachFixNm = 5.0
    static let interceptNm = 12.0

    static func legs(origin: Airport, destination: Airport, departureRunway: Runway?,
                     approachRunway: Runway?, enroute: [Fix]) -> [Fix] {
        var legs: [Fix] = []
        if let runway = departureRunway {
            let elevation = runway.elevationFt ?? origin.elevationFt
            legs.append(Fix(ident: runway.fixIdent, coordinate: runway.coordinate, kind: .origin,
                            altitudeFt: elevation))
            // A runway-heading climb to 1500 ft above the field, named as
            // the units name an altitude-terminated leg: "(2900)".
            let target = ((elevation + departureClimbFt) / 100).rounded(.up) * 100
            let climbNm = runway.lengthNm + departureClimbFt / 1_000 * climbNmPer1000Ft
            legs.append(Fix(ident: "(\(Int(target)))",
                            coordinate: GreatCircle.destination(from: runway.coordinate, courseDeg: runway.headingDeg,
                                                                distanceNm: climbNm),
                            kind: .departure, altitudeFt: target))
        } else {
            legs.append(Fix(ident: origin.icao, coordinate: origin.coordinate, kind: .origin,
                            altitudeFt: origin.elevationFt))
        }
        legs.append(contentsOf: enroute)
        if let runway = approachRunway {
            let elevation = runway.elevationFt ?? destination.elevationFt
            let outbound = (runway.headingDeg + 180).truncatingRemainder(dividingBy: 360)
            func onFinal(_ nm: Double) -> CLLocationCoordinate2D {
                GreatCircle.destination(from: runway.threshold, courseDeg: outbound, distanceNm: nm)
            }
            func glidepath(_ nm: Double) -> Double {
                ((elevation + nm / descentNmPer1000Ft * 1_000) / 100).rounded() * 100
            }
            legs.append(Fix(ident: "CI" + runway.ident, coordinate: onFinal(interceptNm), kind: .approach,
                            altitudeFt: glidepath(interceptNm)))
            legs.append(Fix(ident: "FF" + runway.ident, coordinate: onFinal(finalApproachFixNm), kind: .approach,
                            altitudeFt: glidepath(finalApproachFixNm)))
            legs.append(Fix(ident: runway.fixIdent, coordinate: runway.threshold, kind: .destination,
                            altitudeFt: elevation + 50))
        } else {
            legs.append(Fix(ident: destination.icao, coordinate: destination.coordinate, kind: .destination,
                            altitudeFt: destination.elevationFt))
        }
        return legs
    }

    /// Along-track distance of each leg's fix from the start of the path.
    var legDistancesNm: [Double] {
        var total = 0.0
        var result: [Double] = []
        var previous: CLLocationCoordinate2D?
        for fix in legs {
            if let previous { total += GreatCircle.distanceNm(previous, fix.coordinate) }
            result.append(total)
            previous = fix.coordinate
        }
        // A flown or great-circle path is not made of the legs: scale so
        // the destination sits at the path's end.
        if source != .entered, let last = result.last, last > 0 {
            let scale = totalDistanceNm / last
            result = result.map { $0 * scale }
        }
        return result
    }

    /// Two plans with the same key fly the same path: a flight pack
    /// downloaded for one serves the other.
    var routeKey: String {
        var parts = [origin.icao, destination.icao]
        switch source {
        case .greatCircle: parts.append("GC")
        case .archive(let day): parts.append("ARCH" + day)
        case .entered: parts.append(contentsOf: legs.map { "\($0.ident)@\($0.latitude),\($0.longitude)" })
        }
        return parts.joined(separator: "|")
    }

    var coordinates: [CLLocationCoordinate2D] { route.map(\.coordinate) }

    var totalDistanceNm: Double { Self.length(of: route) }

    private static func length(of points: [RoutePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + GreatCircle.distanceNm($1.0.coordinate, $1.1.coordinate) }
    }

    /// A typical cruise level for the distance: short hops stay low.
    static func defaultCruiseAltitudeFt(distanceNm: Double) -> Double {
        switch distanceNm {
        case ..<120: return 17_000
        case ..<250: return 25_000
        case ..<450: return 33_000
        case ..<1_500: return 36_000
        default: return 38_000
        }
    }

    // MARK: Along the path

    /// The point `along` NM down the path (clamped to its ends).
    func coordinate(atNm along: Double) -> CLLocationCoordinate2D {
        var remaining = max(0, along)
        for (a, b) in zip(route, route.dropFirst()) {
            let leg = GreatCircle.distanceNm(a.coordinate, b.coordinate)
            if remaining <= leg, leg > 0 {
                return GreatCircle.intermediate(a.coordinate, b.coordinate, fraction: remaining / leg)
            }
            remaining -= leg
        }
        return route.last?.coordinate ?? origin.coordinate
    }

    /// The course along the path at `along` NM, degrees true — taken over
    /// the next two miles so it does not jump at each vertex.
    func course(atNm along: Double) -> Double {
        let total = totalDistanceNm
        let from = min(along, max(0, total - 2))
        return GreatCircle.initialCourse(coordinate(atNm: from), coordinate(atNm: min(total, from + 2)))
    }

    // MARK: Vertical profile

    /// Climb at about 2.2 NM per 1000 ft (2500 ft/min at 330 kt over the
    /// ground), descend on a 3° path (about 3.2 NM per 1000 ft).
    static let climbNmPer1000Ft = 2.2
    static let descentNmPer1000Ft = 3.2

    /// Along-track distances of the top of climb and top of descent. On a
    /// leg too short to reach the cruise level they meet where the climb
    /// and descent lines cross.
    var topOfClimbNm: Double { verticalProfile.toc }
    var topOfDescentNm: Double { verticalProfile.tod }
    /// The level actually reached, lower than `cruiseAltitudeFt` on a short
    /// leg.
    var reachableCruiseFt: Double { verticalProfile.cruise }

    private var verticalProfile: (toc: Double, tod: Double, cruise: Double) {
        let total = totalDistanceNm
        let climbFt = max(0, cruiseAltitudeFt - origin.elevationFt)
        let descentFt = max(0, cruiseAltitudeFt - destination.elevationFt)
        let start = climbStartNm
        let toc = start + climbFt / 1_000 * Self.climbNmPer1000Ft
        let tod = total - descentFt / 1_000 * Self.descentNmPer1000Ft
        if toc <= tod { return (toc, tod, cruiseAltitudeFt) }
        // Lines from both ends: origin + (d-start)/climb, destination + (total-d)/descent.
        let c = Self.climbNmPer1000Ft / 1_000, d = Self.descentNmPer1000Ft / 1_000
        let meet = (total / d + start / c + destination.elevationFt - origin.elevationFt) / (1 / c + 1 / d)
        let level = origin.elevationFt + (meet - start) / c
        return (meet, meet, level)
    }

    /// Where the climb begins: lift-off, at the end of the take-off run
    /// when the runway is known.
    private var climbStartNm: Double { departureRunway?.lengthNm ?? 0 }

    /// Planned altitude at an along-track distance — the flown track's own
    /// altitude where the path came from the archive, else the climb /
    /// cruise / descent profile.
    func plannedAltitudeFt(atNm along: Double) -> Double {
        let p = verticalProfile
        if along <= p.toc {
            return origin.elevationFt + max(0, along - climbStartNm) / Self.climbNmPer1000Ft * 1_000
        }
        if along >= p.tod {
            return destination.elevationFt + (totalDistanceNm - along) / Self.descentNmPer1000Ft * 1_000
        }
        return p.cruise
    }
}
