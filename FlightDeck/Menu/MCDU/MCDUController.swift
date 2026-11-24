import SwiftUI
import MapKit

/// The MCDU's brain: which page is up, what is in the scratchpad, and the
/// flight / route set up through it. Keys arrive through ``press(_:)``; the
/// page content and the line-select actions live in MCDUPages.swift.
///
/// It is owned by the root view and outlives the MCDU being shown, so an
/// entry made before closing it is still there when it is opened again.
@MainActor
final class MCDUController: ObservableObject {

    // MARK: Page and scratchpad

    @Published var page: MCDUPage = .menu
    /// Which screenful of a multi-page list is up (NEXT/PREV PAGE).
    @Published var subpage = 0
    @Published private(set) var scratchpad = ""
    /// A message shown in the scratchpad until CLR or the next key.
    @Published private(set) var message: (text: String, amber: Bool)?

    // MARK: Flight setup (plane mode)

    @Published var flightNumber: String?
    @Published var date = Date()
    @Published var origin: Airport?
    @Published var destination: Airport?
    /// Flight level entered by the crew; nil means the plan's own.
    @Published var cruiseLevel: Int?
    /// Take-off runway, approach runway and the waypoints in between,
    /// entered on the F-PLN / LEGS, DEPARTURE and ARRIVAL pages.
    @Published var departureRunway: Runway?
    @Published var approachRunway: Runway?
    @Published var enroute: [FlightPlan.Fix] = []
    /// Published procedures chosen on DEPARTURES / ARRIVALS: names and
    /// transitions, looked up in ``ProcedureDatabase``.
    @Published var sidName: String?
    @Published var sidTransition: String?
    @Published var starName: String?
    @Published var starTransition: String?
    @Published var approachName: String?
    @Published var approachVia: String?
    /// Which list the DEPARTURES / ARRIVALS page shows.
    @Published var departureList: DepartureList = .runways
    @Published var arrivalList: ArrivalList = .approaches

    enum DepartureList { case runways, sids, transitions }
    enum ArrivalList { case approaches, vias, stars, transitions }
    @Published var lookup: FlightLookupResult?
    @Published var isLookingUp = false
    /// The plan the entries above make, rebuilt whenever one changes.
    @Published private(set) var draftPlan: FlightPlan?

    // MARK: Destination search (car / bike)

    let search = DestinationSearchModel()
    @Published var searchQuery = ""
    @Published var selected: (name: String, coordinate: CLLocationCoordinate2D)?
    @Published var isShowingMap = false

    // MARK: SimBrief

    /// The user's SimBrief username, for INIT REQUEST.
    @Published var simBriefUser: String? = UserDefaults.standard.string(forKey: "simBriefUser") {
        didSet { UserDefaults.standard.set(simBriefUser, forKey: "simBriefUser") }
    }
    @Published private(set) var isRequestingPlan = false

    /// INIT REQUEST: load the latest SimBrief plan into the setup.
    func requestSimBriefPlan() {
        guard let user = simBriefUser else { return flash("ENTER SIMBRIEF USER") }
        guard !isRequestingPlan else { return }
        isRequestingPlan = true
        Task {
            defer { isRequestingPlan = false }
            do {
                apply(try await SimBriefPlan.fetch(username: user))
            } catch {
                flash((error as? SimBriefPlan.FetchError)?.errorDescription ?? "SIMBRIEF NOT AVAIL", amber: true)
            }
        }
    }

