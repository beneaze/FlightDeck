import Foundation
import CoreLocation

/// A runway end from the bundled database (OurAirports, public domain).
struct Runway: Codable, Hashable {
    /// "26R", "08", …
    let ident: String
    let latitude: Double
    let longitude: Double
    let elevationFt: Double?
    /// Runway direction, degrees true.
    let headingDeg: Double
    let lengthFt: Double
    let displacedThresholdFt: Double

    /// The runway end.
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// Where landing aircraft cross the threshold — past a displaced one.
    var threshold: CLLocationCoordinate2D {
        guard displacedThresholdFt > 0 else { return coordinate }
        return GreatCircle.destination(from: coordinate, courseDeg: headingDeg,
                                       distanceNm: displacedThresholdFt / 6_076)
    }

    var lengthNm: Double { lengthFt / 6_076 }
    /// "06L" for a runway the source spells "6L": procedures and the
    /// units always use two digits.
    var designator: String { Self.designator(ident) }
    /// "RW26R", the way flight plans name runways.
    var fixIdent: String { "RW" + designator }

    static func designator(_ ident: String) -> String {
        let digits = ident.prefix { $0.isNumber }
        guard digits.count == 1 else { return ident }
        return "0" + ident
    }
}

/// A radio navaid from the bundled database (OurAirports, public domain).
struct Navaid: Hashable {
    enum Kind: String {
        case vor = "V", vorDme = "VD", vortac = "VT", tacan = "T", ndb = "N", ndbDme = "ND", dme = "D"

        var label: String {
            switch self {
            case .vor: return "VOR"
            case .vorDme: return "VOR/DME"
            case .vortac: return "VORTAC"
            case .tacan: return "TACAN"
            case .ndb: return "NDB"
            case .ndbDme: return "NDB/DME"
            case .dme: return "DME"
            }
        }
    }

    let ident: String
    let name: String
    let kind: Kind
    let latitude: Double
    let longitude: Double
    let frequencyKhz: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// "117.15" for a VOR, "373" for an NDB.
    var frequencyText: String {
        switch kind {
        case .ndb, .ndbDme: return String(Int(frequencyKhz))
        default: return String(format: "%.2f", frequencyKhz / 1_000)
        }
    }
}

/// Runways and navaids, always available offline. Built by
/// Tools/BuildAirports from OurAirports.
///
/// There is no free worldwide source of the published procedures (SIDs,
/// STARs, approaches) or of named airway points, so departures and
/// approaches are built from the runway itself — see ``FlightPlan``.
final class NavDatabase: @unchecked Sendable {
    static let shared = NavDatabase()

    private let runwaysByAirport: [String: [Runway]]
    private let navaidsByIdent: [String: [Navaid]]

