import Foundation
import MapKit
import Combine

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
    /// The route vertex the aircraft is currently abeam.
    @Published private(set) var progressIndex = 0
    @Published private(set) var isPlanning = false
    @Published private(set) var errorMessage: String?

    /// The route geometry, one coordinate per polyline vertex.
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    /// Metres from the start of the route to each vertex.
    private var cumulativeMeters: [Double] = []
    private var lastProgressUpdate = Date.distantPast

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
            request.transportType = .automobile
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

    /// Flatten the route once and derive the waypoint list from its steps.
    private func adopt(_ planned: MKRoute, to dest: Destination) {
        route = planned

        let points = planned.polyline.points()
        let count = planned.polyline.pointCount
        routeCoordinates = (0..<count).map { points[$0].coordinate }
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
                                    routeIndex: nearestVertex(to: at, in: 0..<count).index)
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
    }

    /// No road route: the destination itself is the only waypoint.
    private func adoptDirect(to dest: Destination) {
        route = nil
        routeCoordinates = []
        cumulativeMeters = []
        waypoints = [Waypoint(ident: Self.ident(fromName: dest.name),
                              coordinate: dest.coordinate, routeIndex: 0)]
        activeWaypointIndex = 0
        progressIndex = 0
    }

    func clearRoute() {
        destination = nil
        route = nil
        waypoints = []
        routeCoordinates = []
        cumulativeMeters = []
        activeWaypointIndex = 0
        progressIndex = 0
        errorMessage = nil
    }

    // MARK: - Sequencing

    /// Advance the plan as the aircraft moves — called on each GPS fix.
    /// Snaps to the nearest route vertex (searching locally first, the whole
    /// route only when far off it, since routes can pass near themselves) and
    /// sequences the TO waypoint to the first one still ahead.
    func updateProgress(location: CLLocation?) {
        guard let location, routeCoordinates.count > 1 else { return }
        guard Date().timeIntervalSince(lastProgressUpdate) > 1 else { return }
        lastProgressUpdate = Date()

        let here = MKMapPoint(location.coordinate)
        let window = max(0, progressIndex - 25)..<min(routeCoordinates.count, progressIndex + 400)
        var best = nearestVertex(to: here, in: window)
        if best.meters > 500 {
            best = nearestVertex(to: here, in: 0..<routeCoordinates.count)
        }

        if best.index != progressIndex { progressIndex = best.index }
        let next = waypoints.firstIndex { $0.routeIndex > best.index }
            ?? max(waypoints.count - 1, 0)
        if next != activeWaypointIndex { activeWaypointIndex = next }
    }

    private func nearestVertex(to point: MKMapPoint, in range: Range<Int>) -> (index: Int, meters: Double) {
        var bestIndex = range.lowerBound
        var bestMeters = Double.greatestFiniteMagnitude
        for i in range {
            let meters = point.distance(to: MKMapPoint(routeCoordinates[i]))
            if meters < bestMeters {
                bestMeters = meters
                bestIndex = i
            }
        }
        return (bestIndex, bestMeters)
    }

    // MARK: - Distances

    /// Distance to run to the destination, in nautical miles — along the
    /// route when one exists, great-circle otherwise.
    func distanceToGoNm(from location: CLLocation?) -> Double? {
        guard destination != nil else { return nil }
        if let along = alongRouteNm(toVertex: routeCoordinates.count - 1, from: location) {
            return along
        }
        guard let destination, let location else { return nil }
        return location.distance(from: CLLocation(latitude: destination.coordinate.latitude,
                                                  longitude: destination.coordinate.longitude)) / 1852
    }

    /// Distance to a waypoint, along the route when possible.
    func distanceNm(to waypoint: Waypoint, from location: CLLocation?) -> Double? {
        if let along = alongRouteNm(toVertex: waypoint.routeIndex, from: location) {
            return along
        }
        guard let location else { return nil }
        return location.distance(from: CLLocation(latitude: waypoint.coordinate.latitude,
                                                  longitude: waypoint.coordinate.longitude)) / 1852
    }

    private func alongRouteNm(toVertex: Int, from location: CLLocation?) -> Double? {
        guard route != nil, cumulativeMeters.indices.contains(toVertex),
              cumulativeMeters.indices.contains(progressIndex) else { return nil }
        var meters = cumulativeMeters[toVertex] - cumulativeMeters[progressIndex]
        // The aircraft is usually somewhere short of the vertex it snapped to.
        if let location {
            let snapped = routeCoordinates[progressIndex]
            meters += location.distance(from: CLLocation(latitude: snapped.latitude,
                                                         longitude: snapped.longitude))
        }
        return max(0, meters) / 1852
    }

    /// Point on the flight plan the flight director should steer toward: a
    /// spot on the route `lookaheadMeters` ahead of the aircraft, so the
    /// guidance follows the planned path and leads its turns — or the
    /// destination itself on a direct-to leg.
    func guidanceTargetCoordinate(lookaheadMeters: Double) -> CLLocationCoordinate2D? {
        if routeCoordinates.count > 1, cumulativeMeters.indices.contains(progressIndex) {
            let target = cumulativeMeters[progressIndex] + lookaheadMeters
            var index = progressIndex
            while index < routeCoordinates.count - 1, cumulativeMeters[index] < target {
                index += 1
            }
            return routeCoordinates[index]
        }
        return destination?.coordinate
    }

    /// Estimated time enroute based on current ground speed, in seconds.
    func timeEnroute(from location: CLLocation?, groundSpeedKts: Double) -> TimeInterval? {
        guard let nm = distanceToGoNm(from: location), groundSpeedKts > 10 else { return nil }
        return nm / groundSpeedKts * 3600
    }

    /// The not-yet-flown route geometry, decimated for drawing — a driving
    /// route can carry thousands of vertices, far more than the ND can
    /// resolve. The vertices just ahead are kept verbatim: at street-scale
    /// ranges the next corner must keep its exact shape, while the far end of
    /// the route can afford to be coarse.
    func remainingRouteCoordinates(maximumCount: Int) -> [CLLocationCoordinate2D] {
        guard routeCoordinates.count > progressIndex + 1 else { return [] }
        let remaining = Array(routeCoordinates[progressIndex...])

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
        guard let destination else { return nil }
        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [URLQueryItem(name: "api", value: "1"),
                     URLQueryItem(name: "destination",
                                  value: "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"),
                     URLQueryItem(name: "travelmode", value: "driving")]
        if let origin {
            items.append(URLQueryItem(name: "origin",
                                      value: "\(origin.latitude),\(origin.longitude)"))
        }
        components.queryItems = items
        return components.url
    }
}
