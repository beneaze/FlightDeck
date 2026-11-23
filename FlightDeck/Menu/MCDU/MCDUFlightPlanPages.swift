import Foundation
import CoreLocation

/// Flight-plan entry, as on the real units: the F-PLN (Airbus) / RTE LEGS
/// (Boeing) page takes waypoints from the scratchpad, the line-select key
/// beside the origin opens the departures and the one beside the
/// destination the arrivals.
///
/// The bundled database has every runway but no published procedures
/// (there is no free source for them), so the departure is a climb on
/// runway heading to 1500 ft above the field and the approach a straight
/// 3° final onto the runway — see ``FlightPlan/legs``. The pages say so
/// rather than list SIDs and STARs that do not exist.
extension MCDUController {

    /// One line of the F-PLN page.
    enum FlightPlanLine {
        /// A fix of the plan, by index into ``FlightPlan/legs``.
        case leg(Int)
        /// Top of climb / descent, between fixes (Airbus only).
        case pseudo(String, alongNm: Double)
    }

    /// The F-PLN page shows the plan being set up — on the ground, or for a
    /// flight not active yet. Once the active flight is airborne it shows
    /// live distances and times instead.
    var isEditingFlightPlan: Bool {
        guard routePlanner?.transportMode == .plane, let draft = draftPlan else { return false }
        let isActive = routePlanner.flightPlan?.routeKey == draft.routeKey
        return !(isActive && (flightData?.groundSpeedKts ?? 0) > 50)
    }

    /// Lines of the plan being edited, the destination left out: it has a
    /// line of its own at the bottom of the page.
    var flightPlanLines: [FlightPlanLine] {
        guard let plan = draftPlan else { return [] }
        let distances = plan.legDistancesNm
        var lines: [FlightPlanLine] = []
        var pseudo: [(String, Double)] = style.isBoeing ? [] : [("(T/C)", plan.topOfClimbNm), ("(T/D)", plan.topOfDescentNm)]
        for index in plan.legs.indices.dropLast() {
            while let next = pseudo.first, next.1 < distances[index] {
                lines.append(.pseudo(next.0, alongNm: next.1))
                pseudo.removeFirst()
            }
            lines.append(.leg(index))
        }
        for (name, nm) in pseudo where nm < plan.totalDistanceNm {
            lines.append(.pseudo(name, alongNm: nm))
        }
        return lines
    }

    // MARK: - F-PLN / RTE LEGS (editing)