    private init() {
        var runways: [String: [Runway]] = [:]
        if let url = Bundle.main.url(forResource: "runways", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let table = try? JSONSerialization.jsonObject(with: data) as? [String: [[Any]]] {
            for (code, ends) in table {
                runways[code] = ends.compactMap { e in
                    guard e.count >= 7, let ident = e[0] as? String,
                          let lat = (e[1] as? NSNumber)?.doubleValue,
                          let lon = (e[2] as? NSNumber)?.doubleValue,
                          let heading = (e[4] as? NSNumber)?.doubleValue else { return nil }
                    return Runway(ident: ident, latitude: lat, longitude: lon,
                                  elevationFt: (e[3] as? NSNumber)?.doubleValue,
                                  headingDeg: heading,
                                  lengthFt: (e[5] as? NSNumber)?.doubleValue ?? 0,
                                  displacedThresholdFt: (e[6] as? NSNumber)?.doubleValue ?? 0)
                }
            }
        }
        runwaysByAirport = runways

        var navaids: [String: [Navaid]] = [:]
        if let url = Bundle.main.url(forResource: "navaids", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] {
            for r in rows {
                guard r.count >= 6, let ident = r[0] as? String, let name = r[1] as? String,
                      let kind = (r[2] as? String).flatMap(Navaid.Kind.init),
                      let lat = (r[3] as? NSNumber)?.doubleValue,
                      let lon = (r[4] as? NSNumber)?.doubleValue else { continue }
                navaids[ident, default: []].append(
                    Navaid(ident: ident, name: name, kind: kind, latitude: lat, longitude: lon,
                           frequencyKhz: (r[5] as? NSNumber)?.doubleValue ?? 0))
            }
        }
        navaidsByIdent = navaids
    }

    /// The runway ends of an airport, longest runways first.
    func runways(at airport: Airport) -> [Runway] {
        let ends: [Runway] = runwaysByAirport[airport.icao] ?? []
        return ends.sorted { (a: Runway, b: Runway) -> Bool in
            if a.lengthFt != b.lengthFt { return a.lengthFt > b.lengthFt }
            return a.ident < b.ident
        }
    }

    func runway(_ ident: String, at airport: Airport) -> Runway? {
        let wanted = Runway.designator(ident.uppercased().replacingOccurrences(of: "RW", with: ""))
        return runwaysByAirport[airport.icao]?.first { $0.designator == wanted }
    }

    /// Every navaid with this ident, nearest to `reference` first.
    func navaids(_ ident: String, near reference: CLLocationCoordinate2D?) -> [Navaid] {
        let all = navaidsByIdent[ident.uppercased()] ?? []
        guard let reference else { return all }
        return all.sorted {
            GreatCircle.distanceNm(reference, $0.coordinate) < GreatCircle.distanceNm(reference, $1.coordinate)
        }
    }

    // MARK: Entries

    /// Turn a scratchpad entry into a flight-plan point:
    /// - a latitude/longitude, Airbus style `4830.5N/01145.2E` or `4830N/01145E`,
    ///   or Boeing style `N4830.5E01145.2`
    /// - a navaid ident (`MBG`); of several with that ident, the nearest to
    ///   `reference`, as the real units list the closest first
    /// - an airport's ICAO code (`LOWI`)
    func fix(for entry: String, near reference: CLLocationCoordinate2D?) -> FlightPlan.Fix? {
        let text = entry.uppercased().replacingOccurrences(of: " ", with: "")
        if let c = Self.coordinate(from: text) {
            return FlightPlan.Fix(ident: Self.coordinateIdent(c), coordinate: c, kind: .enroute)
        }
        if let navaid = navaids(text, near: reference).first {
            return FlightPlan.Fix(ident: navaid.ident, coordinate: navaid.coordinate, kind: .enroute)
        }
        if text.count == 4, let airport = AirportDatabase.shared.airport(code: text), airport.icao == text {
            return FlightPlan.Fix(ident: airport.icao, coordinate: airport.coordinate, kind: .enroute)
        }
        return nil
    }

    /// Parse a latitude/longitude entry.
    static func coordinate(from text: String) -> CLLocationCoordinate2D? {
        // Airbus: DDMM.mN/DDDMM.mE
        let airbus = #"^(\d{2})(\d{2}(?:\.\d)?)([NS])/(\d{3})(\d{2}(?:\.\d)?)([EW])$"#
        // Boeing: NDDMM.mEDDDMM.m
        let boeing = #"^([NS])(\d{2})(\d{2}(?:\.\d)?)([EW])(\d{3})(\d{2}(?:\.\d)?)$"#
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        var lat: Double, lon: Double
        if let g = groups(airbus), g.count == 6,
           let ld = Double(g[0]), let lm = Double(g[1]), let od = Double(g[3]), let om = Double(g[4]) {
            lat = (ld + lm / 60) * (g[2] == "S" ? -1 : 1)
            lon = (od + om / 60) * (g[5] == "W" ? -1 : 1)
        } else if let g = groups(boeing), g.count == 6,
                  let ld = Double(g[1]), let lm = Double(g[2]), let od = Double(g[4]), let om = Double(g[5]) {
            lat = (ld + lm / 60) * (g[0] == "S" ? -1 : 1)
            lon = (od + om / 60) * (g[3] == "W" ? -1 : 1)
        } else {
            return nil
        }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The short name the units give an entered position: "N48E011" style,
    /// whole degrees.
    static func coordinateIdent(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%@%02d%@%03d", c.latitude >= 0 ? "N" : "S", Int(abs(c.latitude)),
               c.longitude >= 0 ? "E" : "W", Int(abs(c.longitude)))
    }
}
