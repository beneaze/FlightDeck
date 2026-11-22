import Foundation
import CoreLocation

/// What a flight-number lookup yields: the callsign it resolved to, the two
/// airports, and — when the source has one — the path the flight takes.
struct FlightLookupResult {
    let callsign: String
    let origin: Airport
    let destination: Airport
    /// The expected lateral path (with altitudes), or nil to fly the great
    /// circle.
    let route: [FlightPlan.RoutePoint]?
    let source: FlightPlan.RouteSource
}

enum FlightLookupError: LocalizedError {
    case badFlightNumber
    case notFound(String)
    case offline
    case unknownAirport(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .badFlightNumber: return "Enter a flight number like LH400 or a callsign like DLH400."
        case .notFound(let callsign): return "No recent flight found for \(callsign). Pick the airports instead."
        case .offline: return "No internet connection. Pick the airports instead."
        case .unknownAirport(let code): return "Airport \(code) is not in the built-in list."
        case .unavailable: return "The flight archive is not reachable. Pick the airports instead."
        }
    }
}

/// Any source that turns a flight number into airports and a path. The free
/// archive below is the default; a paid source with filed routes (behind a
/// server that holds its key) would be another conformer.
protocol FlightLookupProvider: Sendable {
    func lookup(flightNumber: String) async throws -> FlightLookupResult
}

/// The free flight-track archive: for each callsign, the most recent track
/// it actually flew, built daily from adsb.lol's open ADS-B data (ODbL 1.0)
/// and published as static files (see Tools/FlightArchive). The path a
/// flight took on an earlier day is the best freely available stand-in for
/// its filed route.
struct FlightArchiveProvider: FlightLookupProvider {
    /// Where the archive is published — the GitHub Pages site of the
    /// archive repository. Set this once the archive repository is live; a
    /// `-flightArchiveBaseURL <url>` launch argument overrides it (for
    /// testing against a local copy).
    static let publishedBaseURL = "https://peakflyer.github.io/flightdeck-flight-archive/v1/"

    static let attribution = "Flight tracks: contains data from adsb.lol (ODbL 1.0)."

    var baseURL: URL? {
        let override = UserDefaults.standard.string(forKey: "flightArchiveBaseURL")
        return URL(string: override ?? Self.publishedBaseURL)
    }

    private struct Entry: Decodable {
        let callsign: String
        let flownOn: String
        let origin: String
        let destination: String
        /// [latitude, longitude, altitudeFt]
        let track: [[Double]]
    }

    func lookup(flightNumber: String) async throws -> FlightLookupResult {
        guard let callsign = AirlineCodes.callsign(forFlightNumber: flightNumber) else {
            throw FlightLookupError.badFlightNumber
        }
        if UserDefaults.standard.bool(forKey: "simulateOffline") { throw FlightLookupError.offline }
        guard let base = baseURL else { throw FlightLookupError.unavailable }
        let url = base.appendingPathComponent(String(callsign.prefix(3)))
            .appendingPathComponent("\(callsign).json")

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost,
                                              .dataNotAllowed].contains(error.code) {
            throw FlightLookupError.offline
        } catch {
            throw FlightLookupError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw FlightLookupError.unavailable }
        if http.statusCode == 404 { throw FlightLookupError.notFound(callsign) }
        guard (200..<300).contains(http.statusCode),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { throw FlightLookupError.unavailable }

        let airports = AirportDatabase.shared
        guard let origin = airports.airport(code: entry.origin) else {
            throw FlightLookupError.unknownAirport(entry.origin)
        }
        guard let destination = airports.airport(code: entry.destination) else {
            throw FlightLookupError.unknownAirport(entry.destination)
        }

        // The archived track starts and ends a few miles out; pin both ends
        // to the airports so the plan runs runway to runway.
        var route = entry.track.compactMap { p -> FlightPlan.RoutePoint? in
            guard p.count >= 2 else { return nil }
            return FlightPlan.RoutePoint(latitude: p[0], longitude: p[1], altitudeFt: p.count > 2 ? p[2] : nil)
        }
        route.insert(.init(latitude: origin.latitude, longitude: origin.longitude,
                           altitudeFt: origin.elevationFt), at: 0)
        route.append(.init(latitude: destination.latitude, longitude: destination.longitude,
                           altitudeFt: destination.elevationFt))

        return FlightLookupResult(callsign: entry.callsign, origin: origin, destination: destination,
                                  route: route.count > 2 ? route : nil,
                                  source: .archive(flownOn: entry.flownOn))
    }
}
