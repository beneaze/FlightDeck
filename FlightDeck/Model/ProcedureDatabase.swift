import Foundation
import CoreLocation

/// One leg of a published terminal procedure, as ARINC 424 codes it.
struct ProcedureLeg: Hashable {
    /// The fix the leg ends at; empty for legs to an altitude, a radial or
    /// vectors.
    let ident: String
    let latitude: Double?
    let longitude: Double?
    /// ARINC 424 path terminator: IF, TF, CF, DF, VA, CA, VM, HM, RF, …
    let pathTerminator: String
    /// "+" at or above, "-" at or below, "" at, "B" between, G/H/I/J glide
    /// path variants.
    let altitudeDescription: String
    let altitude1Ft: Double?
    let altitude2Ft: Double?
    /// Magnetic course or heading of the leg, degrees.
    let courseDeg: Double?
    let distanceNm: Double?
    /// The missed approach point: an approach's last leg kept.
    let isMissedApproachPoint: Bool

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }

    /// The altitude to show as the leg's constraint.
    var constraintFt: Double? {
        // "B": between altitude 1 (upper) and 2 (lower); show the lower.
        altitudeDescription == "B" ? (altitude2Ft ?? altitude1Ft) : altitude1Ft
    }
}

/// An airport's SIDs, STARs and approaches: procedure → transition → legs.
/// Runway transitions are named RW25L, RW25B (all parallel 25s) or ALL;
/// common routes and an approach's final segment sit under "".
struct TerminalProcedures {
    var sids: [String: [String: [ProcedureLeg]]] = [:]
    var stars: [String: [String: [ProcedureLeg]]] = [:]
    var approaches: [String: [String: [ProcedureLeg]]] = [:]

    var isEmpty: Bool { sids.isEmpty && stars.isEmpty && approaches.isEmpty }

    /// Whether a transition key serves a runway: RW25L for 25L, RW25B for
    /// every 25, ALL or none for all.
    static func transition(_ key: String, serves runway: Runway?) -> Bool {
        guard key.hasPrefix("RW") else { return false }
        guard let runway else { return true }
        if key == "RW" + runway.designator { return true }
        let number = runway.designator.prefix { $0.isNumber }
        return key == "RW\(number)B"
    }

    static func isRunwayTransition(_ key: String) -> Bool { key.hasPrefix("RW") || key == "ALL" }

    /// SIDs usable from a runway: one with a transition for it, or one
    /// with no runway transitions at all.
    func sids(from runway: Runway?) -> [String] {
        sids.filter { _, transitions in
            let runwayKeys = transitions.keys.filter { $0.hasPrefix("RW") }
            return runwayKeys.isEmpty || runwayKeys.contains { Self.transition($0, serves: runway) }
        }.keys.sorted()
    }

    /// Enroute transitions of a SID or STAR.
    static func enrouteTransitions(_ transitions: [String: [ProcedureLeg]]) -> [String] {
        transitions.keys.filter { !$0.isEmpty && !isRunwayTransition($0) }.sorted()
    }

    /// The legs of a SID from a runway, through its common route, out
    /// along an enroute transition.
    func sidLegs(_ name: String, runway: Runway?, transition: String?) -> [ProcedureLeg] {
        guard let t = sids[name] else { return [] }
        let runwayPart = t.first { Self.transition($0.key, serves: runway) }?.value ?? t["ALL"] ?? []
        return runwayPart + (t[""] ?? []) + (transition.flatMap { t[$0] } ?? [])
    }

    /// The legs of a STAR from an enroute transition, through its common
    /// route, to a runway's transition.
    func starLegs(_ name: String, transition: String?, runway: Runway?) -> [ProcedureLeg] {
        guard let t = stars[name] else { return [] }
        let runwayPart = t.first { Self.transition($0.key, serves: runway) }?.value ?? t["ALL"] ?? []
        return (transition.flatMap { t[$0] } ?? []) + (t[""] ?? []) + runwayPart
    }

    /// The legs of an approach from a transition (via) to the missed
    /// approach point.
    func approachLegs(_ name: String, via: String?) -> [ProcedureLeg] {
        guard let t = approaches[name] else { return [] }
        return (via.flatMap { t[$0] } ?? []) + (t[""] ?? [])
    }

    /// Approach transitions (vias).
    func vias(_ approach: String) -> [String] {
        (approaches[approach] ?? [:]).keys.filter { !$0.isEmpty }.sorted()
    }
}

/// Terminal procedures, from two sources:
/// - **US airports:** bundled, from the FAA's CIFP (public domain), built
///   by Tools/BuildProcedures.
/// - **Everywhere:** the user's own X-Plane navigation data, imported from
///   the Files app (``XPlaneNavData``). Imported data wins where both exist.
///
/// Nothing licensed ships with the app: the X-Plane data is what the user
/// copied from their own simulator.
final class ProcedureDatabase: @unchecked Sendable {
    static let shared = ProcedureDatabase()

    private let lock = NSLock()
    private var bundled: [String: Any]?
    private var cache: [String: TerminalProcedures] = [:]

