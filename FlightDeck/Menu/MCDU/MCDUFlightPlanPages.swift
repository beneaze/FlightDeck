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
        case .origin: return plan.departureRunway.map { plan.origin.icao + $0.designator } ?? fix.ident
        case .destination: return plan.approachRunway.map { plan.destination.icao + $0.designator } ?? fix.ident
        default: return fix.ident
        }
    }

    /// A constraint in magenta, else the predicted altitude small.
    private func altitudeRuns(_ fix: FlightPlan.Fix, plannedFt: Double) -> [MCDURun] {
        if let constraint = fix.altitudeFt, [.approach, .departure, .arrival].contains(fix.kind) {
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
                if sidName != nil {
                    sidName = nil
                    sidTransition = nil
                } else if departureRunway != nil {
                    departureRunway = nil
                } else {
                    return flash("NOT ALLOWED")
                }
            case .arrival:
                starName = nil
                starTransition = nil
            case .approach, .destination:
                if approachName != nil {
                    approachName = nil
                    approachVia = nil
                } else if approachRunway != nil {
                    approachRunway = nil
                } else {
                    return flash("NOT ALLOWED")
                }
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
        case .arrival, .approach, .destination: show(.arrival)
        case .enroute: put(fix.ident)
        }
    }

    /// Legs before the entered waypoints: the origin, and the climb-out
    /// when a runway is set.
    private func departureLegCount(_ plan: FlightPlan) -> Int {
        plan.legs.prefix { $0.kind == .origin || $0.kind == .departure }.count
    }

    private func enrouteIndex(ofLeg leg: Int, in plan: FlightPlan) -> Int? {
        let i = leg - departureLegCount(plan)
        return (0..<enroute.count).contains(i) ? i : nil
    }

    private func insertionIndex(beforeLeg leg: Int, in plan: FlightPlan) -> Int {
        max(0, min(enroute.count, leg - departureLegCount(plan)))
    }

    // MARK: - DEPARTURES / ARRIVALS

    /// One selectable line of a DEPARTURES / ARRIVALS list.
    struct ProcedureItem {
        let title: String
        var detail = ""
        var label = ""
        let isSelected: Bool
        let select: () -> Void
    }

    static let procedureLinesPerPage = 4

    private func lengthText(_ runway: Runway) -> String {
        style.isBoeing ? "\(Int(runway.lengthFt))FT" : "\(Int((runway.lengthFt * 0.3048).rounded()))M"
    }

    private func approachTitle(_ ident: String) -> String {
        ProcedureDatabase.approachName(ident, boeing: style.isBoeing)
    }

    // Departure lists

    private var runwayItems: [ProcedureItem] {
        guard let origin else { return [] }
        return NavDatabase.shared.runways(at: origin).map { runway in
            ProcedureItem(title: runway.designator, detail: lengthText(runway),
                          label: String(format: "CRS%03.0f", runway.headingDeg),
                          isSelected: runway == departureRunway) { [unowned self] in
                departureRunway = departureRunway == runway ? nil : runway
                // A SID that does not serve the new runway goes.
                if let sid = sidName, !procedures(at: origin).sids(from: departureRunway).contains(sid) {
                    sidName = nil
                    sidTransition = nil
                }
                refreshPlan()
                if departureRunway != nil, !procedures(at: origin).sids(from: departureRunway).isEmpty {
                    departureList = .sids
                    subpage = 0
                }
            }
        }
    }

    private var sidItems: [ProcedureItem] {
        let available = procedures(at: origin).sids(from: departureRunway)
        var items = [ProcedureItem(title: "NO SID", isSelected: sidName == nil) { [unowned self] in
            sidName = nil
            sidTransition = nil
            refreshPlan()
        }]
        items += available.map { name in
            ProcedureItem(title: name, isSelected: name == sidName) { [unowned self] in
                sidName = sidName == name ? nil : name
                sidTransition = nil
                refreshPlan()
                if sidName != nil, let t = procedures(at: origin).sids[name],
                   !TerminalProcedures.enrouteTransitions(t).isEmpty {
                    departureList = .transitions
                    subpage = 0
                }
            }
        }
        return items
    }

    private var sidTransitionItems: [ProcedureItem] {
        guard let sidName, let t = procedures(at: origin).sids[sidName] else { return [] }
        return [ProcedureItem(title: "NO TRANS", isSelected: sidTransition == nil) { [unowned self] in
            sidTransition = nil
            refreshPlan()
        }] + TerminalProcedures.enrouteTransitions(t).map { name in
            ProcedureItem(title: name, isSelected: name == sidTransition) { [unowned self] in
                sidTransition = sidTransition == name ? nil : name
                refreshPlan()
            }
        }
    }

    // Arrival lists

    private var approachItems: [ProcedureItem] {
        guard let destination else { return [] }
        let published = procedures(at: destination).approaches.keys.sorted {
            // Precision approaches first, then by runway.
            let order = "IRHLDVSNQBXUPG"
            let a = order.firstIndex(of: $0.first ?? "Z") ?? order.endIndex
            let b = order.firstIndex(of: $1.first ?? "Z") ?? order.endIndex
            return a != b ? a < b : $0 < $1
        }
        if !published.isEmpty {
            return published.map { ident in
                ProcedureItem(title: approachTitle(ident),
                              label: ProcedureDatabase.approachRunway(ident).map { "RWY " + $0 } ?? "CIRCLING",
                              isSelected: ident == approachName) { [unowned self] in
                    chooseApproach(approachName == ident ? nil : ident)
                    if approachName != nil, !procedures(at: destination).vias(ident).isEmpty {
                        arrivalList = .vias
                        subpage = 0
                    }
                }
            }
        }
        // No published approaches: a straight-in 3° final to each runway.
        return NavDatabase.shared.runways(at: destination).map { runway in
            ProcedureItem(title: runway.fixIdent, detail: lengthText(runway),
                          label: String(format: "CRS%03.0f  3.0°", runway.headingDeg),
                          isSelected: approachName == nil && runway == approachRunway) { [unowned self] in
                approachName = nil
                approachVia = nil
                approachRunway = approachRunway == runway ? nil : runway
                refreshPlan()
            }
        }
    }

    private var viaItems: [ProcedureItem] {
        guard let approachName else { return [] }
        return [ProcedureItem(title: "NO VIA", isSelected: approachVia == nil) { [unowned self] in
            approachVia = nil
            refreshPlan()
        }] + procedures(at: destination).vias(approachName).map { name in
            ProcedureItem(title: name, isSelected: name == approachVia) { [unowned self] in
                approachVia = approachVia == name ? nil : name
                refreshPlan()
            }
        }
    }

    private var starItems: [ProcedureItem] {
        [ProcedureItem(title: "NO STAR", isSelected: starName == nil) { [unowned self] in
            starName = nil
            starTransition = nil
            refreshPlan()
        }] + procedures(at: destination).stars.keys.sorted().map { name in
            ProcedureItem(title: name, isSelected: name == starName) { [unowned self] in
                starName = starName == name ? nil : name
                starTransition = nil
                refreshPlan()
                if starName != nil, let t = procedures(at: destination).stars[name],
                   !TerminalProcedures.enrouteTransitions(t).isEmpty {
                    arrivalList = .transitions
                    subpage = 0
                }
            }
        }
    }

    private var starTransitionItems: [ProcedureItem] {
        guard let starName, let t = procedures(at: destination).stars[starName] else { return [] }
        return [ProcedureItem(title: "NO TRANS", isSelected: starTransition == nil) { [unowned self] in
            starTransition = nil
            refreshPlan()
        }] + TerminalProcedures.enrouteTransitions(t).map { name in
            ProcedureItem(title: name, isSelected: name == starTransition) { [unowned self] in
                starTransition = starTransition == name ? nil : name
                refreshPlan()
            }
        }
    }

    /// The lists on screen: Airbus one (left), Boeing two (left, right).
    var procedureLists: (left: [ProcedureItem], right: [ProcedureItem]) {
        switch (page, style.isBoeing) {
        case (.departure, false):
            switch departureList {
            case .runways: return (runwayItems, [])
            case .sids: return (sidItems, [])
            case .transitions: return (sidTransitionItems, [])
            }
        case (.departure, true):
            return (departureList == .transitions ? sidTransitionItems : sidItems, runwayItems)
        case (.arrival, false):
            switch arrivalList {
            case .approaches: return (approachItems, [])
            case .vias: return (viaItems, [])
            case .stars: return (starItems, [])
            case .transitions: return (starTransitionItems, [])
            }
        case (.arrival, true):
            return (arrivalList == .transitions ? starTransitionItems : starItems,
                    arrivalList == .vias ? viaItems : approachItems)
        default:
            return ([], [])
        }
    }

    private func visible(_ items: [ProcedureItem]) -> [ProcedureItem] {
        Array(items.dropFirst(subpage * Self.procedureLinesPerPage).prefix(Self.procedureLinesPerPage))
    }

    func departurePage(_ rows: inout [MCDULine]) -> [MCDURun] {
        guard let origin else {
            set(&rows, 2, center: data("NO ORIGIN", .white))
            set(&rows, 5, left: prompt(style.isBoeing ? "<INDEX" : "<RETURN"))
            return titleRuns(style.title(.departure))
        }
        if style.isBoeing {
            boeingProcedurePage(&rows, leftHeader: departureList == .transitions ? "TRANS" : "SIDS",
                                rightHeader: "RUNWAYS",
                                leftSwitch: departureList == .transitions ? "<SIDS" : (sidName != nil ? "<TRANS" : nil),
                                rightSwitch: nil)
            return titleRuns(origin.icao + " DEPARTURES")
        }
        let header: String
        switch departureList {
        case .runways: header = "AVAILABLE RUNWAYS"
        case .sids: header = "SIDS"
        case .transitions: header = "TRANS"
        }
        airbusProcedurePage(&rows, labels: ("RWY", "SID", "TRANS"),
                            values: (departureRunway?.designator, sidName ?? (departureRunway == nil ? nil : "NONE"),
                                     sidTransition ?? (sidName == nil ? nil : "NONE")),
                            header: header)
        return titleRuns(style.title(.departure), origin.icao)
    }

    func arrivalPage(_ rows: inout [MCDULine]) -> [MCDURun] {
        guard let destination else {
            set(&rows, 2, center: data("NO DESTINATION", .white))
            set(&rows, 5, left: prompt(style.isBoeing ? "<INDEX" : "<RETURN"))
            return titleRuns(style.title(.arrival))
        }
        if style.isBoeing {
            boeingProcedurePage(&rows, leftHeader: arrivalList == .transitions ? "TRANS" : "STARS",
                                rightHeader: arrivalList == .vias ? "TRANS" : "APPROACHES",
                                leftSwitch: arrivalList == .transitions ? "<STARS" : (starName != nil ? "<TRANS" : nil),
                                rightSwitch: arrivalList == .vias ? "APPROACHES>" : (approachName != nil ? "TRANS>" : nil))
            return titleRuns(destination.icao + " ARRIVALS")
        }
        let header: String
        switch arrivalList {
        case .approaches: header = "APPR AVAILABLE"
        case .vias: header = "APPR VIAS"
        case .stars: header = "STARS"
        case .transitions: header = "TRANS"
        }
        let approachText = approachName.map(approachTitle) ?? approachRunway?.fixIdent
        airbusProcedurePage(&rows, labels: ("APPR", "VIA", "STAR"),
                            values: (approachText, approachVia ?? (approachName == nil ? nil : "NONE"),
                                     starName.map { name in starTransition.map { name + "." + $0 } ?? name } ?? "NONE"),
                            header: header)
        return titleRuns(style.title(.arrival), destination.icao)
    }

    /// Airbus: the selections on the first line, one list below (R1 steps
    /// to the next list, L1 back to the first), its name above the bottom.
    private func airbusProcedurePage(_ rows: inout [MCDULine], labels: (String, String, String),
                                     values: (String?, String?, String?), header: String) {
        func value(_ v: String?) -> [MCDURun] { v.map { data(String($0.prefix(8)), .green) } ?? data("------", .white) }
        rows[0] = MCDULine(left: label(labels.0), center: label(labels.1), right: label(labels.2))
        rows[1] = MCDULine(left: value(values.0), center: value(values.1), right: value(values.2) + prompt(">"))
        let items = visible(procedureLists.left)
        if items.isEmpty, subpage == 0 {
            set(&rows, 2, center: data(page == .departure ? "NO RWY IN DATA BASE" : "NONE IN DATA BASE",
                                       .amber, small: true))
        }
        for (i, item) in items.enumerated() {
            set(&rows, i + 1, labelLeft: label(item.label),
                left: [MCDURun(text: (item.isSelected ? " " : "<") + item.title, color: item.isSelected ? .green : .white)],
                right: item.detail.isEmpty ? [] : data(item.detail, .white, small: true))
        }
        set(&rows, 5, labelLeft: label(header), left: prompt("<RETURN"), right: prompt("F-PLN>"))
    }

    /// Boeing: procedures left, runways or approaches right, `<SEL>` beside
    /// the chosen ones; line 5 switches a column to its transitions.
    private func boeingProcedurePage(_ rows: inout [MCDULine], leftHeader: String, rightHeader: String,
                                     leftSwitch: String?, rightSwitch: String?) {
        let lists = procedureLists
        let left = visible(lists.left), right = visible(lists.right)
        for row in 0..<Self.procedureLinesPerPage {
            var leftRuns: [MCDURun] = [], rightRuns: [MCDURun] = []
            if row < left.count {
                let item = left[row]
                leftRuns = item.isSelected ? data(item.title, .green) + data(" <SEL>", .green, small: true)
                                           : prompt(item.title)
            }
            if row < right.count {
                let item = right[row]
                rightRuns = item.isSelected ? data("<SEL> ", .green, small: true) + data(item.title, .green)
                                            : prompt(item.title)
            }
            set(&rows, row, labelLeft: row == 0 ? label(leftHeader) : [],
                labelRight: row == 0 ? label(rightHeader) : [], left: leftRuns, right: rightRuns)
        }
        set(&rows, 4, left: leftSwitch.map(prompt) ?? [], right: rightSwitch.map(prompt) ?? [])
        set(&rows, 5, left: prompt("<INDEX"), right: prompt("ROUTE>"))
    }

    func departureSelect(left: Bool, index: Int) { procedureSelect(left: left, index: index) }
    func arrivalSelect(left: Bool, index: Int) { procedureSelect(left: left, index: index) }

    private func procedureSelect(left: Bool, index: Int) {
        if index == 5 {
            show(left && style.isBoeing ? .depArr : .flightPlan)
            return
        }
        let lists = procedureLists
        if style.isBoeing {
            if index == 4 {
                if left {
                    if page == .departure {
                        departureList = departureList == .transitions ? .sids : (sidName != nil ? .transitions : .sids)
                    } else {
                        arrivalList = arrivalList == .transitions ? .stars : (starName != nil ? .transitions : .stars)
                    }
                } else if page == .arrival {
                    arrivalList = arrivalList == .vias ? .approaches : (approachName != nil ? .vias : .approaches)
                }
                subpage = 0
                return
            }
            let items = visible(left ? lists.left : lists.right)
            guard items.indices.contains(index) else { return }
            items[index].select()
            return
        }
        // Airbus.
        if index == 0 {
            if left {
                if page == .departure { departureList = .runways } else { arrivalList = .approaches }
            } else if page == .departure {
                switch departureList {
                case .runways: departureList = .sids
                case .sids: departureList = sidName != nil ? .transitions : .runways
                case .transitions: departureList = .runways
                }
            } else {
                switch arrivalList {
                case .approaches: arrivalList = approachName != nil ? .vias : .stars
                case .vias: arrivalList = .stars
                case .stars: arrivalList = starName != nil ? .transitions : .approaches
                case .transitions: arrivalList = .approaches
                }
            }
            subpage = 0
            return
        }
        guard left else { return }
        let items = visible(lists.left)
        guard items.indices.contains(index - 1) else { return }
        items[index - 1].select()
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
