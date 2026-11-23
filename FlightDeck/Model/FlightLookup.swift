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
        case .notFound(let callsign): return "No route known for \(callsign). Pick the airports instead."
        case .offline: return "No internet connection. Pick the airports instead."
        case .unknownAirport(let code): return "Airport \(code) is not in the built-in list."
        case .unavailable: return "The route service is not reachable. Pick the airports instead."
        }
    }
}

/// Any source that turns a flight number into airports and a path.
protocol FlightLookupProvider: Sendable {
    func lookup(flightNumber: String) async throws -> FlightLookupResult
}

/// The default lookup: where a flight-track archive has been set up, the
/// path flown on an earlier day; otherwise the airports from two free route
/// services asked at once — adsbdb.com and hexdb.io — taking whichever
/// answers first, so one being slow or down does not stop the lookup.
struct DefaultFlightLookup: FlightLookupProvider {
    let archive = FlightArchiveProvider()
    let routeServices: [FlightLookupProvider] = [AdsbdbRouteProvider(), HexdbRouteProvider()]

    func lookup(flightNumber: String) async throws -> FlightLookupResult {
        if archive.baseURL != nil, let flown = try? await archive.lookup(flightNumber: flightNumber) {
            return flown
        }
        return try await withThrowingTaskGroup(of: Result<FlightLookupResult, Error>.self) { group in
            for service in routeServices {
                group.addTask {
                    do { return .success(try await service.lookup(flightNumber: flightNumber)) }
                    catch { return .failure(error) }
                }
            }
            var errors: [FlightLookupError] = []
            for try await outcome in group {
                switch outcome {
                case .success(let result):
                    group.cancelAll()
                    return result
                case .failure(let error):
                    errors.append(error as? FlightLookupError ?? .unavailable)
                }
            }
            // The most telling failure: a bad entry, then "no route known"
            // from a service that answered, then no connection.
            if errors.contains(where: { if case .badFlightNumber = $0 { return true }; return false }) {
                throw FlightLookupError.badFlightNumber
            }
            if let notFound = errors.first(where: { if case .notFound = $0 { return true }; return false }) {
                throw notFound
            }
            if let unknown = errors.first(where: { if case .unknownAirport = $0 { return true }; return false }) {
                throw unknown
            }
            if errors.contains(where: { if case .offline = $0 { return true }; return false }) {
                throw FlightLookupError.offline
            }
            throw FlightLookupError.unavailable
        }
    }
}

/// Shared by the route services: fetch JSON, mapping transport failures.
private enum RouteService {
    static func fetch(_ url: URL) async throws -> (Data, Int) {
        if UserDefaults.standard.bool(forKey: "simulateOffline") { throw FlightLookupError.offline }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost,
                                              .dataNotAllowed].contains(error.code) {
            throw FlightLookupError.offline
        } catch {
            throw FlightLookupError.unavailable
        }
    }
}

/// Airports for a callsign from hexdb.io, a free public API (no key):
/// `{"flight": "OCN1267", "route": "LGZA-EDDM"}`. A multi-stop route takes
/// its first and last airport.
struct HexdbRouteProvider: FlightLookupProvider {
    static let baseURL = URL(string: "https://hexdb.io/api/v1/route/icao/")!

    private struct Response: Decodable {
        let flight: String
        let route: String
    }

    func lookup(flightNumber: String) async throws -> FlightLookupResult {
        guard let callsign = AirlineCodes.callsign(forFlightNumber: flightNumber) else {
            throw FlightLookupError.badFlightNumber
        }
        let (data, status) = try await RouteService.fetch(Self.baseURL.appendingPathComponent(callsign))
        if status == 404 { throw FlightLookupError.notFound(callsign) }
        guard (200..<300).contains(status) else { throw FlightLookupError.unavailable }
        // hexdb answers an unknown callsign with 200 and no route.
        guard let entry = try? JSONDecoder().decode(Response.self, from: data) else {
            throw FlightLookupError.notFound(callsign)
        }
        let codes = entry.route.split(separator: "-").map(String.init)
        guard let first = codes.first, let last = codes.last, codes.count >= 2 else {
            throw FlightLookupError.notFound(callsign)
        }
        let airports = AirportDatabase.shared
        guard let origin = airports.airport(code: first) else { throw FlightLookupError.unknownAirport(first) }
        guard let destination = airports.airport(code: last) else { throw FlightLookupError.unknownAirport(last) }
        return FlightLookupResult(callsign: entry.flight, origin: origin, destination: destination,
                                  route: nil, source: .greatCircle)
    }
}

