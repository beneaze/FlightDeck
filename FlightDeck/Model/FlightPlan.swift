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

    init(id: UUID = UUID(), flightNumber: String?, callsign: String?, date: Date,
         origin: Airport, destination: Airport, cruiseAltitudeFt: Double? = nil,
         route: [RoutePoint]? = nil, source: RouteSource = .greatCircle) {
        self.id = id
        self.flightNumber = flightNumber
        self.callsign = callsign
        self.date = date
        self.origin = origin
        self.destination = destination
        let points = route.map(Self.densified)
            ?? GreatCircle.points(from: origin.coordinate, to: destination.coordinate, spacingNm: 5)
                .map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude, altitudeFt: nil) }
        self.route = points
        self.source = route == nil ? .greatCircle : source
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
    var title: String { flightNumber ?? "\(origin.code)–\(destination.code)" }

    /// One line for lists: "SK455  OSL → CPH", or just "OSL → CPH" when the
    /// flight was planned by airports alone.
    var summary: String {
        let pair = "\(origin.code) → \(destination.code)"
        return flightNumber.map { "\($0)  \(pair)" } ?? pair
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
        let toc = climbFt / 1_000 * Self.climbNmPer1000Ft
        let tod = total - descentFt / 1_000 * Self.descentNmPer1000Ft
        if toc <= tod { return (toc, tod, cruiseAltitudeFt) }
        // Lines from both ends: origin + d/climb, destination + (total-d)/descent.
        let c = Self.climbNmPer1000Ft / 1_000, d = Self.descentNmPer1000Ft / 1_000
        let meet = (total / d + destination.elevationFt - origin.elevationFt) / (1 / c + 1 / d)
        let level = origin.elevationFt + meet / c
        return (meet, meet, level)
    }

    /// Planned altitude at an along-track distance — the flown track's own
    /// altitude where the path came from the archive, else the climb /
    /// cruise / descent profile.
    func plannedAltitudeFt(atNm along: Double) -> Double {
        let p = verticalProfile
        if along <= p.toc { return origin.elevationFt + along / Self.climbNmPer1000Ft * 1_000 }
        if along >= p.tod {
            return destination.elevationFt + (totalDistanceNm - along) / Self.descentNmPer1000Ft * 1_000
        }
        return p.cruise
    }
}
