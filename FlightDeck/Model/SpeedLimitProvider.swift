import Foundation
import CoreLocation
import Combine

/// The posted speed limit of the road being driven, looked up from
/// OpenStreetMap through the Overpass API — the one source that needs no API
/// key; MapKit carries no speed-limit data. On the PFD the limit plays the
/// part of VMAX: the red barber pole on the speed tape starts at it.
///
/// Roads tagged with a limit within a few hundred metres of the aircraft are
/// fetched in one request and cached; each GPS fix is then matched against
/// the cache locally, so the network sees one request per few hundred metres
/// of travel. The road is chosen by distance from the fix, tie-broken by how
/// well its direction agrees with the track — at a junction the cross street
/// is just as close, but runs the wrong way.
///
/// Road data © OpenStreetMap contributors, ODbL.
@MainActor
final class SpeedLimitProvider: ObservableObject {

    /// Lookups can be switched off — they send the position to a third-party
    /// server (overpass-api.de).
    @Published var isEnabled = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            clear()
        }
    }
    private static let enabledKey = "speedLimitLookupEnabled"

    /// Limit on the current road, in knots; nil when no road with a posted
    /// limit is matched (or the road is unrestricted).
    @Published private(set) var limitKts: Double?
    /// The matched road is explicitly unrestricted (`maxspeed=none` — an
    /// autobahn).
    @Published private(set) var isUnrestricted = false
    /// Name (or ref) of the matched road, for the menu.
    @Published private(set) var roadName: String?
    /// One-line state of the data source, for the menu.
    @Published private(set) var status = "STANDBY"

    /// What a `maxspeed` tag resolved to.
    enum Limit: Equatable {
        case limit(kts: Double)
        case unrestricted
    }

    private struct Way {
        let id: Int
        let tags: [String: String]
        let points: [CLLocationCoordinate2D]
    }

    private var ways: [Way] = []
    private var fetchCenter: CLLocationCoordinate2D?
    private var fetchDate = Date.distantPast
    private var lastRequestDate = Date.distantPast
    private var retryAfter = Date.distantPast
    private var fetchTask: Task<Void, Never>?
    private var lastMatchDate = Date.distantPast
    private var matchedWayID: Int?

    /// Radius of roads fetched around the fix; a new fetch is made once the
    /// aircraft is `refetchDistanceMeters` from the last fetch's centre.
    private static let fetchRadiusMeters = 600.0
    private static let refetchDistanceMeters = 350.0
    private static let minimumRequestInterval: TimeInterval = 5
    private static let cacheLifetime: TimeInterval = 600
    /// A road further off than this is not the one being driven.
    private static let maximumMatchMeters = 40.0
    /// Weight of a 90° misalignment between track and road, in metres of
    /// distance — enough to lose against the road being driven, not enough
    /// to pick a parallel street two lanes over.
    private static let misalignmentPenaltyMeters = 40.0
    /// A road keeps its match while it scores within this of the best — so
    /// two candidates at a junction do not flicker.
    private static let stickinessMeters = 8.0
    /// A lost match is held this long before the limit is dropped, so a
    /// junction or a GPS wobble does not blank the pole.
    private static let matchHold: TimeInterval = 6
    private nonisolated static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) != nil {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        status = isEnabled ? "STANDBY" : "OFF"
    }

    /// Feed each GPS fix — not the smoothed display position: matching is
    /// against measurements, and once a second is plenty.
    func update(fix: CLLocation?, trackDeg: Double) {
        guard isEnabled, let fix else { return }
        match(at: fix.coordinate, trackDeg: trackDeg)
        fetchIfNeeded(around: fix.coordinate)
    }

    /// Forget the current limit and stop matching until the next fix — for
    /// plane mode, where road limits mean nothing and no position should be
    /// sent to OpenStreetMap.
    func pause() {
        clear()
    }

    private func clear() {
        limitKts = nil
        isUnrestricted = false
        roadName = nil
        matchedWayID = nil
        status = isEnabled ? "STANDBY" : "OFF"
    }

    // MARK: - Matching

    private func match(at position: CLLocationCoordinate2D, trackDeg: Double) {
        guard !ways.isEmpty else { return }

        // Local flat-earth metres about the fix.
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(position.latitude * .pi / 180)
        func local(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - position.longitude) * metersPerDegreeLon,
             (c.latitude - position.latitude) * metersPerDegreeLat)
        }

        // Each way's best leg: how far off it the fix is, penalised by how far
        // the track is from running along it, and which way along it we go.
        var candidates: [(way: Way, score: Double, forward: Bool)] = []
        for way in ways where way.points.count > 1 {
            var best: (score: Double, forward: Bool)?
            for i in 0..<(way.points.count - 1) {
                let a = local(way.points[i]), b = local(way.points[i + 1])
                let dx = b.x - a.x, dy = b.y - a.y
                let length2 = dx * dx + dy * dy
                guard length2 > 0 else { continue }
                let t = (-(a.x * dx + a.y * dy) / length2).clamped(to: 0...1)
                let px = a.x + t * dx, py = a.y + t * dy
                let meters = (px * px + py * py).squareRoot()
                guard meters < Self.maximumMatchMeters else { continue }

                let legBearing = atan2(dx, dy) * 180 / .pi
                let along = angularDifference(trackDeg, legBearing)
                let misalignment = min(abs(along), 180 - abs(along))        // 0…90
                let score = meters + Self.misalignmentPenaltyMeters * misalignment / 90
                if best == nil || score < best!.score {
                    best = (score, abs(along) < 90)
                }
            }
            if let best { candidates.append((way, best.score, best.forward)) }
        }

        guard var chosen = candidates.min(by: { $0.score < $1.score }) else {
            lostMatch()
            return
        }
        if let current = matchedWayID,
           let held = candidates.first(where: { $0.way.id == current }),
           held.score < chosen.score + Self.stickinessMeters {
            chosen = held
        }

        let tags = chosen.way.tags
        let raw = (chosen.forward ? tags["maxspeed:forward"] : tags["maxspeed:backward"])
            ?? tags["maxspeed"]
        guard let raw, let limit = Self.parse(maxspeed: raw) else {
            lostMatch()
            return
        }

        lastMatchDate = Date()
        matchedWayID = chosen.way.id
        roadName = tags["name"] ?? tags["ref"]
        switch limit {
        case .limit(let kts):
            limitKts = kts
            isUnrestricted = false
        case .unrestricted:
            limitKts = nil
            isUnrestricted = true
        }
    }

    private func lostMatch() {
        guard Date().timeIntervalSince(lastMatchDate) > Self.matchHold else { return }
        limitKts = nil
        isUnrestricted = false
        roadName = nil
        matchedWayID = nil
    }

    // MARK: - Tag parsing

    /// OSM `maxspeed` values: a bare number is km/h; "30 mph" carries its
    /// unit; "none" is an unrestricted road; zone codes such as "DE:urban"
    /// stand for a country's implicit limit. Anything else — "signals",
    /// "variable", "walk" — gives no usable limit.
    static func parse(maxspeed raw: String) -> Limit? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" { return .unrestricted }
        if let number = Double(value) { return kmh(number) }

        let parts = value.split(separator: " ")
        if parts.count == 2, let number = Double(parts[0]) {
            switch parts[1] {
            case "mph": return mph(number)
            case "km/h", "kmh", "kph": return kmh(number)
            case "knots", "kt": return .limit(kts: number)
            default: return nil
            }
        }

        if let zone = zoneLimits[value] { return zone }
        // Generic zone codes: "xx:urban" is 50 km/h nearly everywhere;
        // "xx:zone30" / "xx:zone:30" spell out their own number.
        if value.hasSuffix(":urban") { return kmh(50) }
        if let range = value.range(of: ":zone:?", options: .regularExpression),
           let number = Double(value[range.upperBound...]) {
            return kmh(number)
        }
        return nil
    }

    private static func kmh(_ value: Double) -> Limit { .limit(kts: value / 1.852) }
    private static func mph(_ value: Double) -> Limit { .limit(kts: value / 1.150779) }

    /// Implicit limits behind the commonest zone codes.
    private static let zoneLimits: [String: Limit] = [
        "de:urban": kmh(50), "de:rural": kmh(100), "de:motorway": .unrestricted,
        "de:living_street": kmh(7), "de:bicycle_road": kmh(30),
        "at:urban": kmh(50), "at:rural": kmh(100), "at:motorway": kmh(130),
        "ch:urban": kmh(50), "ch:rural": kmh(80), "ch:motorway": kmh(120),
        "fr:urban": kmh(50), "fr:rural": kmh(80), "fr:motorway": kmh(130),
        "it:urban": kmh(50), "it:rural": kmh(90), "it:motorway": kmh(130),
        "nl:urban": kmh(50), "nl:rural": kmh(80), "nl:motorway": kmh(100),
        "be:urban": kmh(50), "be:rural": kmh(70), "be:motorway": kmh(120),
        "es:urban": kmh(50), "es:rural": kmh(90), "es:motorway": kmh(120),
        "gb:nsl_single": mph(60), "gb:nsl_dual": mph(70), "gb:motorway": mph(70),
    ]

    // MARK: - Fetching

    private func fetchIfNeeded(around position: CLLocationCoordinate2D) {
        guard fetchTask == nil else { return }
        let now = Date()
        guard now >= retryAfter,
              now.timeIntervalSince(lastRequestDate) >= Self.minimumRequestInterval else { return }
        if let center = fetchCenter,
           now.timeIntervalSince(fetchDate) < Self.cacheLifetime,
           Self.distanceMeters(center, position) < Self.refetchDistanceMeters {
            return
        }

        lastRequestDate = now
        if ways.isEmpty { status = "OSM: QUERY" }
        fetchTask = Task { [weak self] in
            defer { self?.fetchTask = nil }
            do {
                let fetched = try await Self.fetchWays(around: position,
                                                       radiusMeters: Self.fetchRadiusMeters)
                guard let self else { return }
                self.ways = fetched
                self.fetchCenter = position
                self.fetchDate = Date()
                self.status = fetched.isEmpty ? "OSM: NO LIMITS NEARBY" : "OSM: \(fetched.count) ROADS"
            } catch {
                guard let self else { return }
                self.status = "OSM: UNAVAILABLE"
                self.retryAfter = Date().addingTimeInterval(30)
            }
        }
    }

    private struct OverpassResponse: Decodable {
        struct Element: Decodable {
            let type: String
            let id: Int
            let tags: [String: String]?
            let geometry: [Node]?
        }
        struct Node: Decodable {
            let lat: Double
            let lon: Double
        }
        let elements: [Element]
    }

    /// Every highway within `radiusMeters` carrying any `maxspeed*` tag, with
    /// its geometry.
    private nonisolated static func fetchWays(around c: CLLocationCoordinate2D,
                                              radiusMeters: Double) async throws -> [Way] {
        let query = """
        [out:json][timeout:10];
        way(around:\(Int(radiusMeters)),\(c.latitude),\(c.longitude))["highway"][~"^maxspeed"~"."];
        out tags geom;
        """
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("CockpitView/1.0 (iOS; A320 EFIS for the road)", forHTTPHeaderField: "User-Agent")
        request.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return decoded.elements.compactMap { element in
            guard element.type == "way", let geometry = element.geometry, geometry.count > 1
            else { return nil }
            return Way(id: element.id, tags: element.tags ?? [:],
                       points: geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        }
    }

    private static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