    /// Forget cached airports, after an import or a removal.
    func reload() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
    }

    func procedures(at airport: Airport) -> TerminalProcedures {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[airport.icao] { return cached }
        var result = XPlaneNavData.shared.procedures(at: airport.icao) ?? TerminalProcedures()
        if result.isEmpty { result = bundledProcedures(airport.icao) }
        cache[airport.icao] = result
        return result
    }

    private func bundledProcedures(_ icao: String) -> TerminalProcedures {
        if bundled == nil {
            if let url = Bundle.main.url(forResource: "procedures-us", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let table = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bundled = table
            } else {
                bundled = [:]
            }
        }
        guard let entry = bundled?[icao] as? [String: Any] else { return TerminalProcedures() }
        func decode(_ kind: String) -> [String: [String: [ProcedureLeg]]] {
            guard let procs = entry[kind] as? [String: [String: [[Any]]]] else { return [:] }
            return procs.mapValues { $0.mapValues { $0.compactMap(Self.leg) } }
        }
        return TerminalProcedures(sids: decode("SID"), stars: decode("STAR"), approaches: decode("APP"))
    }

    private static func leg(_ a: [Any]) -> ProcedureLeg? {
        guard a.count >= 10 else { return nil }
        func double(_ i: Int) -> Double? { (a[i] as? NSNumber)?.doubleValue }
        return ProcedureLeg(ident: a[0] as? String ?? "", latitude: double(1), longitude: double(2),
                            pathTerminator: a[3] as? String ?? "", altitudeDescription: a[4] as? String ?? "",
                            altitude1Ft: double(5), altitude2Ft: double(6), courseDeg: double(7),
                            distanceNm: double(8), isMissedApproachPoint: (a[9] as? String) == "M")
    }

    // MARK: Names as the units print them

    /// "I28R" → "ILS28R", "R10RY" → "RNV10R-Y" (Airbus); Boeing prints
    /// "ILS 28R", "RNAV 10R Y".
    static func approachName(_ ident: String, boeing: Bool) -> String {
        let types: [Character: (String, String)] = [
            "I": ("ILS", "ILS"), "L": ("LOC", "LOC"), "R": ("RNV", "RNAV"), "H": ("RNP", "RNP"),
            "D": ("VOR", "VOR"), "V": ("VOR", "VOR"), "S": ("VOR", "VOR"), "N": ("NDB", "NDB"),
            "Q": ("NDB", "NDB"), "B": ("BAC", "LOC BC"), "X": ("LDA", "LDA"), "U": ("SDF", "SDF"),
            "P": ("GPS", "GPS"), "G": ("IGS", "IGS"),
        ]
        guard let first = ident.first, let type = types[first] else { return ident }
        let rest = ident.dropFirst()
        let runway = String(rest.prefix { $0.isNumber || "LRC".contains($0) })
        let suffix = String(rest.dropFirst(runway.count)).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        if boeing {
            return [type.1, runway, suffix].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return type.0 + runway + (suffix.isEmpty ? "" : "-" + suffix)
    }

    /// The runway an approach lands on: "I28R" → "28R".
    static func approachRunway(_ ident: String) -> String? {
        let digits = ident.dropFirst().prefix { $0.isNumber || "LRC".contains($0) }
        guard digits.first?.isNumber == true else { return nil }
        return String(digits)
    }
}

/// Turns procedure legs into the plan's fixes.
enum ProcedureBuilder {
    /// Legs with a fix keep it, with the leg's altitude constraint. A leg
    /// flown to an altitude (VA, CA, FA: the climb after take-off) becomes
    /// an altitude fix "(520)" along its course, as far out as the climb
    /// takes. Legs to an intercept, a radial or vectors (VI, CI, VM, FM, …)
    /// have no place to put: the plan goes direct to the next fix.
    ///
    /// Courses are magnetic; `variationDeg` (east positive) turns them true.
    static func fixes(_ legs: [ProcedureLeg], kind: FlightPlan.Fix.Kind,
                      from start: CLLocationCoordinate2D, startAltitudeFt: Double,
                      variationDeg: Double, lastIsDestination: Bool = false) -> [FlightPlan.Fix] {
        var out: [FlightPlan.Fix] = []
        var position = start
        var altitude = startAltitudeFt
        for (i, leg) in legs.enumerated() {
            if let c = leg.coordinate {
                let isLast = lastIsDestination && i == legs.count - 1
                out.append(FlightPlan.Fix(ident: leg.ident, coordinate: c, kind: isLast ? .destination : kind,
                                          altitudeFt: leg.constraintFt))
                position = c
                if let a = leg.constraintFt { altitude = a }
            } else if ["VA", "CA", "FA"].contains(leg.pathTerminator),
                      let target = leg.altitude1Ft, let course = leg.courseDeg {
                let climbNm = max(1, (target - altitude) / 1_000 * FlightPlan.climbNmPer1000Ft)
                let c = GreatCircle.destination(from: position, courseDeg: normalizedHeading(course + variationDeg),
                                                distanceNm: climbNm)
                out.append(FlightPlan.Fix(ident: "(\(Int(target)))", coordinate: c, kind: kind, altitudeFt: target))
                position = c
                altitude = target
            }
        }
        return out
    }

    /// Magnetic variation from a runway: its true heading against the
    /// magnetic one its number gives (26R → 260°). Good to a few degrees,
    /// which is all an altitude leg's drawing needs.
    static func variation(_ runway: Runway?) -> Double {
        guard let runway, let number = Double(runway.ident.prefix { $0.isNumber }) else { return 0 }
        return angularDifference(runway.headingDeg, number * 10).clamped(to: -25...25)
    }
}