    func plannedFlightPlanPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        guard let plan = draftPlan else { return [] }
        let legs = plan.legs, distances = plan.legDistancesNm
        for (row, line) in flightPlanLines.dropFirst(subpage * 5).prefix(5).enumerated() {
            switch line {
            case .leg(let index):
                let fix = legs[index]
                var legLabel: [MCDURun] = []
                if index == 0 {
                    legLabel = label(style.isBoeing ? "" : "FROM")
                } else {
                    let course = GreatCircle.initialCourse(legs[index - 1].coordinate, fix.coordinate)
                    let legNm = distances[index] - distances[index - 1]
                    legLabel = label(String(format: style.isBoeing ? "%03.0f°" : "C%03.0f°", course)
                                     + "  " + distance(legNm))
                }
                set(&rows, row, labelLeft: legLabel,
                    left: data(lineIdent(fix, plan: plan), index == 0 ? .white : (style.isBoeing ? .white : .green)),
                    right: altitudeRuns(fix, plannedFt: plan.plannedAltitudeFt(atNm: distances[index])))
            case .pseudo(let name, let nm):
                set(&rows, row, left: data(name, .green),
                    right: data(altitude(plan.plannedAltitudeFt(atNm: nm)), .green, small: true))
            }
        }
        if let last = legs.last {
            set(&rows, 5, labelLeft: label("DEST"), labelRight: label("DIST"),
                left: data(lineIdent(last, plan: plan), .white),
                right: data(distance(plan.totalDistanceNm), .green))
        }
        return titleRuns(style.isBoeing ? "RTE LEGS" : "F-PLN", plan.title)
    }

    /// "EDDM26R" for the origin's runway on the Airbus unit, else the fix's
    /// own ident.
    private func lineIdent(_ fix: FlightPlan.Fix, plan: FlightPlan) -> String {
        guard !style.isBoeing else { return fix.ident }
        switch fix.kind {
        case .origin: return plan.departureRunway.map { plan.origin.icao + $0.ident } ?? fix.ident
        case .destination: return plan.approachRunway.map { plan.destination.icao + $0.ident } ?? fix.ident
        default: return fix.ident
        }
    }

    /// A constraint in magenta, else the predicted altitude small.
    private func altitudeRuns(_ fix: FlightPlan.Fix, plannedFt: Double) -> [MCDURun] {
        if let constraint = fix.altitudeFt, fix.kind == .approach || fix.kind == .departure {
            return data(altitude(constraint), .magenta)
        }
        return data(altitude(plannedFt), style.isBoeing ? .cyan : .green, small: true)
    }

    func plannedFlightPlanSelect(left: Bool, index: Int) {
        guard left, let plan = draftPlan else { return }
        let legs = plan.legs
        // Which fix the key is beside.
        let legIndex: Int
        if index == 5 {
            legIndex = legs.count - 1
        } else {
            let lines = Array(flightPlanLines.dropFirst(subpage * 5).prefix(5))
            guard lines.indices.contains(index) else { return }
            guard case .leg(let i) = lines[index] else { return flash("NOT ALLOWED") }
            legIndex = i
        }
        let fix = legs[legIndex]

        if isClearCommand {
            clearScratchpad()
            switch fix.kind {
            case .enroute:
                if let i = enrouteIndex(ofLeg: legIndex, in: plan), enroute.indices.contains(i) { enroute.remove(at: i) }
            case .origin, .departure:
                guard departureRunway != nil else { return flash("NOT ALLOWED") }
                departureRunway = nil
            case .approach, .destination:
                guard approachRunway != nil else { return flash("NOT ALLOWED") }
                approachRunway = nil
            }
            refreshPlan()
            return
        }

        if let entry = takeEntry() {
            // A waypoint goes in before the fix it is entered on, as on the
            // Boeing unit; entered on the origin it is not allowed.
            guard legIndex > 0 else { return flash("NOT ALLOWED") }
            let reference = legs[legIndex - 1].coordinate
            guard let newFix = NavDatabase.shared.fix(for: entry, near: reference) else {
                return flash("NOT IN DATA BASE")
            }
            let position = insertionIndex(beforeLeg: legIndex, in: plan)
            enroute.insert(newFix, at: position)
            refreshPlan()
            return
        }

        switch fix.kind {
        case .origin, .departure: show(.departure)
        case .approach, .destination: show(.arrival)
        case .enroute: put(fix.ident)
        }
    }

    /// Legs before the entered waypoints: the origin, and the climb-out
    /// when a runway is set.
    private func departureLegCount(_ plan: FlightPlan) -> Int { plan.departureRunway == nil ? 1 : 2 }

    private func enrouteIndex(ofLeg leg: Int, in plan: FlightPlan) -> Int? {
        let i = leg - departureLegCount(plan)
        return (0..<enroute.count).contains(i) ? i : nil
    }

    private func insertionIndex(beforeLeg leg: Int, in plan: FlightPlan) -> Int {
        max(0, min(enroute.count, leg - departureLegCount(plan)))
    }

    // MARK: - DEPARTURES / ARRIVALS

    private static let runwaysPerPage = 4

    private func visibleRunways(at airport: Airport) -> [Runway] {
        Array(NavDatabase.shared.runways(at: airport).dropFirst(subpage * Self.runwaysPerPage).prefix(Self.runwaysPerPage))
    }

    private func lengthText(_ runway: Runway) -> String {
        style.isBoeing ? "\(Int(runway.lengthFt))FT" : "\(Int((runway.lengthFt * 0.3048).rounded()))M"
    }

    func departurePage(_ rows: inout [MCDULine]) -> [MCDURun] {
        guard let origin else {
            set(&rows, 2, center: data("NO ORIGIN", .white))
            set(&rows, 5, left: prompt(style.isBoeing ? "<INDEX" : "<RETURN"))
            return titleRuns(style.title(.departure))
        }
        procedurePage(&rows, airport: origin, selected: departureRunway, isDeparture: true)
        return style.isBoeing ? titleRuns(origin.icao + " DEPARTURES") : titleRuns(style.title(.departure), origin.icao)
    }

    func arrivalPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        guard let destination else {
            set(&rows, 2, center: data("NO DESTINATION", .white))
            set(&rows, 5, left: prompt(style.isBoeing ? "<INDEX" : "<RETURN"))
            return titleRuns(style.title(.arrival))
        }
        procedurePage(&rows, airport: destination, selected: approachRunway, isDeparture: false)
        return style.isBoeing ? titleRuns(destination.icao + " ARRIVALS") : titleRuns(style.title(.arrival), destination.icao)
    }

    /// Both units list the runways (for an arrival, the runway approaches)
    /// and the procedures. Airbus: the selection on the first line, the
    /// list below with its course. Boeing: procedures left, runways right,
    /// `<SEL>` beside the chosen one.
    private func procedurePage(_ rows: inout [MCDULine], airport: Airport, selected: Runway?, isDeparture: Bool) {
        let runways = visibleRunways(at: airport)
        let name: (Runway) -> String = { isDeparture ? $0.ident : $0.fixIdent }
        if runways.isEmpty, subpage == 0 {
            set(&rows, 2, center: data("NO RWY IN DATA BASE", .amber, small: true))
        }
        if style.isBoeing {
            for (row, runway) in runways.enumerated() {
                let isSelected = runway == selected
                set(&rows, row,
                    labelLeft: row == 0 ? label(isDeparture ? "SIDS" : "STARS") : [],
                    labelRight: row == 0 ? label(isDeparture ? "RUNWAYS" : "APPROACHES") : [],
                    left: row == 0 ? data(isDeparture ? "NONE" : "NONE", .white, small: true) : [],
                    right: isSelected ? data("<SEL> ", .green, small: true) + data(name(runway), .green)
                                      : prompt(name(runway)))
            }
            set(&rows, 4, labelLeft: label(isDeparture ? "NO SIDS IN DATA BASE" : "NO STARS IN DATA BASE"))
            set(&rows, 5, left: prompt("<INDEX"), right: prompt("ROUTE>"))
        } else {
            let selection = selected.map { data(name($0), .green) } ?? data("------", .white)
            rows[0] = MCDULine(left: label(isDeparture ? "RWY" : "APPR"), center: label(isDeparture ? "SID" : "VIA"),
                               right: label(isDeparture ? "TRANS" : "STAR"))
            rows[1] = MCDULine(left: selection, center: data("NONE", .white, small: true),
                               right: data("NONE", .white, small: true))
            for (i, runway) in runways.enumerated() {
                let course = String(format: "CRS%03.0f", runway.headingDeg)
                set(&rows, i + 1,
                    labelLeft: label(course + (isDeparture ? "" : "  3.0°")),
                    left: [MCDURun(text: "<" + name(runway), color: runway == selected ? .green : .white)],
                    right: data(lengthText(runway), .white, small: true))
            }
            set(&rows, 5, labelRight: label(isDeparture ? "NO SID IN DATA BASE" : "NO STAR IN DATA BASE"),
                left: prompt("<RETURN"), right: prompt("F-PLN>"))
        }
    }

    func departureSelect(left: Bool, index: Int) { procedureSelect(left: left, index: index, isDeparture: true) }
    func arrivalSelect(left: Bool, index: Int) { procedureSelect(left: left, index: index, isDeparture: false) }

    private func procedureSelect(left: Bool, index: Int, isDeparture: Bool) {
        if index == 5 {
            if left {
                show(style.isBoeing ? .depArr : .flightPlan)
            } else {
                show(.flightPlan)
            }
            return
        }
        guard let airport = isDeparture ? origin : destination else { return }
        let runways = visibleRunways(at: airport)
        // Airbus: list on the left from line 2; Boeing: runways on the right from line 1.
        let row = style.isBoeing ? index : index - 1
        guard left != style.isBoeing, runways.indices.contains(row) else {
            if isClearCommand {
                clearScratchpad()
                if isDeparture { departureRunway = nil } else { approachRunway = nil }
                refreshPlan()
            }
            return
        }
        let runway = runways[row]
        if isDeparture {
            departureRunway = departureRunway == runway ? nil : runway
        } else {
            approachRunway = approachRunway == runway ? nil : runway
        }
        refreshPlan()
    }

    // MARK: - DEP/ARR INDEX (Boeing)

    func depArrPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        rows[0] = MCDULine(center: label("RTE 1"))
        rows[1] = MCDULine(left: origin != nil ? prompt("<DEP") : [],
                           center: data(origin?.icao ?? "----", origin == nil ? .white : .green))
        rows[3] = MCDULine(center: data(destination?.icao ?? "----", destination == nil ? .white : .green),
                           right: destination != nil ? prompt("ARR>") : [])
        if origin == nil, destination == nil {
            set(&rows, 3, center: data("ENTER FROM/TO ON RTE", .white, small: true))
        }
        return titleRuns(style.title(.depArr))
    }

    func depArrSelect(left: Bool, index: Int) {
        switch (left, index) {
        case (true, 0): if origin != nil { show(.departure) }
        case (false, 1): if destination != nil { show(.arrival) }
        default: break
        }
    }
}
