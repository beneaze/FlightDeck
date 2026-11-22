import Foundation
import MapKit
import Combine

/// What the route is planned for. Apple Maps routes cars and bikes
/// differently — a bike is kept off motorways and onto cycle paths — and the
/// Google Maps hand-off follows suit. A plane flies a flight plan instead
/// (see ``FlightPlan``), chosen by flight number or airports.
enum TransportMode: String, CaseIterable {
    case car, bicycle, plane

    var label: String {
        switch self {
        case .car: return "CAR"
        case .bicycle: return "BIKE"
        case .plane: return "PLANE"
        }
    }

    /// Whether routes come from Apple Maps road routing.
    var isRoad: Bool { self != .plane }

    var mapKitType: MKDirectionsTransportType {
        switch self {
        case .car, .plane: return .automobile
        case .bicycle: return .cycling
        }
    }

    /// Google Maps `travelmode` query value; nil where there is no hand-off.
    var googleTravelMode: String? {
        switch self {
        case .car: return "driving"
        case .bicycle: return "bicycling"
        case .plane: return nil
        }
    }
}

/// Plans a "flight plan" style route from the current position to a chosen
/// destination and exposes it, Airbus-style, for the navigation display:
/// named waypoints at each manoeuvre point, an active leg that sequences as
/// waypoints are passed, and distances measured along the route rather than
/// straight through the buildings in between.
///
/// Routing/search use Apple's MapKit (no API key required). The "Open in
/// Google Maps" action hands the same route to the Google Maps app or
/// website. A Google Directions provider could replace ``fly(to:at:from:)``
/// behind the same interface.
@MainActor
final class RoutePlanner: ObservableObject {

    struct Destination: Identifiable {
        let id = UUID()
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    /// A flight-plan waypoint. Each road manoeuvre becomes one; the
    /// destination is the last.
    struct Waypoint {
        /// Airbus-style ident: the road being turned onto when it can be read
        /// from the manoeuvre instruction, else a sequence number.
        let ident: String
        let coordinate: CLLocationCoordinate2D
        /// Position in the route geometry — which vertex the waypoint sits at.
        let routeIndex: Int
    }

    @Published private(set) var destination: Destination?
    @Published private(set) var route: MKRoute?
    @Published private(set) var waypoints: [Waypoint] = []
    /// The TO waypoint — the one currently being flown to.
    @Published private(set) var activeWaypointIndex = 0
    /// The route vertex that starts the leg the aircraft is currently on.
    @Published private(set) var progressIndex = 0
    /// Distance flown along the route, to the aircraft's projection onto the
    /// current leg — continuous, so everything measured from it is too.
    @Published private(set) var alongTrackMeters: Double = 0
    @Published private(set) var isPlanning = false
    /// The flight being flown in plane mode; nil for road routes.
    @Published private(set) var flightPlan: FlightPlan?
    @Published private(set) var errorMessage: String?

    /// Ground elevation along the route — the vertical display's profile.
    /// Fetched once per planned route; nil until it arrives.
    @Published private(set) var elevationProfile: ElevationProfile?
    /// Why there is no profile yet: "LOADING" or "NOT AVAIL" while a route is
    /// active without one; nil otherwise.
    @Published private(set) var elevationStatus: String?

    /// Car, bicycle or plane. Switching between car and bike with a
    /// destination active replans at once; switching to or from plane drops
    /// the route, as a flight plan and a road route have nothing in common.
    @Published var transportMode: TransportMode = .car {
        didSet {
            UserDefaults.standard.set(transportMode.rawValue, forKey: Self.transportModeKey)
            guard transportMode != oldValue else { return }
            if transportMode.isRoad != oldValue.isRoad {
                clearRoute()
            } else if destination != nil {
                Task { await replan() }
            }
        }
    }
    private static let transportModeKey = "routeTransportMode"