    /// Fill the setup from a SimBrief plan: airports, runways, cruise level,
    /// the route's waypoints, and its SID and STAR where the procedure data
    /// has them — otherwise their fixes stay in the plan as waypoints.
    func apply(_ ofp: SimBriefPlan) {
        let airports = AirportDatabase.shared
        guard let from = airports.airport(code: ofp.origin), let to = airports.airport(code: ofp.destination) else {
            return flash("NOT IN DATA BASE", amber: true)
        }
        lookup = nil
        flightNumber = ofp.flightNumber
        setAirports(origin: from, destination: to)
        departureRunway = ofp.departureRunway.flatMap { NavDatabase.shared.runway($0, at: from) }
        approachRunway = ofp.arrivalRunway.flatMap { NavDatabase.shared.runway($0, at: to) }
        if let feet = ofp.cruiseAltitudeFt, (5_000...43_000).contains(feet) {
            cruiseLevel = Int((feet / 100).rounded())
        }

        var waypoints = ofp.fixes
        let departures = procedures(at: from)
        if let sid = ofp.sidName, let transitions = departures.sids[sid],
           departures.sids(from: departureRunway).contains(sid) {
            sidName = sid
            let fixes = ofp.fixes.filter { $0.isProcedure && $0.via == sid }
            // An enroute transition is named after the fix it ends at.
            if let last = fixes.last?.ident, TerminalProcedures.enrouteTransitions(transitions).contains(last) {
                sidTransition = last
            }
            waypoints.removeAll { $0.isProcedure && $0.via == sid }
        }
        let arrivals = procedures(at: to)
        if let star = ofp.starName, let transitions = arrivals.stars[star] {
            starName = star
            let fixes = ofp.fixes.filter { $0.isProcedure && $0.via == star }
            if let first = fixes.first?.ident, TerminalProcedures.enrouteTransitions(transitions).contains(first) {
                starTransition = first
            }
            waypoints.removeAll { $0.isProcedure && $0.via == star }
        }
        // SimBrief names no approach: take the ILS (else the first) to the
        // planned runway, as a crew would brief it.
        if let runway = approachRunway {
            let onRunway = arrivals.approaches.keys.filter {
                ProcedureDatabase.approachRunway($0).map(Runway.designator) == runway.designator
            }.sorted()
            if let approach = onRunway.first(where: { $0.hasPrefix("I") }) ?? onRunway.first {
                approachName = approach
            }
        }
        enroute = waypoints.map {
            FlightPlan.Fix(ident: $0.ident, coordinate: .init(latitude: $0.latitude, longitude: $0.longitude),
                           kind: .enroute)
        }
        refreshPlan()
        flash("SIMBRIEF PLAN LOADED")
    }

    // MARK: X-Plane navigation data

    @Published var isShowingImporter = false
    /// The how-to guide, opened again from MENU.
    @Published var isShowingGuide = false
    @Published private(set) var isImportingNavData = false

