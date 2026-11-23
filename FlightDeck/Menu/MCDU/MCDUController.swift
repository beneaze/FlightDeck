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
    @Published var lookup: FlightLookupResult?
    @Published var isLookingUp = false
    /// The plan the entries above make, rebuilt whenever one changes.
    @Published private(set) var draftPlan: FlightPlan?

    // MARK: Destination search (car / bike)

    let search = DestinationSearchModel()
    @Published var searchQuery = ""
    @Published var selected: (name: String, coordinate: CLLocationCoordinate2D)?
    @Published var isShowingMap = false

    // MARK: Models

    private(set) var routePlanner: RoutePlanner!
    private(set) var flightData: FlightDataModel!
    private(set) var packs: FlightPackStore!
    private(set) var speedLimits: SpeedLimitProvider!
    private let lookupProvider: FlightLookupProvider = FlightArchiveProvider()

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
            departureRunway: departureRunway, approachRunway: approachRunway, enroute: enroute)
    }

    /// New airports: runways and waypoints chosen for the old ones go.
    func setAirports(origin newOrigin: Airport?, destination newDestination: Airport?) {
        if newOrigin != origin { departureRunway = nil }
        if newDestination != destination { approachRunway = nil }
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
                case .unavailable: flash("FLT ARCHIVE NOT AVAIL", amber: true)
                }
            } catch {
                flash("FLT ARCHIVE NOT AVAIL", amber: true)
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
        case .departure: return max(1, Int(ceil(Double(origin.map { NavDatabase.shared.runways(at: $0).count } ?? 0) / 4)))
        case .arrival:
            return max(1, Int(ceil(Double(destination.map { NavDatabase.shared.runways(at: $0).count } ?? 0) / 4)))
        case .flights: return max(1, Int(ceil(Double(packs?.packs.count ?? 0) / 5)))
        case .credits: return max(1, Int(ceil(Double(Self.creditLines.count) / 10)))
        default: return 1
        }
    }
}