    /// The route geometry, one coordinate per polyline vertex.
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    /// The same vertices in map points, for the projection maths.
    private var routeMapPoints: [MKMapPoint] = []
    /// Metres from the start of the route to each vertex.
    private var cumulativeMeters: [Double] = []
    /// How far along the current leg (0…1) the aircraft's projection sits.
    private var progressFraction = 0.0
    /// Where the aircraft last was, for replanning from the present position.
    private var lastKnownPosition: CLLocationCoordinate2D?
    private var elevationTask: Task<Void, Never>?
    /// Bumped on every new plan, so a late elevation response for a route
    /// that has since been replaced is dropped.
    private var routeGeneration = 0

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.transportModeKey),
           let mode = TransportMode(rawValue: raw) {
            transportMode = mode
        }
    }

    var activeWaypoint: Waypoint? {
        waypoints.indices.contains(activeWaypointIndex) ? waypoints[activeWaypointIndex] : nil
    }

    // MARK: - Planning

    /// Plan a route to the chosen destination and adopt it as the flight plan.
    func fly(to name: String, at coordinate: CLLocationCoordinate2D,
             from origin: CLLocationCoordinate2D?) async {
        guard let origin else {
            errorMessage = "No GPS position yet"
            return
        }
        isPlanning = true
        errorMessage = nil
        defer { isPlanning = false }

        let dest = Destination(name: name, coordinate: coordinate)
        do {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            request.transportType = transportMode.mapKitType
            let response = try await MKDirections(request: request).calculate()

            destination = dest
            if let planned = response.routes.first {
                adopt(planned, to: dest)
            } else {
                adoptDirect(to: dest)
            }
        } catch {
            // No route is not a reason to lose the destination — keep it as a
            // direct leg, the way an FMS keeps a DIR TO.
            destination = dest
            adoptDirect(to: dest)
            errorMessage = error.localizedDescription
        }
    }

    /// Re-run the plan to the current destination from where the aircraft is
    /// now — after a change of transport mode.
    func replan() async {
        guard let destination else { return }
        await fly(to: destination.name, at: destination.coordinate, from: lastKnownPosition)
    }

    /// Flatten the route once and derive the waypoint list from its steps.
    private func adopt(_ planned: MKRoute, to dest: Destination) {
        route = planned

        let points = planned.polyline.points()
        let count = planned.polyline.pointCount
        routeMapPoints = (0..<count).map { points[$0] }
        routeCoordinates = routeMapPoints.map(\.coordinate)
        cumulativeMeters = [0]
        cumulativeMeters.reserveCapacity(count)
        for i in 1..<count {
            cumulativeMeters.append(cumulativeMeters[i - 1] + points[i].distance(to: points[i - 1]))
        }

        // One waypoint per manoeuvre: each step after the first begins where
        // its instruction happens. Manoeuvres bunched within 400 m of each
        // other along the route — ramp and slip-road sequences — merge into
        // their final turn, or the plan would print as a pile of idents.
        var plan: [Waypoint] = []
        for (number, step) in planned.steps.dropFirst().enumerated() {
            guard step.polyline.pointCount > 0 else { continue }
            let at = step.polyline.points()[0]
            let waypoint = Waypoint(ident: Self.ident(fromInstruction: step.instructions,
                                                      number: number + 1),
                                    coordinate: at.coordinate,
                                    routeIndex: nearestVertex(to: at))
            if let previous = plan.last,
               cumulativeMeters[waypoint.routeIndex] - cumulativeMeters[previous.routeIndex] < 400 {
                plan[plan.count - 1] = waypoint
            } else {
                plan.append(waypoint)
            }
        }
        // The destination closes the plan, absorbing any last-metres turn.
        if let last = plan.last,
           cumulativeMeters[count - 1] - cumulativeMeters[last.routeIndex] < 400 {
            plan.removeLast()
        }
        plan.append(Waypoint(ident: Self.ident(fromName: dest.name),
                             coordinate: dest.coordinate,
                             routeIndex: count - 1))
        waypoints = plan
        activeWaypointIndex = 0
        progressIndex = 0
        progressFraction = 0
        alongTrackMeters = 0
        loadElevationProfile()
    }

    // MARK: - Flight plans

    /// Adopt a flight plan as the route: its path becomes the route geometry,
    /// so sequencing, distances, guidance and the ND drawing all work as for
    /// a road route. The waypoints are the airliner's own: top of climb, top
    /// of descent and the destination airport. The VD in plane mode plots
    /// the terrain along the track from the flight pack instead of a route
    /// profile, so none is loaded here.
    func adopt(flightPlan plan: FlightPlan) {
        guard plan.route.count > 1 else { return }
        dropElevationProfile()
        flightPlan = plan
        route = nil
        destination = Destination(name: plan.destination.code, coordinate: plan.destination.coordinate)
        errorMessage = nil

        routeCoordinates = plan.coordinates
        routeMapPoints = routeCoordinates.map(MKMapPoint.init)
        cumulativeMeters = [0]
        for i in 1..<routeCoordinates.count {
            cumulativeMeters.append(cumulativeMeters[i - 1]
                + GreatCircle.distanceNm(routeCoordinates[i - 1], routeCoordinates[i]) * 1852)
        }

        func vertex(atNm nm: Double) -> Int {
            let meters = nm * 1852
            return cumulativeMeters.firstIndex { $0 >= meters } ?? cumulativeMeters.count - 1
        }
        let last = routeCoordinates.count - 1
        var plan_: [Waypoint] = []
        let toc = vertex(atNm: plan.topOfClimbNm), tod = vertex(atNm: plan.topOfDescentNm)
        if toc > 0, toc < last { plan_.append(Waypoint(ident: "T/C", coordinate: routeCoordinates[toc], routeIndex: toc)) }
        if tod > toc, tod < last { plan_.append(Waypoint(ident: "T/D", coordinate: routeCoordinates[tod], routeIndex: tod)) }
        plan_.append(Waypoint(ident: plan.destination.icao, coordinate: plan.destination.coordinate,
                              routeIndex: last))
        waypoints = plan_
        activeWaypointIndex = 0
        progressIndex = 0
        progressFraction = 0
        alongTrackMeters = 0
    }

    /// Distance flown along the flight plan, in nautical miles.
    var alongTrackNm: Double { alongTrackMeters / 1852 }

    /// No road route: the destination itself is the only waypoint.
    private func adoptDirect(to dest: Destination) {
        route = nil
        routeCoordinates = []
        routeMapPoints = []
        cumulativeMeters = []
        waypoints = [Waypoint(ident: Self.ident(fromName: dest.name),
                              coordinate: dest.coordinate, routeIndex: 0)]
        activeWaypointIndex = 0
        progressIndex = 0
        progressFraction = 0
        alongTrackMeters = 0
        dropElevationProfile()
    }

    func clearRoute() {
        destination = nil
        flightPlan = nil
        route = nil
        waypoints = []
        routeCoordinates = []
        routeMapPoints = []
        cumulativeMeters = []
        activeWaypointIndex = 0
        progressIndex = 0
        progressFraction = 0
        alongTrackMeters = 0
        errorMessage = nil
        dropElevationProfile()
    }

    // MARK: - Elevation profile

    /// Sample the route at even along-track intervals — fine enough that a
    /// street-scale range still shows the next rise, coarse enough that a
    /// long motorway route stays within a handful of requests — and look the
    /// ground elevation up for every sample.
    private func loadElevationProfile() {
        dropElevationProfile()
        guard let total = cumulativeMeters.last, total > 0 else { return }

        routeGeneration += 1
        let generation = routeGeneration
        let spacing = (total / 400).clamped(to: 50...500)
        var positions = Array(stride(from: 0, to: total, by: spacing))
        positions.append(total)
        let coordinates = positions.map { coordinate(atMeters: $0) }

        elevationStatus = "LOADING"
        elevationTask = Task { [weak self] in
            do {
                let meters = try await ElevationService.elevationsMeters(for: coordinates)
                guard let self, self.routeGeneration == generation else { return }
                self.elevationProfile = ElevationProfile(
                    samples: zip(positions, meters).map {
                        ElevationProfile.Sample(alongMeters: $0, elevationFt: $1 * 3.28084)
                    })
                self.elevationStatus = nil
            } catch is CancellationError {
                // Superseded by a newer plan.
            } catch {
                guard let self, self.routeGeneration == generation else { return }
                self.elevationStatus = "NOT AVAIL"
            }
        }
    }

    private func dropElevationProfile() {
        elevationTask?.cancel()
        elevationTask = nil
        elevationProfile = nil
        elevationStatus = nil
    }

    /// The point on the route a given distance from its start.
    private func coordinate(atMeters meters: Double) -> CLLocationCoordinate2D {
        guard routeCoordinates.count > 1 else { return routeCoordinates.first ?? CLLocationCoordinate2D() }
        var low = 0, high = cumulativeMeters.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if cumulativeMeters[mid] <= meters { low = mid } else { high = mid }
        }
        let legStart = cumulativeMeters[low], legEnd = cumulativeMeters[high]
        let t = legEnd > legStart ? ((meters - legStart) / (legEnd - legStart)).clamped(to: 0...1) : 0
        return Self.interpolate(routeCoordinates[low], routeCoordinates[high], t)
    }

    // MARK: - Sequencing

    /// Advance the plan as the aircraft moves — called on every position
    /// update, sixty times a second. Projects the aircraft onto the nearest
    /// leg (searching locally first, the whole route only when far off it,
    /// since routes can pass near themselves), which gives a continuous
    /// along-track distance, and sequences the TO waypoint to the first one
    /// still ahead. Cheap enough to run at the display rate: a few hundred
    /// point-to-segment distances.
    func updateProgress(location: CLLocation?) {
        guard let location else { return }
        lastKnownPosition = location.coordinate
        guard routeMapPoints.count > 1 else { return }

        let here = MKMapPoint(location.coordinate)
        let lastLeg = routeMapPoints.count - 1
        let window = max(0, progressIndex - 25)..<min(lastLeg, progressIndex + 400)
        var best = nearestLeg(to: here, in: window)
        if best.meters > 500 {
            best = nearestLeg(to: here, in: 0..<lastLeg)
        }

        if best.index != progressIndex { progressIndex = best.index }
        progressFraction = best.fraction
        let along = cumulativeMeters[best.index]
            + best.fraction * (cumulativeMeters[best.index + 1] - cumulativeMeters[best.index])
        if along != alongTrackMeters { alongTrackMeters = along }

        let next = waypoints.firstIndex { $0.routeIndex > best.index }
            ?? max(waypoints.count - 1, 0)
        if next != activeWaypointIndex { activeWaypointIndex = next }
    }

    /// The leg (vertex `index` to `index + 1`) nearest to a point, where along
    /// it the projection falls, and how far off it the point is.
    private func nearestLeg(to point: MKMapPoint,
                            in legs: Range<Int>) -> (index: Int, fraction: Double, meters: Double) {
        let metersPerPoint = MKMetersPerMapPointAtLatitude(point.coordinate.latitude)
        var best = (index: legs.lowerBound, fraction: 0.0, meters: Double.greatestFiniteMagnitude)
        for i in legs {
            let a = routeMapPoints[i], b = routeMapPoints[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            var t = 0.0
            if length2 > 0 {
                t = (((point.x - a.x) * dx + (point.y - a.y) * dy) / length2).clamped(to: 0...1)
            }
            let ox = a.x + t * dx - point.x, oy = a.y + t * dy - point.y
            let meters = (ox * ox + oy * oy).squareRoot() * metersPerPoint
            if meters < best.meters {
                best = (i, t, meters)
            }
        }
        return best
    }

    private func nearestVertex(to point: MKMapPoint) -> Int {
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, vertex) in routeMapPoints.enumerated() {
            let distance = point.distance(to: vertex)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// The aircraft's projection onto the current leg.
    private var projectedCoordinate: CLLocationCoordinate2D? {
        guard routeCoordinates.count > progressIndex + 1 else { return nil }
        return Self.interpolate(routeCoordinates[progressIndex],
                                routeCoordinates[progressIndex + 1],
                                progressFraction)
    }

    private static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                                    _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    // MARK: - Distances

    /// Distance to run to the destination, in nautical miles — along the
    /// route when one exists, great-circle otherwise.
    func distanceToGoNm(from location: CLLocation?) -> Double? {
        guard destination != nil else { return nil }
        if let along = alongRouteNm(toVertex: routeCoordinates.count - 1) {
            return along
        }
        guard let destination, let location else { return nil }
        return location.distance(from: CLLocation(latitude: destination.coordinate.latitude,
                                                  longitude: destination.coordinate.longitude)) / 1852
    }

    /// Distance to a waypoint, along the route when possible.
    func distanceNm(to waypoint: Waypoint, from location: CLLocation?) -> Double? {
        if let along = alongRouteNm(toVertex: waypoint.routeIndex) {
            return along
        }
        guard let location else { return nil }
        return location.distance(from: CLLocation(latitude: waypoint.coordinate.latitude,
                                                  longitude: waypoint.coordinate.longitude)) / 1852
    }

    private func alongRouteNm(toVertex: Int) -> Double? {
        guard cumulativeMeters.count > 1, cumulativeMeters.indices.contains(toVertex) else { return nil }
        return max(0, cumulativeMeters[toVertex] - alongTrackMeters) / 1852
    }

    /// Point on the flight plan the flight director should steer toward: the
    /// spot on the route `lookaheadMeters` ahead of the aircraft's projection,
    /// interpolated along the leg it falls on so the guidance slides along the
    /// planned path and leads its turns — or the destination itself on a
    /// direct-to leg.
    func guidanceTargetCoordinate(lookaheadMeters: Double) -> CLLocationCoordinate2D? {
        guard routeCoordinates.count > 1, cumulativeMeters.indices.contains(progressIndex + 1)
        else { return destination?.coordinate }

        let target = alongTrackMeters + lookaheadMeters
        var index = progressIndex
        while index < routeCoordinates.count - 2, cumulativeMeters[index + 1] < target {
            index += 1
        }
        let legStart = cumulativeMeters[index], legEnd = cumulativeMeters[index + 1]
        let t = legEnd > legStart ? ((target - legStart) / (legEnd - legStart)).clamped(to: 0...1) : 1
        return Self.interpolate(routeCoordinates[index], routeCoordinates[index + 1], t)
    }

    /// Estimated time enroute based on current ground speed, in seconds.
    func timeEnroute(from location: CLLocation?, groundSpeedKts: Double) -> TimeInterval? {
        guard let nm = distanceToGoNm(from: location), groundSpeedKts > 10 else { return nil }
        return nm / groundSpeedKts * 3600
    }

    /// The not-yet-flown route geometry, decimated for drawing — a driving
    /// route can carry thousands of vertices, far more than the ND can
    /// resolve. It starts at the aircraft's projection onto the current leg,
    /// so the flown part disappears continuously behind the aircraft symbol.
    /// The vertices just ahead are kept verbatim: at street-scale ranges the
    /// next corner must keep its exact shape, while the far end of the route
    /// can afford to be coarse.
    func remainingRouteCoordinates(maximumCount: Int) -> [CLLocationCoordinate2D] {
        guard let start = projectedCoordinate else { return [] }
        let remaining = [start] + Array(routeCoordinates[(progressIndex + 1)...])

        let nearCount = Swift.min(remaining.count, maximumCount / 2)
        var result = Array(remaining.prefix(nearCount))

        let tail = Array(remaining.dropFirst(nearCount))
        if !tail.isEmpty {
            let step = Swift.max(1, tail.count / (maximumCount / 2))
            result.append(contentsOf: stride(from: 0, to: tail.count, by: step).map { tail[$0] })
            if let last = tail.last { result.append(last) }
        }
        return result
    }

    // MARK: - Idents

    private static func ident(fromName name: String) -> String {
        let cleaned = name.uppercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "DEST" : String(cleaned.prefix(7))
    }

    private static func ident(fromInstruction instruction: String, number: Int) -> String {
        for marker in [" onto ", " toward ", " on "] {
            if let range = instruction.range(of: marker, options: .caseInsensitive) {
                let cleaned = instruction[range.upperBound...].uppercased()
                    .filter { $0.isLetter || $0.isNumber }
                if cleaned.count >= 2 { return String(cleaned.prefix(7)) }
            }
        }
        return String(format: "WP%02d", number)
    }

    // MARK: - Google Maps hand-off

    /// URL that opens this route in Google Maps (app if installed, web otherwise).
    func googleMapsURL(from origin: CLLocationCoordinate2D?) -> URL? {
        guard let destination, transportMode.isRoad else { return nil }
        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [URLQueryItem(name: "api", value: "1"),
                     URLQueryItem(name: "destination",
                                  value: "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"),
                     URLQueryItem(name: "travelmode", value: transportMode.googleTravelMode ?? "driving")]
        if let origin {
            items.append(URLQueryItem(name: "origin",
                                      value: "\(origin.latitude),\(origin.longitude)"))
        }
        components.queryItems = items
        return components.url
    }
}