    /// Copy the X-Plane navigation data folder the user picked.
    func importNavData(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        isImportingNavData = true
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try XPlaneNavData.shared.importFolder(url) }
            await MainActor.run {
                self.isImportingNavData = false
                switch outcome {
                case .success(let count):
                    self.refreshPlan()
                    self.flash("XP DATA: \(count) AIRPORTS")
                case .failure(let error):
                    let text = (error as? XPlaneNavData.ImportError)?.errorDescription ?? "IMPORT FAILED"
                    self.flash(String(text.uppercased().prefix(22)), amber: true)
                }
            }
        }
    }

    // MARK: Models

    private(set) var routePlanner: RoutePlanner!
    private(set) var flightData: FlightDataModel!
    private(set) var packs: FlightPackStore!
    private(set) var speedLimits: SpeedLimitProvider!
    private let lookupProvider: FlightLookupProvider = DefaultFlightLookup()

    /// Put the MCDU away and return to the displays.
    var close: () -> Void = {}

    func attach(routePlanner: RoutePlanner, flightData: FlightDataModel,
                packs: FlightPackStore, speedLimits: SpeedLimitProvider) {
        self.routePlanner = routePlanner
        self.flightData = flightData
        self.packs = packs
        self.speedLimits = speedLimits
    }

    var isAttached: Bool { routePlanner != nil }
    var style: MCDUStyle { MCDUStyle(flightData?.displayStyle ?? .airbus) }

    // MARK: Keys

    func press(_ key: MCDUKey) {
        switch key {
        case .character(let c): type(String(c))
        case .space: type(" ")
        case .plusMinus:
            if scratchpad.hasSuffix("-") {
                scratchpad.removeLast()
                type("+")
            } else {
                type("-")
            }
        case .clear: clearKey()
        case .delete:
            message = nil
            scratchpad = "DELETE"
        case .page(let target):
            if let target { show(target) } else { flash("NOT ALLOWED") }
        case .previousPage:
            if subpage > 0 { subpage -= 1 }
        case .nextPage:
            subpage += 1
            if subpage >= pageCount { subpage = 0 }
        case .exec: exec()
        case .lsk(let left, let index): lineSelect(left: left, index: index)
        }
    }

    func show(_ target: MCDUPage) {
        page = target
        subpage = 0
        // DEPARTURES / ARRIVALS open on the first choice still to make.
        if target == .departure {
            departureList = departureRunway == nil ? .runways : (sidName == nil ? .sids : .transitions)
        } else if target == .arrival {
            arrivalList = approachName == nil && approachRunway == nil ? .approaches : (starName == nil ? .stars : .transitions)
        }
    }

    /// What the scratchpad line shows.
    var scratchpadText: (text: String, amber: Bool) {
        message ?? (scratchpad, false)
    }

    private func type(_ text: String) {
        message = nil
        if isClearCommand { scratchpad = "" }
        guard scratchpad.count < 22 else { return }
        scratchpad += text
    }

    /// CLR: away with a message first, then one character at a time. On an
    /// empty scratchpad the Airbus unit puts CLR there, which a line-select
    /// key then uses to delete that line's entry.
    private func clearKey() {
        if message != nil {
            message = nil
        } else if isClearCommand {
            scratchpad = ""
        } else if !scratchpad.isEmpty {
            scratchpad.removeLast()
        } else if !style.isBoeing {
            scratchpad = "CLR"
        }
    }

    /// The scratchpad holds a delete command (Airbus CLR, Boeing DELETE).
    var isClearCommand: Bool { scratchpad == "CLR" || scratchpad == "DELETE" }

    /// Empty the scratchpad (after a CLR / DELETE command was used).
    func clearScratchpad() {
        scratchpad = ""
    }

    /// Put text in the scratchpad, as a line-select key does with a fix.
    func put(_ text: String) {
        message = nil
        scratchpad = String(text.prefix(22))
    }

    /// Take the scratchpad's entry, leaving it empty.
    func takeEntry() -> String? {
        let entry = scratchpad.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return nil }
        scratchpad = ""
        return entry
    }

    func flash(_ text: String, amber: Bool = false) {
        message = (text, amber)
    }

    // MARK: EXEC (737)

    /// A downloaded flight that matches the setup but is not the active
    /// one yet: EXEC lights, and pressing it makes the flight active.
    var pendingPack: FlightPack? {
        guard let packs, let plan = draftPlan else { return nil }
        return packs.packs.first {
            $0.isComplete && $0.id != packs.activePackID && $0.plan.routeKey == plan.routeKey
        }
    }

    /// A downloaded flight with the draft plan's path, active or not.
    var readyPack: FlightPack? {
        guard let packs, let plan = draftPlan else { return nil }
        return packs.packs.first { $0.isComplete && $0.plan.routeKey == plan.routeKey }
    }

    var isExecLit: Bool { pendingPack != nil }

    private func exec() {
        guard let pack = pendingPack else { return flash("NOT ALLOWED") }
        activate(pack)
    }

    // MARK: Flight setup actions

    /// Rebuild the draft plan from the entries.
    func refreshPlan() {
        guard let origin, let destination, origin != destination else {
            draftPlan = nil
            return
        }
        let fromLookup = lookup.map { $0.origin == origin && $0.destination == destination } ?? false
        draftPlan = FlightPlan(
            flightNumber: flightNumber,
            callsign: fromLookup ? lookup?.callsign : flightNumber.flatMap(AirlineCodes.callsign),
            date: date, origin: origin, destination: destination,
            cruiseAltitudeFt: cruiseLevel.map { Double($0) * 100 },
            route: fromLookup ? lookup?.route : nil,
            source: fromLookup ? (lookup?.source ?? .greatCircle) : .greatCircle,
            departureRunway: departureRunway, approachRunway: approachRunway, enroute: enroute,
            sid: sidRoute(from: origin), star: starRoute(to: destination), approach: approachRoute(to: destination))
    }

    // MARK: Procedures

    func procedures(at airport: Airport?) -> TerminalProcedures {
        airport.map { ProcedureDatabase.shared.procedures(at: $0) } ?? TerminalProcedures()
    }

    private func sidRoute(from origin: Airport) -> FlightPlan.ProcedureRoute? {
        guard let sidName else { return nil }
        let legs = procedures(at: origin).sidLegs(sidName, runway: departureRunway, transition: sidTransition)
        let start = departureRunway.map { GreatCircle.destination(from: $0.coordinate, courseDeg: $0.headingDeg,
                                                                  distanceNm: $0.lengthNm) } ?? origin.coordinate
        let fixes = ProcedureBuilder.fixes(legs, kind: .departure, from: start,
                                           startAltitudeFt: departureRunway?.elevationFt ?? origin.elevationFt,
                                           variationDeg: ProcedureBuilder.variation(departureRunway))
        return FlightPlan.ProcedureRoute(name: [sidName, sidTransition].compactMap { $0 }.joined(separator: "."),
                                         legs: fixes)
    }

    private func starRoute(to destination: Airport) -> FlightPlan.ProcedureRoute? {
        guard let starName else { return nil }
        let legs = procedures(at: destination).starLegs(starName, transition: starTransition, runway: approachRunway)
        let fixes = ProcedureBuilder.fixes(legs, kind: .arrival, from: destination.coordinate,
                                           startAltitudeFt: destination.elevationFt,
                                           variationDeg: ProcedureBuilder.variation(approachRunway))
        return FlightPlan.ProcedureRoute(name: [starTransition, starName].compactMap { $0 }.joined(separator: "."),
                                         legs: fixes)
    }

    private func approachRoute(to destination: Airport) -> FlightPlan.ProcedureRoute? {
        guard let approachName else { return nil }
        let legs = procedures(at: destination).approachLegs(approachName, via: approachVia)
        let fixes = ProcedureBuilder.fixes(legs, kind: .approach, from: destination.coordinate,
                                           startAltitudeFt: destination.elevationFt,
                                           variationDeg: ProcedureBuilder.variation(approachRunway),
                                           lastIsDestination: true)
        return FlightPlan.ProcedureRoute(name: [approachVia, approachName].compactMap { $0 }.joined(separator: "."),
                                         legs: fixes)
    }

    /// Choose an approach: it sets the landing runway, and a STAR whose
    /// runway transition no longer fits keeps its common route.
    func chooseApproach(_ name: String?) {
        approachName = name
        approachVia = nil
        if let name, let destination, let ident = ProcedureDatabase.approachRunway(name) {
            approachRunway = NavDatabase.shared.runway(ident, at: destination)
        }
        refreshPlan()
    }

    /// New airports: runways and waypoints chosen for the old ones go.
    func setAirports(origin newOrigin: Airport?, destination newDestination: Airport?) {
        if newOrigin != origin {
            departureRunway = nil
            sidName = nil
            sidTransition = nil
        }
        if newDestination != destination {
            approachRunway = nil
            starName = nil
            starTransition = nil
            approachName = nil
            approachVia = nil
        }
        if newOrigin != origin || newDestination != destination { enroute = [] }
        origin = newOrigin
        destination = newDestination
        refreshPlan()
    }

    /// Look a flight number up in the flight-track archive; its airports
    /// and path fill the setup.
    func lookUp(_ number: String) {
        flightNumber = number
        lookup = nil
        isLookingUp = true
        Task {
            defer { isLookingUp = false }
            do {
                let result = try await lookupProvider.lookup(flightNumber: number)
                lookup = result
                cruiseLevel = nil
                setAirports(origin: result.origin, destination: result.destination)
            } catch let error as FlightLookupError {
                refreshPlan()
                switch error {
                case .badFlightNumber: flash("FORMAT ERROR")
                case .notFound: flash("FLT NOT IN DATA BASE", amber: true)
                case .offline: flash("NO CONNECTION", amber: true)
                case .unknownAirport: flash("NOT IN DATA BASE", amber: true)
                case .unavailable: flash("ROUTE DATA NOT AVAIL", amber: true)
                }
            } catch {
                flash("ROUTE DATA NOT AVAIL", amber: true)
            }
        }
    }

    /// Download the draft plan's flight pack. FlightPackStore makes it the
    /// active flight when it completes, which the root view then flies.
    func download() {
        guard let plan = draftPlan else { return flash("NOT ALLOWED") }
        guard packs.progress == nil else { return flash("DOWNLOAD IN PROGRESS") }
        Task {
            await packs.prepare(plan)
            if let error = packs.lastError {
                flash(error, amber: true)
            } else {
                flash("OFFLINE DATA READY")
            }
        }
    }

    func activate(_ pack: FlightPack) {
        packs.activate(pack.id)
        routePlanner.adopt(flightPlan: pack.plan)
        flightData.selectedAltitudeFt = pack.plan.reachableCruiseFt
        flash("\(pack.plan.title) ACTIVE")
    }

    /// Resume an interrupted download.
    func resume(_ pack: FlightPack) {
        guard packs.progress == nil else { return flash("DOWNLOAD IN PROGRESS") }
        Task {
            await packs.prepare(pack.plan)
            flash(packs.lastError ?? "OFFLINE DATA READY", amber: packs.lastError != nil)
        }
    }

    // MARK: Destination search actions

    func startSearch(_ text: String) {
        searchQuery = text
        selected = nil
        search.query = text
        if let location = flightData.location?.coordinate { search.focus(on: location) }
        show(.destSearch)
    }

    /// Resolve a search suggestion to a place.
    func choose(_ completion: MKLocalSearchCompletion) {
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
                return flash("NOT IN DATA BASE", amber: true)
            }
            selected = (item.name ?? completion.title, item.placemark.coordinate)
        }
    }

    /// Plan the road route to the chosen place and go back to the displays.
    func flySelected() {
        guard let selected else { return flash("NOT ALLOWED") }
        guard let origin = flightData.location?.coordinate else { return flash("NO GPS POSITION", amber: true) }
        Task { await routePlanner.fly(to: selected.name, at: selected.coordinate, from: origin) }
        close()
    }

    // MARK: Paging

    /// How many screenfuls the current page has.
    var pageCount: Int {
        switch page {
        case .destSearch: return max(1, Int(ceil(Double(search.completions.count) / 4)))
        case .flightPlan:
            let lines = isEditingFlightPlan ? flightPlanLines.count : (routePlanner?.waypoints.count ?? 0)
            return max(1, Int(ceil(Double(max(lines, 1)) / 5)))
        case .departure, .arrival:
            let lists = procedureLists
            let lines = Double(max(lists.left.count, lists.right.count))
            return max(1, Int(ceil(lines / Double(Self.procedureLinesPerPage))))
        case .flights: return max(1, Int(ceil(Double(packs?.packs.count ?? 0) / 5)))
        case .credits: return max(1, Int(ceil(Double(Self.creditLines.count) / 10)))
        default: return 1
        }
    }
}
