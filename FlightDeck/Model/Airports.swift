import Foundation
import CoreLocation

/// An airport from the bundled database (OurAirports, public domain).
struct Airport: Codable, Hashable, Identifiable {
    /// ICAO code where one exists, else the local/GPS code.
    let icao: String
    let iata: String?
    let name: String
    let city: String
    /// ISO country code.
    let country: String
    let latitude: Double
    let longitude: Double
    let elevationFt: Double
    /// Large airports — the hubs — as opposed to medium ones.
    let isLarge: Bool

    var id: String { icao }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    /// The code a passenger knows: IATA when there is one.
    var code: String { iata ?? icao }

    private enum CodingKeys: String, CodingKey {
        case icao = "i", iata = "a", name = "n", city = "c", country = "k"
        case latitude = "y", longitude = "x", elevationFt = "e", isLarge = "l"
    }
}

/// The bundled airport list: large and medium airports worldwide, searchable
/// by code, city or name, and by position. Always available offline.
final class AirportDatabase: @unchecked Sendable {
    static let shared = AirportDatabase()

    let airports: [Airport]
    private let byCode: [String: Airport]
    /// Airports bucketed by whole degree of latitude and longitude.
    private let buckets: [Int: [Airport]]

    private init() {
        var list: [Airport] = []
        if let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Airport].self, from: data) {
            list = decoded
        }
        airports = list
        var codes: [String: Airport] = [:]
        var grid: [Int: [Airport]] = [:]
        for airport in list {
            codes[airport.icao] = airport
            // A large airport wins an IATA code shared with a smaller one.
            if let iata = airport.iata, codes[iata].map({ !$0.isLarge }) ?? true {
                codes[iata] = airport
            }
            grid[Self.bucket(airport.latitude, airport.longitude), default: []].append(airport)
        }
        byCode = codes
        buckets = grid
    }

    private static func bucket(_ lat: Double, _ lon: Double) -> Int {
        let la = Int(floor(lat)) + 90, lo = (Int(floor(lon)) + 180 + 360) % 360
        return la * 360 + lo
    }

    /// The airport with this IATA or ICAO code.
    func airport(code: String) -> Airport? {
        byCode[code.uppercased().trimmingCharacters(in: .whitespaces)]
    }

    /// Up to `limit` airports matching the text: exact codes first, then
    /// codes, cities and names starting with it, then names containing it.
    /// Large airports rank above medium ones within each group.
    func search(_ text: String, limit: Int = 30) -> [Airport] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let upper = query.uppercased()
        // A city or name starting with the text outranks a code that merely
        // starts with it: "zur" means Zurich, not an ICAO code beginning ZUR.
        func rank(_ a: Airport) -> Int? {
            if a.iata == upper || a.icao == upper { return 0 }
            if a.city.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 1 }
            if a.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 2 }
            if a.iata?.hasPrefix(upper) == true || a.icao.hasPrefix(upper) { return 3 }
            if a.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || a.city.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return 4 }
            return nil
        }
        var scored: [(airport: Airport, score: Int)] = []
        for airport in airports {
            guard let r = rank(airport) else { continue }
            scored.append((airport, r * 2 + (airport.isLarge ? 0 : 1)))
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score < rhs.score : lhs.airport.name < rhs.airport.name
        }
        return scored.prefix(limit).map { $0.airport }
    }

    /// Airports within `radiusNm` of a point.
    func airports(near point: CLLocationCoordinate2D, withinNm radiusNm: Double) -> [Airport] {
        let latSpan = Int(ceil(radiusNm / 60)) + 1
        let lonSpan = Int(ceil(radiusNm / (60 * max(0.05, cos(point.latitude * .pi / 180))))) + 1
        var result: [Airport] = []
        let baseLat = Int(floor(point.latitude)), baseLon = Int(floor(point.longitude))
        for dLat in -latSpan...latSpan {
            let lat = baseLat + dLat
            guard (-90..<90).contains(lat) else { continue }
            for dLon in -min(lonSpan, 180)...min(lonSpan, 180) {
                for airport in buckets[Self.bucket(Double(lat), Double(baseLon + dLon))] ?? []
                where GreatCircle.distanceNm(point, airport.coordinate) <= radiusNm {
                    result.append(airport)
                }
            }
        }
        return result
    }

    /// The nearest airport to a point, within `radiusNm`.
    func nearest(to point: CLLocationCoordinate2D, withinNm radiusNm: Double) -> Airport? {
        airports(near: point, withinNm: radiusNm)
            .min { GreatCircle.distanceNm(point, $0.coordinate) < GreatCircle.distanceNm(point, $1.coordinate) }
    }
}

/// IATA → ICAO airline designators (LH → DLH), from Wikidata (CC0), so a
/// flight number as printed on a boarding pass becomes the callsign that
/// aircraft transmit.
enum AirlineCodes {
    private static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "airlines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }()

    /// The ICAO callsign for a flight number: "LH 400" → "DLH400". A
    /// designator that is already ICAO (three letters) passes through.
    static func callsign(forFlightNumber text: String) -> String? {
        let compact = text.uppercased().filter { $0.isLetter || $0.isNumber }
        // Airline designator: two characters (IATA, may contain a digit) or
        // three letters (ICAO), followed by the flight number proper.
        guard compact.count >= 3 else { return nil }
        let chars = Array(compact)
        if chars.count >= 4, chars[0...2].allSatisfy(\.isLetter) {
            let rest = String(chars[3...])
            if rest.first?.isNumber == true { return String(chars[0...2]) + Self.trimZeros(rest) }
        }
        let prefix = String(chars[0...1])
        let rest = String(chars[2...])
        guard rest.first?.isNumber == true, let icao = table[prefix] else { return nil }
        return icao + Self.trimZeros(rest)
    }

    /// Callsigns carry no leading zeros: LH0400 → DLH400.
    private static func trimZeros(_ s: String) -> String {
        let trimmed = s.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