/// Airports for a callsign from adsbdb.com: a free public API (no key)
/// serving the flight routes of Virtual Radar Server's standing data
/// (CC0), compiled from ACARS logs and user reports. It gives the two
/// airports, not the path: the plan flies the great circle, or the
/// waypoints entered on the MCDU.
///
/// The route belongs to the callsign aircraft transmit, which for most
/// flights is the airline's ICAO code and the flight number (LH400 →
/// DLH400). A codeshare's number (LH4335 flown by Eurowings Discover as
/// 4Y1267) is not what the aircraft transmits; enter the operating flight.
struct AdsbdbRouteProvider: FlightLookupProvider {
    static let baseURL = URL(string: "https://api.adsbdb.com/v0/callsign/")!
    static let attribution = "Flight routes: adsbdb.com, from Virtual Radar Server standing data (CC0)."

    private struct Response: Decodable {
        struct Body: Decodable { let flightroute: Route? }
        struct Route: Decodable {
            let callsign: String
            let origin: Place
            let destination: Place
        }
        struct Place: Decodable {
            let icao_code: String
            let iata_code: String?
            let name: String
            let municipality: String?
            let country_iso_name: String?
            let latitude: Double
            let longitude: Double
            let elevation: Double?
        }
        let response: Body
    }

    func lookup(flightNumber: String) async throws -> FlightLookupResult {
        guard let callsign = AirlineCodes.callsign(forFlightNumber: flightNumber) else {
            throw FlightLookupError.badFlightNumber
        }
        let (data, status) = try await RouteService.fetch(Self.baseURL.appendingPathComponent(callsign))
        if status == 404 { throw FlightLookupError.notFound(callsign) }
        guard (200..<300).contains(status),
              let route = (try? JSONDecoder().decode(Response.self, from: data))?.response.flightroute
        else { throw FlightLookupError.unavailable }
        return FlightLookupResult(callsign: route.callsign, origin: Self.airport(route.origin),
                                  destination: Self.airport(route.destination), route: nil, source: .greatCircle)
    }

    /// The bundled airport where there is one (so runways and the plan's
    /// identity match), else the one adsbdb describes.
    private static func airport(_ place: Response.Place) -> Airport {
        if let known = AirportDatabase.shared.airport(code: place.icao_code) { return known }
        return Airport(icao: place.icao_code, iata: place.iata_code, name: place.name,
                       city: place.municipality ?? "", country: place.country_iso_name ?? "",
                       latitude: place.latitude, longitude: place.longitude,
                       elevationFt: place.elevation ?? 0, isLarge: false)
    }
}

/// The free flight-track archive: for each callsign, the most recent track
/// it actually flew, built daily from adsb.lol's open ADS-B data (ODbL 1.0)
/// and published as static files (see Tools/FlightArchive). The path a
/// flight took on an earlier day is the best freely available stand-in for
/// its filed route.
struct FlightArchiveProvider: FlightLookupProvider {
    /// Where the archive is published, once someone runs one (see
    /// Tools/FlightArchive). None is by default: lookups then use adsbdb.com
    /// alone. A `-flightArchiveBaseURL <url>` launch argument sets one (for
    /// testing against a local copy).
    static let publishedBaseURL: String? = nil

    static let attribution = "Flight tracks: contains data from adsb.lol (ODbL 1.0)."

    var baseURL: URL? {
        (UserDefaults.standard.string(forKey: "flightArchiveBaseURL") ?? Self.publishedBaseURL).flatMap(URL.init)
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
