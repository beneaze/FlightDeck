import SwiftUI
import MapKit

/// The MCDU pages: what each one shows, and what its line-select keys do.
///
/// Conventions, as on the real units: labels in small white over their
/// data; crew entries cyan (small when the system computed the value and
/// the crew has not overwritten it); system data green; amber boxes for a
/// required entry; `<` and `>` prompts lead to other pages; an amber `*`
/// starts an action.
extension MCDUController {

    // MARK: - Screen

    func screen() -> MCDUScreen {
        guard isAttached else { return MCDUScreen(title: [], rows: Array(repeating: .empty, count: 12)) }
        var rows = Array(repeating: MCDULine.empty, count: 12)
        let title: [MCDURun]
        switch page {
        case .menu: title = menuPage(&rows)
        case .route: title = routePlanner.transportMode == .plane ? flightInitPage(&rows) : roadRoutePage(&rows)
        case .destSearch: title = searchPage(&rows)
        case .flightPlan: title = isEditingFlightPlan ? plannedFlightPlanPage(&rows) : flightPlanPage(&rows)
        case .departure: title = departurePage(&rows)
        case .arrival: title = arrivalPage(&rows)
        case .depArr: title = depArrPage(&rows)
        case .progress: title = progressPage(&rows)
        case .settings: title = settingsPage(&rows)
        case .flights: title = flightsPage(&rows)
        case .credits: title = creditsPage(&rows)
        }
        let count = pageCount
        return MCDUScreen(title: title, pageNumber: count > 1 ? "\(min(subpage, count - 1) + 1)/\(count)" : nil,
                          rows: rows)
    }

    // MARK: - Line select

    func lineSelect(left: Bool, index: Int) {
        guard isAttached else { return }
        switch page {
        case .menu: menuSelect(left: left, index: index)
        case .route:
            if routePlanner.transportMode == .plane {
                flightInitSelect(left: left, index: index)
            } else {
                roadRouteSelect(left: left, index: index)
            }
        case .destSearch: searchSelect(left: left, index: index)
        case .flightPlan:
            if isEditingFlightPlan {
                plannedFlightPlanSelect(left: left, index: index)
            } else if left, index == 5 {
                show(.route)
            }
        case .departure: departureSelect(left: left, index: index)
        case .arrival: arrivalSelect(left: left, index: index)
        case .depArr: depArrSelect(left: left, index: index)
        case .progress:
            if left, index == 5 { show(.flightPlan) }
        case .settings: settingsSelect(left: left, index: index)
        case .flights: flightsSelect(left: left, index: index)
        case .credits:
            if left, index == 5 { show(.settings) }
        }
    }

    // MARK: - Building blocks

    func label(_ text: String) -> [MCDURun] { [MCDURun(text: text, color: .white, small: true)] }
    func prompt(_ text: String) -> [MCDURun] { [MCDURun(text: text, color: .white)] }
    func data(_ text: String, _ color: MCDUColor = .green, small: Bool = false) -> [MCDURun] {
        [MCDURun(text: text, color: color, small: small)]
    }
    func boxes(_ count: Int) -> [MCDURun] {
        [MCDURun(text: String(repeating: "▯", count: count), color: .amber)]
    }
    func action(_ text: String) -> [MCDURun] {
        [MCDURun(text: text, color: .white), MCDURun(text: "*", color: .amber)]
    }
    func titleRuns(_ text: String, _ extra: String? = nil) -> [MCDURun] {
        var runs = [MCDURun(text: text, color: .white)]
        if let extra { runs.append(MCDURun(text: " " + extra, color: .green)) }
        return runs
    }

    /// A choice among options: the selected one large green, the others
    /// small white.
    func choice(_ options: [String], selected: Int) -> [MCDURun] {
        var runs: [MCDURun] = []
        for (i, option) in options.enumerated() {
            if i > 0 { runs.append(MCDURun(text: "/", color: .white, small: true)) }
            runs.append(MCDURun(text: option, color: i == selected ? .green : .white, small: i != selected))
        }
        return runs
    }

    func set(_ rows: inout [MCDULine], _ pair: Int,
                     labelLeft: [MCDURun] = [], labelRight: [MCDURun] = [],
                     left: [MCDURun] = [], right: [MCDURun] = [], center: [MCDURun] = []) {
        rows[pair * 2] = MCDULine(left: labelLeft, right: labelRight)
        rows[pair * 2 + 1] = MCDULine(left: left, center: center, right: right)
    }

