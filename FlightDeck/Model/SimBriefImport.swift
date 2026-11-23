import Foundation
import CoreLocation

/// The latest flight plan (OFP) the user generated in SimBrief, fetched by
/// their SimBrief username through SimBrief's public OFP fetcher — the way
/// simulator add-ons load a SimBrief plan. Real filed ATC routes are only
/// sold by paid services; a SimBrief plan is the free stand-in, built from
/// real-world route data.
///
/// `https://www.simbrief.com/api/xml.fetcher.php?username=<user>&json=1`
struct SimBriefPlan {
    struct Fix {
        let ident: String
        let latitude: Double
        let longitude: Double
        /// The SID or STAR the fix belongs to, else the airway, else nil.
        let via: String?
        let isProcedure: Bool
        /// SimBrief's flight phase: CLB, CRZ, DSC.
        let stage: String
    }

    let callsign: String?
    let flightNumber: String?
    let origin: String
    let destination: String
    let departureRunway: String?
    let arrivalRunway: String?
    let cruiseAltitudeFt: Double?
    let fixes: [Fix]

    enum FetchError: LocalizedError {
        case unknownUser, offline, unavailable, noPlan

        var errorDescription: String? {
            switch self {
            case .unknownUser: return "SIMBRIEF USER UNKNOWN"
            case .offline: return "NO CONNECTION"
            case .unavailable: return "SIMBRIEF NOT AVAIL"
            case .noPlan: return "NO SIMBRIEF PLAN"
            }
        }
    }

    static func fetch(username: String) async throws -> SimBriefPlan {
        var components = URLComponents(string: "https://www.simbrief.com/api/xml.fetcher.php")!
        components.queryItems = [URLQueryItem(name: "username", value: username),
                                 URLQueryItem(name: "json", value: "1")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost,
                                              .dataNotAllowed].contains(error.code) {
            throw FetchError.offline
        } catch {
            throw FetchError.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.unavailable
        }
        if let fetch = json["fetch"] as? [String: Any], let message = fetch["status"] as? String,
           message.lowercased() != "success" {
            throw message.lowercased().contains("user") ? FetchError.unknownUser : FetchError.noPlan
        }
        guard (200..<300).contains(status), let plan = parse(json) else { throw FetchError.noPlan }
        return plan
    }

    /// Read an OFP in SimBrief's JSON form.
    static func parse(_ json: [String: Any]) -> SimBriefPlan? {
        func string(_ object: Any?) -> String? {
            switch object {
            case let s as String: return s.isEmpty ? nil : s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
        func double(_ object: Any?) -> Double? { string(object).flatMap(Double.init) }

        guard let origin = json["origin"] as? [String: Any], let destination = json["destination"] as? [String: Any],
              let from = string(origin["icao_code"]), let to = string(destination["icao_code"]) else { return nil }
        let general = json["general"] as? [String: Any] ?? [:]
        let atc = json["atc"] as? [String: Any] ?? [:]

        // navlog.fix is an array, or a single object for a one-fix plan.
        var rawFixes: [[String: Any]] = []
        if let navlog = json["navlog"] as? [String: Any] {
            if let list = navlog["fix"] as? [[String: Any]] { rawFixes = list }
            else if let one = navlog["fix"] as? [String: Any] { rawFixes = [one] }
        }
        let fixes: [Fix] = rawFixes.compactMap { f in
            guard let ident = string(f["ident"]), let lat = double(f["pos_lat"]), let lon = double(f["pos_long"])
            else { return nil }
            // Airports, and the top of climb / descent SimBrief lists as fixes.
            if string(f["type"]) == "apt" || ["TOC", "TOD"].contains(ident) { return nil }
            let via = string(f["via_airway"]).flatMap { $0 == "DCT" ? nil : $0 }
            return Fix(ident: ident, latitude: lat, longitude: lon, via: via,
                       isProcedure: string(f["is_sid_star"]) == "1", stage: string(f["stage"]) ?? "CRZ")
        }

        let airline = string(general["icao_airline"])
        let number = string(general["flight_number"])
        return SimBriefPlan(
            callsign: string(atc["callsign"]) ?? airline.flatMap { a in number.map { a + $0 } },
            flightNumber: airline.flatMap { a in number.map { a + $0 } },
            origin: from, destination: to,
            departureRunway: string(origin["plan_rwy"]), arrivalRunway: string(destination["plan_rwy"]),
            cruiseAltitudeFt: double(general["initial_altitude"]),
            fixes: fixes)
    }

    // MARK: Procedures

    /// The SID: the procedure the climb's procedure fixes fly.
    var sidName: String? { fixes.first { $0.isProcedure && $0.stage == "CLB" }?.via }
    /// The STAR: the procedure the descent's procedure fixes fly.
    var starName: String? { fixes.last { $0.isProcedure && $0.stage != "CLB" }?.via }
}
