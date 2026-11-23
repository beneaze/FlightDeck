import Foundation
import CoreLocation

/// Terminal procedures from the user's own X-Plane navigation data.
///
/// The user picks, in the Files app, the folder that holds X-Plane's
/// `CIFP` folder together with `earth_fix.dat` and `earth_nav.dat` —
/// `Custom Data` or `Resources/default data` in an X-Plane 11 or 12
/// install. The files are copied into the app (Application Support, not
/// backed up) so they work offline, and read as needed: one airport's
/// `CIFP/<ICAO>.dat` when its procedures are first asked for, the fix and
/// navaid files once, to place the fixes those procedures name.
///
/// Formats: X-Plane CIFP 1101/1102 and later (ARINC 424 fields, comma
/// separated), earth_fix.dat 1101/1200, earth_nav.dat 1150/1200 —
/// Laminar Research's published specifications. The data stays the
/// user's; the app neither ships nor uploads it.
final class XPlaneNavData: @unchecked Sendable {
    static let shared = XPlaneNavData()

    enum ImportError: LocalizedError {
        case missing(String)
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .missing(let name): return "\(name) not found in that folder"
            case .copyFailed: return "Could not copy the files"
            }
        }
    }

    private let root: URL
    private let lock = NSLock()
    private var fixes: [String: [Place]]?

    private struct Place {
        let latitude: Double
        let longitude: Double
        /// Terminal area airport, or "ENRT".
        let area: String
        let region: String
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("NavData/XPlane", isDirectory: true)
    }

    private var cifpDirectory: URL { root.appendingPathComponent("CIFP", isDirectory: true) }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: cifpDirectory.path) }

    /// How many airports the imported data has procedures for.
    var airportCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: cifpDirectory.path))?
            .filter { $0.hasSuffix(".dat") }.count ?? 0
    }

    /// The AIRAC cycle from earth_fix.dat's header, e.g. "2311".
    var cycle: String? {
        guard let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent("earth_fix.dat")),
              let data = try? handle.read(upToCount: 400), let text = String(data: data, encoding: .utf8)
        else { return nil }
        guard let range = text.range(of: "cycle ") else { return nil }
        return String(text[range.upperBound...].prefix(4))
    }

    // MARK: Import

    /// Copy X-Plane navigation data from a folder the user picked. Runs off
    /// the main thread; returns the number of airports with procedures.
    func importFolder(_ picked: URL) throws -> Int {
        let fm = FileManager.default
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        // The picked folder holds CIFP, or is CIFP itself with the .dat
        // files beside it in its parent — not reachable from a sandbox,
        // so the containing folder has to be picked.
        let cifp = picked.lastPathComponent == "CIFP" ? picked : picked.appendingPathComponent("CIFP")
        let base = picked.lastPathComponent == "CIFP" ? picked.deletingLastPathComponent() : picked
        guard fm.fileExists(atPath: cifp.path) else { throw ImportError.missing("CIFP folder") }
        let fix = base.appendingPathComponent("earth_fix.dat")
        let nav = base.appendingPathComponent("earth_nav.dat")
        guard fm.fileExists(atPath: fix.path) else { throw ImportError.missing("earth_fix.dat") }
        guard fm.fileExists(atPath: nav.path) else { throw ImportError.missing("earth_nav.dat") }

        let staging = root.deletingLastPathComponent().appendingPathComponent("XPlane-import", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: cifp, to: staging.appendingPathComponent("CIFP"))
            try fm.copyItem(at: fix, to: staging.appendingPathComponent("earth_fix.dat"))
            try fm.copyItem(at: nav, to: staging.appendingPathComponent("earth_nav.dat"))
            try? fm.removeItem(at: root)
            try fm.moveItem(at: staging, to: root)
            var url = root.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            try? fm.removeItem(at: staging)
            throw ImportError.copyFailed
        }
        lock.lock(); fixes = nil; lock.unlock()
        ProcedureDatabase.shared.reload()
        return airportCount
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        lock.lock(); fixes = nil; lock.unlock()
        ProcedureDatabase.shared.reload()
    }

    // MARK: Reading

    func procedures(at icao: String) -> TerminalProcedures? {
        let file = cifpDirectory.appendingPathComponent("\(icao).dat")
        guard let text = (try? String(contentsOf: file, encoding: .utf8))
                ?? (try? String(contentsOf: file, encoding: .isoLatin1))
        else { return nil }

        // Runway thresholds come with the file.
        var runways: [String: (Double, Double)] = [:]
        var records: [(kind: String, fields: [String])] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let kind = String(line[..<colon])
            let fields = line[line.index(after: colon)...]
                .split(separator: ",", omittingEmptySubsequences: false)
                .flatMap { $0.split(separator: ";", omittingEmptySubsequences: false) }
                .map { String($0) }
            if kind == "RWY" {
                if fields.count >= 10, let pos = Self.arincCoordinate(fields[8], fields[9]) {
                    runways[fields[0].trimmingCharacters(in: .whitespaces)] = pos
                }
            } else if kind == "SID" || kind == "STAR" || kind == "APPCH" {
                records.append((kind, fields))
            }
        }

        var result = TerminalProcedures()
        for (kind, f) in records where f.count >= 25 {
            func field(_ i: Int) -> String { f[i].trimmingCharacters(in: .whitespaces) }
            let ident = field(2)
            var transition = field(3)
            let fix = field(4)
            var position: (Double, Double)?
            if !fix.isEmpty {
                position = field(6) == "P" && field(7) == "G" ? runways[fix] : place(fix, area: icao, region: field(5))
            }
            let leg = ProcedureLeg(
                ident: fix, latitude: position?.0, longitude: position?.1,
                pathTerminator: field(11), altitudeDescription: field(22),
                altitude1Ft: Self.altitude(field(23)), altitude2Ft: Self.altitude(field(24)),
                courseDeg: Self.scaled(field(20)), distanceNm: Self.scaled(field(21)),
                isMissedApproachPoint: f[8].count >= 4 && Array(f[8])[3] == "M")
            switch kind {
            case "SID": result.sids[ident, default: [:]][transition, default: []].append(leg)
            case "STAR": result.stars[ident, default: [:]][transition, default: []].append(leg)
            default:
                if field(1) != "A" { transition = "" }
                result.approaches[ident, default: [:]][transition, default: []].append(leg)
            }
        }
        // Approaches end at the missed approach point.
        for (ident, transitions) in result.approaches {
            if let final = transitions[""], let map = final.firstIndex(where: \.isMissedApproachPoint) {
                result.approaches[ident]?[""] = Array(final[...map])
            }
        }
        return result
    }

    /// A fix's position: the airport's terminal fix or navaid first, then
    /// an enroute one in the same ICAO region.
    private func place(_ ident: String, area: String, region: String) -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        if fixes == nil { fixes = loadPlaces() }
        guard let candidates = fixes?[ident] else { return nil }
        let best = candidates.first { $0.area == area }
            ?? candidates.first { $0.area == "ENRT" && $0.region == region }
            ?? candidates.first { $0.region == region }
            ?? candidates.first
        return best.map { ($0.latitude, $0.longitude) }
    }

    /// Every fix (earth_fix.dat) and radio navaid (earth_nav.dat: NDB 2,
    /// VOR 3, DME 12/13) by ident.
    private func loadPlaces() -> [String: [Place]] {
        var table: [String: [Place]] = [:]
        if let text = try? String(contentsOf: root.appendingPathComponent("earth_fix.dat"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                guard p.count >= 5, let lat = Double(p[0]), let lon = Double(p[1]) else { continue }
                table[String(p[2]), default: []].append(Place(latitude: lat, longitude: lon,
                                                              area: String(p[3]), region: String(p[4])))
            }
        }
        if let text = try? String(contentsOf: root.appendingPathComponent("earth_nav.dat"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                guard p.count >= 10, let row = Int(p[0]), [2, 3, 12, 13].contains(row),
                      let lat = Double(p[1]), let lon = Double(p[2]) else { continue }
                table[String(p[7]), default: []].append(Place(latitude: lat, longitude: lon,
                                                              area: String(p[8]), region: String(p[9])))
            }
        }
        return table
    }

    // MARK: Field decoding

    /// ARINC 424 position: N37363403 / W122225483 (DDMMSS.ss).
    static func arincCoordinate(_ lat: String, _ lon: String) -> (Double, Double)? {
        let la = lat.trimmingCharacters(in: .whitespaces), lo = lon.trimmingCharacters(in: .whitespaces)
        guard la.count == 9, lo.count == 10,
              let ld = Double(la.dropFirst().prefix(2)), let lm = Double(la.dropFirst(3).prefix(2)),
              let ls = Double(la.dropFirst(5)),
              let od = Double(lo.dropFirst().prefix(3)), let om = Double(lo.dropFirst(4).prefix(2)),
              let os = Double(lo.dropFirst(6)) else { return nil }
        let latitude = (ld + lm / 60 + ls / 100 / 3600) * (la.hasPrefix("S") ? -1 : 1)
        let longitude = (od + om / 60 + os / 100 / 3600) * (lo.hasPrefix("W") ? -1 : 1)
        return (latitude, longitude)
    }

    /// "05000" → 5000, "FL180" → 18000.
    static func altitude(_ text: String) -> Double? {
        if text.hasPrefix("FL") { return Double(text.dropFirst(2)).map { $0 * 100 } }
        return Double(text)
    }

    /// ARINC tenths ("1038" → 103.8), or a decimal already.
    static func scaled(_ text: String) -> Double? {
        if text.contains(".") { return Double(text) }
        return Double(text).map { $0 / 10 }
    }
}