    // MARK: Formatting

    private var speedUnitLabel: String {
        switch flightData.speedUnit {
        case .kmh: return "KMH"
        case .mph: return "MPH"
        case .knots: return "KT"
        }
    }

    private func speed(_ kts: Double) -> String {
        "\(Int((kts * flightData.speedUnit.perKnot).rounded()))\(speedUnitLabel)"
    }

    func altitude(_ feet: Double) -> String {
        if routePlanner.transportMode == .plane, feet >= 10_000 { return "FL\(Int((feet / 100).rounded()))" }
        return "\(Int((feet / 10).rounded()) * 10)FT"
    }

    func distance(_ nm: Double) -> String {
        nm < 10 ? String(format: "%.1fNM", nm) : "\(Int(nm.rounded()))NM"
    }

    func utc(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d%02dZ", c.hour ?? 0, c.minute ?? 0)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                                 "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    private func dayMonth(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.day, .month], from: date)
        return String(format: "%02d", c.day ?? 1) + Self.months[(c.month ?? 1) - 1]
    }

    /// "2026-11-21" → "21NOV".
    private func flownDay(_ isoDate: String) -> String {
        let parts = isoDate.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), (1...12).contains(month) else { return isoDate }
        return String(parts[2]) + Self.months[month - 1]
    }

    private func position(_ c: CLLocationCoordinate2D) -> String {
        func part(_ value: Double, _ positive: String, _ negative: String, _ degreeDigits: Int) -> String {
            let v = abs(value)
            let degrees = Int(v)
            let minutes = (v - Double(degrees)) * 60
            return (value >= 0 ? positive : negative)
                + String(format: "%0\(degreeDigits)d%04.1f", degrees, minutes)
        }
        return part(c.latitude, "N", "S", 2) + " " + part(c.longitude, "E", "W", 3)
    }

    /// Terrain elevation under the aircraft from the active flight pack.
    private var groundElevationFt: Double? {
        guard routePlanner.transportMode == .plane, let location = flightData.location else { return nil }
        return packs.activeTerrain?.elevationFt(at: location.coordinate)
    }

    // MARK: - MENU

    private func menuPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        let mode = routePlanner.transportMode
        func entry(_ m: TransportMode) -> [MCDURun] {
            m == mode ? data(m.label, .green) + data(" ACT", .green, small: true) : prompt("<" + m.label)
        }
        let legs = style.isBoeing ? "RTE LEGS>" : "F-PLN>"
        set(&rows, 0, labelLeft: label("MODE"), labelRight: label(mode == .plane ? "FLIGHT" : "ROUTE"),
            left: entry(.car), right: prompt(style.title(.route) + ">"))
        set(&rows, 1, left: entry(.bicycle), right: prompt(legs))
        set(&rows, 2, left: entry(.plane), right: prompt("PROG>"))
        set(&rows, 3, right: prompt("SETTINGS>"))
        set(&rows, 4, right: prompt("STORED FLT>"))
        set(&rows, 5, left: prompt("<DISPLAYS"), right: prompt("CREDITS>"))
        return titleRuns(style.title(.menu))
    }

    private func menuSelect(left: Bool, index: Int) {
        if left {
            switch index {
            case 0: routePlanner.transportMode = .car
            case 1: routePlanner.transportMode = .bicycle
            case 2: routePlanner.transportMode = .plane
            case 5: close()
            default: break
            }
        } else {
            switch index {
            case 0: show(.route)
            case 1: show(.flightPlan)
            case 2: show(.progress)
            case 3: show(.settings)
            case 4: show(.flights)
            case 5: show(.credits)
            default: break
            }
        }
    }

    // MARK: - INIT / RTE — plane

    private func flightInitPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        let plan = draftPlan
        let fromTo: [MCDURun]
        if let origin, let destination {
            fromTo = data("\(origin.icao)/\(destination.icao)", .cyan)
        } else if let origin {
            fromTo = data(origin.icao, .cyan) + data("/", .white) + boxes(4)
        } else if let destination {
            fromTo = boxes(4) + data("/", .white) + data(destination.icao, .cyan)
        } else {
            fromTo = boxes(4) + data("/", .white) + boxes(4)
        }
        set(&rows, 0, labelLeft: label("FLT NBR"), labelRight: label("FROM/TO"),
            left: isLookingUp ? data("SEARCHING", .white, small: true)
                : (flightNumber.map { data($0, .cyan) } ?? boxes(8)),
            right: fromTo)

        let cruise: [MCDURun]
        if let plan {
            let level = Int(plan.cruiseAltitudeFt / 100)
            cruise = data("FL\(level)", .cyan, small: cruiseLevel == nil)
        } else {
            cruise = data("-----", .white)
        }
        set(&rows, 1, labelLeft: label("DATE"), labelRight: label("CRZ FL"),
            left: data(dayMonth(date), .cyan), right: cruise)

        if let plan {
            let path: [MCDURun]
            switch plan.source {
            case .archive(let flownOn): path = data("FLOWN " + flownDay(flownOn), .green)
            case .entered: path = data(style.isBoeing ? "RTE LEGS" : "F-PLN", .green)
            case .greatCircle: path = data("GREAT CIRCLE", .green)
            }
            set(&rows, 2, labelLeft: label("PATH"), labelRight: label("DIST"),
                left: path, right: data(distance(plan.totalDistanceNm), .green))
            set(&rows, 3, labelLeft: label("T/C  T/D"), labelRight: label("CALLSIGN"),
                left: data("\(Int(plan.topOfClimbNm))/\(Int(plan.topOfDescentNm))NM", .green, small: true),
                right: data(plan.callsign ?? "----", .green))
        }

        // Offline data: download, progress, ready.
        let readyPack = self.readyPack
        let offline: [MCDURun]
        if let progress = packs.progress {
            offline = data("DNLD \(progress.done)/\(progress.total)", .green)
        } else if readyPack != nil {
            offline = data("READY", .green)
        } else if plan != nil {
            offline = action("DOWNLOAD")
        } else {
            offline = data("----", .white)
        }
        set(&rows, 4, labelRight: label("OFFLINE DATA"), right: offline)

        let active = routePlanner.flightPlan
        let six: [MCDURun]
        var sixLabel: [MCDURun] = []
        if let readyPack, readyPack.id != packs.activePackID {
            six = action("ACTIVATE")
        } else if active != nil {
            // "ACTIVE" above: beside <STORED FLT the line has room for the
            // prompt only.
            sixLabel = data("ACTIVE", .green, small: true)
            six = action("CLR FLT")
        } else {
            six = []
        }
        set(&rows, 5, labelRight: sixLabel, left: prompt("<STORED FLT"), right: six)
        return titleRuns(style.title(.route), active?.title)
    }

    private func flightInitSelect(left: Bool, index: Int) {
        switch (left, index) {
        case (true, 0):
            if isClearCommand {
                clearScratchpad()
                flightNumber = nil
                lookup = nil
                refreshPlan()
            } else if let entry = takeEntry() {
                lookUp(entry.uppercased().replacingOccurrences(of: " ", with: ""))
            }
        case (false, 0):
            if isClearCommand {
                clearScratchpad()
                setAirports(origin: nil, destination: nil)
                return
            }
            guard let entry = takeEntry() else { return }
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count <= 2 else { return flash("FORMAT ERROR") }
            let codes = parts.count == 2 ? (parts[0], parts[1]) : (parts[0], "")
            let db = AirportDatabase.shared
            var from = origin, to = destination
            if !codes.0.isEmpty {
                guard let a = db.airport(code: codes.0) else { return flash("NOT IN DATA BASE") }
                from = a
            }
            if !codes.1.isEmpty {
                guard let a = db.airport(code: codes.1) else { return flash("NOT IN DATA BASE") }
                to = a
            }
            setAirports(origin: from, destination: to)
        case (true, 1):
            guard let entry = takeEntry() else { return }
            guard let parsed = parseDate(entry) else { return flash("FORMAT ERROR") }
            date = parsed
            refreshPlan()
        case (false, 1):
            if isClearCommand {
                clearScratchpad()
                cruiseLevel = nil
                refreshPlan()
                return
            }
            guard let entry = takeEntry() else { return }
            let digits = entry.uppercased().replacingOccurrences(of: "FL", with: "")
            guard let level = Int(digits) else { return flash("FORMAT ERROR") }
            guard (50...430).contains(level) else { return flash("ENTRY OUT OF RANGE") }
            cruiseLevel = level
            refreshPlan()
        case (false, 4):
            if packs.progress == nil, draftPlan != nil { download() }
        case (true, 5):
            show(.flights)
        case (false, 5):
            if let pack = pendingPack {
                activate(pack)
            } else if routePlanner.flightPlan != nil {
                packs.activate(nil)
                routePlanner.clearRoute()
                flash("FLIGHT CLEARED")
            }
        default:
            break
        }
    }

    /// "23NOV", "23" (this month) or "+1" / "-1" days from the current one.
    private func parseDate(_ entry: String) -> Date? {
        let text = entry.uppercased()
        let calendar = Calendar.current
        if let offset = Int(text), text.hasPrefix("+") || text.hasPrefix("-") {
            return calendar.date(byAdding: .day, value: offset, to: date)
        }
        let digits = text.prefix { $0.isNumber }
        let monthText = String(text.dropFirst(digits.count))
        guard let day = Int(digits), (1...31).contains(day) else { return nil }
        let today = calendar.dateComponents([.year, .month], from: Date())
        var month = today.month ?? 1
        if !monthText.isEmpty {
            guard let index = Self.months.firstIndex(of: monthText) else { return nil }
            month = index + 1
        }
        var components = DateComponents(year: today.year, month: month, day: day, hour: 12)
        guard var result = calendar.date(from: components) else { return nil }
        // A date more than a week past means next year's.
        if result < Date().addingTimeInterval(-7 * 86_400) {
            components.year = (today.year ?? 2026) + 1
            result = calendar.date(from: components) ?? result
        }
        return result
    }

    // MARK: - INIT / RTE — car and bike

    private func roadRoutePage(_ rows: inout [MCDULine]) -> [MCDURun] {
        let mode = routePlanner.transportMode
        set(&rows, 0, labelLeft: label("MODE"), labelRight: label("SELECT ON MAP"),
            left: choice(["CAR", "BIKE"], selected: mode == .bicycle ? 1 : 0), right: prompt("MAP>"))
        let destination = routePlanner.destination
        set(&rows, 1, labelLeft: label("DEST"), labelRight: label("DIST"),
            left: destination.map { data(String($0.name.uppercased().prefix(12)), .cyan) } ?? boxes(10),
            right: data(routePlanner.distanceToGoNm(from: flightData.location).map(distance) ?? "----",
                        .green))
        if let ete = routePlanner.timeEnroute(from: flightData.location, groundSpeedKts: flightData.groundSpeedKts) {
            set(&rows, 2, labelLeft: label("ETE"), labelRight: label("ETA"),
                left: data(duration(ete)), right: data(utc(Date().addingTimeInterval(ete))))
        }
        if routePlanner.isPlanning {
            set(&rows, 3, center: data("PLANNING ROUTE", .white, small: true))
        } else if let error = routePlanner.errorMessage {
            set(&rows, 3, center: data(String(error.uppercased().prefix(24)), .amber, small: true))
        }
        set(&rows, 4, labelLeft: label("ROUTING"), left: data("APPLE MAPS", .white, small: true))
        set(&rows, 5, left: prompt("<SEARCH"), right: destination != nil ? action("CLR RTE") : [])
        return titleRuns(style.title(.route))
    }

    private func roadRouteSelect(left: Bool, index: Int) {
        switch (left, index) {
        case (true, 0):
            routePlanner.transportMode = routePlanner.transportMode == .car ? .bicycle : .car
        case (false, 0):
            isShowingMap = true
        case (true, 1):
            if isClearCommand {
                clearScratchpad()
                routePlanner.clearRoute()
            } else if let entry = takeEntry() {
                startSearch(entry)
            } else {
                show(.destSearch)
            }
        case (true, 5):
            show(.destSearch)
        case (false, 5):
            if routePlanner.destination != nil {
                routePlanner.clearRoute()
                flash("ROUTE CLEARED")
            }
        default:
            break
        }
    }

    // MARK: - DEST SEARCH

    private var visibleCompletions: ArraySlice<MKLocalSearchCompletion> {
        let all = search.completions
        let start = min(subpage * 4, max(0, all.count))
        return all[start..<min(start + 4, all.count)]
    }

    private func searchPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        set(&rows, 0, labelLeft: label("SEARCH"),
            left: searchQuery.isEmpty ? boxes(12) : data(String(searchQuery.prefix(20)), .cyan))
        if routePlanner.transportMode == .plane {
            set(&rows, 2, center: data("ROAD MODES ONLY", .amber, small: true))
            set(&rows, 5, left: prompt("<RETURN"))
            return titleRuns(style.title(.destSearch))
        }
        let results = Array(visibleCompletions)
        if results.isEmpty, !searchQuery.isEmpty {
            set(&rows, 2, center: data("NO RESULTS YET", .white, small: true))
        }
        for (i, completion) in results.enumerated() {
            let isSelected = selected.map { $0.name.uppercased() == completion.title.uppercased() } ?? false
            set(&rows, i + 1, labelLeft: label(String(completion.subtitle.uppercased().prefix(24))),
                left: [MCDURun(text: "<" + String(completion.title.uppercased().prefix(22)),
                               color: isSelected ? .green : .white)])
        }
        set(&rows, 5, left: prompt("<RETURN"), right: selected != nil ? action("FLY") : [])
        return titleRuns(style.title(.destSearch))
    }

    private func searchSelect(left: Bool, index: Int) {
        switch (left, index) {
        case (true, 0):
            if let entry = takeEntry() { startSearch(entry) }
        case (true, 1...4):
            let results = Array(visibleCompletions)
            guard results.indices.contains(index - 1) else { return }
            choose(results[index - 1])
        case (true, 5):
            show(.route)
        case (false, 5):
            flySelected()
        default:
            break
        }
    }

    // MARK: - F-PLN / LEGS

    private func flightPlanPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        let waypoints = routePlanner.waypoints
        guard !waypoints.isEmpty else {
            set(&rows, 2, center: data("NO F-PLN", .white))
            set(&rows, 5, left: prompt(style.isBoeing ? "<RTE" : "<INIT"))
            return titleRuns(style.title(.flightPlan))
        }
        let location = flightData.location
        let speed = max(flightData.groundSpeedKts, 1)
        let plan = routePlanner.flightPlan
        let visible = Array(waypoints.enumerated()).dropFirst(subpage * 5).prefix(5)
        for (row, entry) in visible.enumerated() {
            let (index, waypoint) = entry
            let distanceNm = routePlanner.distanceNm(to: waypoint, from: location)
            let isActive = index == routePlanner.activeWaypointIndex
            let isPast = index < routePlanner.activeWaypointIndex
            var altitudeLabel: [MCDURun] = []
            if let plan, let d = distanceNm {
                let along = routePlanner.alongTrackNm + d
                altitudeLabel = label(altitude(plan.plannedAltitudeFt(atNm: along)))
            }
            let eta = distanceNm.flatMap { d in flightData.groundSpeedKts > 10
                ? utc(Date().addingTimeInterval(d / speed * 3600)) : nil }
            set(&rows, row,
                labelLeft: label(distanceNm.map(distance) ?? ""),
                labelRight: altitudeLabel,
                left: data(waypoint.ident, isPast ? .grey : (isActive ? .white : .green)),
                right: data(eta ?? "----", .green, small: eta == nil))
        }
        // The destination line, always at the bottom.
        if let last = waypoints.last {
            let d = routePlanner.distanceNm(to: last, from: location)
            set(&rows, 5, labelLeft: label("DEST"), labelRight: label("DIST  ETA"),
                left: data(last.ident, .white),
                right: data((d.map(distance) ?? "----") + " "
                            + (d.flatMap { d in flightData.groundSpeedKts > 10
                                ? utc(Date().addingTimeInterval(d / speed * 3600)) : nil } ?? "----"), .green))
        }
        return titleRuns(style.title(.flightPlan), plan?.title)
    }

    // MARK: - PROG

    private func progressPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        let location = flightData.location
        set(&rows, 0, labelLeft: label("GS"), labelRight: label("ALT"),
            left: data(speed(flightData.groundSpeedKts)), right: data(altitude(flightData.altitudeFt)))

        let vs = flightData.verticalSpeedFpm
        let vsText = flightData.verticalSpeedUnit == .ms
            ? String(format: "%+.1fM/S", vs * 0.00508) : String(format: "%+dFPM", Int((vs / 50).rounded()) * 50)
        let height = groundElevationFt.map { max(0, flightData.altitudeFt - $0) }
        set(&rows, 1, labelLeft: label(routePlanner.transportMode == .plane ? "HGT ABOVE GND" : "TRACK"),
            labelRight: label("V/S"),
            left: routePlanner.transportMode == .plane
                ? data(height.map { "\(Int(($0 / 10).rounded()) * 10)FT" } ?? "----", height == nil ? .white : .green)
                : data(String(format: "%03d°", Int(flightData.trackDeg.rounded()) % 360)),
            right: data(vsText))

        if let to = routePlanner.activeWaypoint {
            set(&rows, 2, labelLeft: label("TO"), labelRight: label("DIST"),
                left: data(to.ident, .white),
                right: data(routePlanner.distanceNm(to: to, from: location).map(distance) ?? "----"))
        }
        if let destination = routePlanner.destination {
            set(&rows, 3, labelLeft: label("DEST"), labelRight: label("DIST"),
                left: data(String(destination.name.uppercased().prefix(10)), .white),
                right: data(routePlanner.distanceToGoNm(from: location).map(distance) ?? "----"))
            if let ete = routePlanner.timeEnroute(from: location, groundSpeedKts: flightData.groundSpeedKts) {
                set(&rows, 4, labelLeft: label("ETE"), labelRight: label("ETA"),
                    left: data(duration(ete)), right: data(utc(Date().addingTimeInterval(ete))))
            }
        } else {
            set(&rows, 3, center: data("NO DESTINATION", .white, small: true))
        }

        // The offline-data status shares the label line with POSITION: the
        // position itself takes most of the data line's 24 columns.
        var offline: [MCDURun] = []
        if routePlanner.transportMode == .plane {
            let ready = packs.activePack?.isComplete ?? false
            offline = data(ready ? "OFFLINE OK" : "NO OFFLINE", ready ? .green : .amber, small: true)
        }
        set(&rows, 5, labelLeft: label("POSITION"), labelRight: offline,
            left: data(location.map { position($0.coordinate) } ?? "NO GPS", location == nil ? .amber : .green,
                       small: true))
        let flight = routePlanner.flightPlan?.title
        return titleRuns(style.title(.progress), flight)
    }

    // MARK: - SETTINGS

    private func settingsPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        let units: [SpeedUnit] = [.kmh, .mph, .knots]
        set(&rows, 0, labelLeft: label("SPEED UNIT"), labelRight: label("STORED"),
            left: choice(["KMH", "MPH", "KT"], selected: units.firstIndex(of: flightData.speedUnit) ?? 0),
            right: prompt("FLIGHTS>"))
        set(&rows, 1, labelLeft: label("V/S UNIT"),
            left: choice(["M/S", "FT/MIN"], selected: flightData.verticalSpeedUnit == .ms ? 0 : 1),
            right: prompt("CREDITS>"))
        set(&rows, 2, labelLeft: label("FLIGHT DECK"),
            left: choice(["A320", "B737"], selected: flightData.displayStyle == .airbus ? 0 : 1))
        if routePlanner.transportMode == .plane {
            set(&rows, 3, labelLeft: label("ROLL"), left: data("TURN RATE", .green, small: true))
            set(&rows, 4, labelLeft: label("SPEED LIMIT"), left: data("N/A IN FLIGHT", .white, small: true))
        } else {
            set(&rows, 3, labelLeft: label("ROLL"),
                left: choice(["LAT G", "TILT"], selected: flightData.rollSource == .lateralAcceleration ? 0 : 1))
            set(&rows, 4, labelLeft: label("SPEED LIMIT"),
                left: choice(["ON", "OFF"], selected: speedLimits.isEnabled ? 0 : 1),
                right: speedLimits.isEnabled
                    ? data(speedLimits.limitKts.map { speed($0) } ?? (speedLimits.isUnrestricted ? "NONE" : "---"),
                           .green)
                    : [])
            rows[8].right = speedLimits.isEnabled ? label("LIMIT") : []
        }
        set(&rows, 5, labelLeft: label("ATTITUDE ZERO"),
            labelRight: flightData.isCalibrated ? label("MOUNT") : label("VERTICAL"),
            left: prompt("<SET"), right: flightData.isCalibrated ? action("RESET") : [])
        return titleRuns(style.title(.settings))
    }

    private func settingsSelect(left: Bool, index: Int) {
        switch (left, index) {
        case (true, 0):
            let units: [SpeedUnit] = [.kmh, .mph, .knots]
            let i = units.firstIndex(of: flightData.speedUnit) ?? 0
            flightData.speedUnit = units[(i + 1) % units.count]
        case (false, 0): show(.flights)
        case (true, 1):
            flightData.verticalSpeedUnit = flightData.verticalSpeedUnit == .ms ? .fpm : .ms
        case (false, 1): show(.credits)
        case (true, 2):
            flightData.displayStyle = flightData.displayStyle == .airbus ? .boeing : .airbus
        case (true, 3):
            guard routePlanner.transportMode.isRoad else { return flash("NOT ALLOWED") }
            flightData.rollSource = flightData.rollSource == .lateralAcceleration ? .tilt : .lateralAcceleration
        case (true, 4):
            guard routePlanner.transportMode.isRoad else { return flash("NOT ALLOWED") }
            speedLimits.isEnabled.toggle()
        case (true, 5):
            flightData.calibrate()
            flash("ATTITUDE ZERO SET")
        case (false, 5):
            if flightData.isCalibrated {
                flightData.clearCalibration()
                flash("ATTITUDE ZERO RESET")
            }
        default:
            break
        }
    }

    // MARK: - STORED FLIGHTS

    private var visiblePacks: ArraySlice<FlightPack> {
        let all = packs.packs
        let start = min(subpage * 5, all.count)
        return all[start..<min(start + 5, all.count)]
    }

    private func flightsPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        let list = Array(visiblePacks)
        if list.isEmpty {
            set(&rows, 2, center: data("NO STORED FLIGHTS", .white, small: true))
        }
        for (i, pack) in list.enumerated() {
            let status: [MCDURun]
            if pack.id == packs.activePackID {
                status = data("ACTIVE", .green)
            } else if packs.progress?.planID == pack.id {
                status = data("DNLD", .white)
            } else {
                status = pack.isComplete ? data("READY", .cyan) : data("RESUME", .amber)
            }
            let size = ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file).uppercased()
            set(&rows, i, labelLeft: label("\(dayMonth(pack.plan.date))  \(size)"),
                left: prompt("<" + pack.plan.summary.replacingOccurrences(of: " → ", with: "-")
                    .replacingOccurrences(of: "  ", with: " ")),
                right: status)
        }
        set(&rows, 5, labelLeft: list.isEmpty ? [] : label(style.isBoeing ? "DEL+LSK: DELETE" : "CLR+LSK: DELETE"),
            left: prompt(style.isBoeing ? "<RTE" : "<INIT"))
        return titleRuns(style.title(.flights))
    }

    private func flightsSelect(left: Bool, index: Int) {
        if index == 5 {
            if left { show(.route) }
            return
        }
        let list = Array(visiblePacks)
        guard list.indices.contains(index) else { return }
        let pack = list[index]
        if isClearCommand {
            clearScratchpad()
            packs.delete(pack.id)
            if routePlanner.flightPlan?.id == pack.id { routePlanner.clearRoute() }
            return flash("FLIGHT DELETED")
        }
        if pack.isComplete {
            activate(pack)
        } else {
            resume(pack)
        }
    }

    // MARK: - CREDITS

    static let creditLines: [String] = {
        let text = [
            "FLIGHTDECK IS FOR FUN:",
            "NOT A NAVIGATION AID.",
            "",
            "ROAD SPEED LIMITS",
            "(C) OPENSTREETMAP",
            "CONTRIBUTORS, ODBL.",
            "FLIGHT ROUTES: ADSBDB.COM",
            "(VIRTUAL RADAR SERVER",
            "DATA, CC0), HEXDB.IO.",
            "FLIGHT TRACKS CONTAIN",
            "DATA FROM ADSB.LOL,",
            "ODBL 1.0.",
            "AIRPORTS, RWYS, NAVAIDS:",
            "OURAIRPORTS",
            "(PUBLIC DOMAIN).",
            "AIRLINE CODES: WIKIDATA",
            "TERRAIN: AWS OPEN DATA",
            "TERRAIN TILES - USGS",
            "3DEP, SRTM, GMTED2010;",
            "NOAA ETOPO1; COPERNICUS",
            "EU-DEM; ARCTICDEM;",
            "GEOSCIENCE AUSTRALIA;",
            "DGM OSTERREICH; OGL",
            "CANADA; INEGI; LINZ;",
            "KARTVERKET; (C) ENV.",
            "AGENCY (UK).",
            "ROUTES: APPLE MAPS.",
        ]
        return text
    }()

    private func creditsPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        let lines = Self.creditLines.dropFirst(subpage * 10).prefix(10)
        for (i, line) in lines.enumerated() {
            rows[i] = MCDULine(left: [MCDURun(text: line, color: i % 2 == 0 ? .white : .white, small: true)])
        }
        rows[11] = MCDULine(left: prompt("<RETURN"))
        return titleRuns(style.title(.credits))
    }
}
