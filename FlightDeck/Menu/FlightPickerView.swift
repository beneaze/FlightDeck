import SwiftUI

/// Plane mode's counterpart to the destination picker: choose the flight —
/// by flight number from the free flight-track archive, or by airports from
/// the built-in list — and download everything the displays need in flight
/// into an offline flight pack.
struct FlightPickerView: View {
    @EnvironmentObject private var routePlanner: RoutePlanner
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var packs: FlightPackStore
    @Environment(\.dismiss) private var dismiss

    /// Called once a flight is ready, so the presenter can close the menu.
    var onReady: () -> Void = {}

    private let lookupProvider: FlightLookupProvider = FlightArchiveProvider()

    @State private var flightNumber = ""
    @State private var date = Date()
    @State private var origin: Airport?
    @State private var destination: Airport?
    @State private var lookedUp: FlightLookupResult?
    @State private var lookupMessage: String?
    @State private var isLookingUp = false
    @State private var cruiseLevel: Int?          // flight level, e.g. 360
    @State private var picking: AirportSlot?

    private enum AirportSlot: String, Identifiable {
        case origin, destination
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                flightSection
                airportsSection
                cruiseSection
                downloadSection
                savedSection
                notesSection
            }
            .navigationTitle("Select Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $picking) { slot in
                AirportSearchView(title: slot == .origin ? "From" : "To") { airport in
                    if slot == .origin { origin = airport } else { destination = airport }
                    lookedUp = nil
                    picking = nil
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Notes

    private static let usageNote = "Download before you board: in flight the app works without internet, "
        + "from GPS and the flight pack. Passengers only — keep the phone in airplane mode and "
        + "follow the crew's instructions."

    private var credits: String {
        let parts: [String] = [FlightArchiveProvider.attribution, TerrainStore.attribution,
                               "Airports: OurAirports (public domain)."]
        return parts.joined(separator: " ")
    }

    private var notesSection: some View {
        Section {
            Text(Self.usageNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(credits)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Flight number

    private var flightSection: some View {
        Section {
            HStack {
                TextField("Flight number, e.g. LH400", text: $flightNumber)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(EFIS.digits(17, .bold))
                    .onSubmit { Task { await lookUp() } }
                if isLookingUp {
                    ProgressView()
                } else {
                    Button("Look up") { Task { await lookUp() } }
                        .disabled(flightNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            DatePicker("Date", selection: $date, displayedComponents: .date)
            if let lookedUp {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(lookedUp.callsign) · \(lookedUp.origin.code) → \(lookedUp.destination.code)")
                        .font(EFIS.digits(15, .bold))
                        .foregroundStyle(EFIS.green)
                    if case .archive(let flownOn) = lookedUp.source {
                        Text("Path as flown on \(flownOn). The route on the day may differ.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let lookupMessage {
                Text(lookupMessage)
                    .font(.footnote)
                    .foregroundStyle(EFIS.amber)
            }
        } header: {
            Text("Flight")
        }
    }

    private func lookUp() async {
        let number = flightNumber.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty else { return }
        isLookingUp = true
        lookupMessage = nil
        defer { isLookingUp = false }
        do {
            let result = try await lookupProvider.lookup(flightNumber: number)
            lookedUp = result
            origin = result.origin
            destination = result.destination
            cruiseLevel = nil
        } catch {
            lookedUp = nil
            lookupMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Airports

    private var airportsSection: some View {
        Section {
            airportRow("From", airport: origin) { picking = .origin }
            airportRow("To", airport: destination) { picking = .destination }
        } header: {
            Text("Airports")
        } footer: {
            Text("Filled in by the lookup, or choose them yourself. Without a looked-up path the route is drawn as a great circle.")
        }
    }

    private func airportRow(_ label: String, airport: Airport?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                if let airport {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(airport.code).font(EFIS.digits(16, .bold)).foregroundStyle(.primary)
                        Text(airport.city.isEmpty ? airport.name : airport.city)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("Choose").foregroundStyle(EFIS.cyan)
                }
            }
        }
    }

    // MARK: Cruise

    private var plan: FlightPlan? {
        guard let origin, let destination, origin != destination else { return nil }
        let number = flightNumber.trimmingCharacters(in: .whitespaces).uppercased()
        let useLookup = lookedUp.map { $0.origin == origin && $0.destination == destination } ?? false
        return FlightPlan(flightNumber: number.isEmpty ? nil : number,
                          callsign: useLookup ? lookedUp?.callsign : AirlineCodes.callsign(forFlightNumber: number),
                          date: date, origin: origin, destination: destination,
                          cruiseAltitudeFt: cruiseLevel.map { Double($0) * 100 },
                          route: useLookup ? lookedUp?.route : nil,
                          source: useLookup ? (lookedUp?.source ?? .greatCircle) : .greatCircle)
    }

    private var cruiseSection: some View {
        Section {
            if let plan {
                let level = cruiseLevel ?? Int(plan.cruiseAltitudeFt / 100)
                Stepper(value: Binding(get: { level }, set: { cruiseLevel = $0 }), in: 100...430, step: 10) {
                    HStack {
                        Text("Cruise")
                        Spacer()
                        Text("FL\(level)").font(EFIS.digits(16, .bold)).foregroundStyle(EFIS.cyan)
                    }
                }
                LabeledContent("Distance", value: String(format: "%.0f NM", plan.totalDistanceNm))
            } else {
                Text("Choose two airports to plan the flight.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Plan")
        }
    }

    // MARK: Download

    private var downloadSection: some View {
        Section {
            if let progress = packs.progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("Downloading terrain \(progress.done)/\(progress.total) · "
                         + ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    guard let plan else { return }
                    Task {
                        await packs.prepare(plan)
                        if packs.activePack?.plan.id == plan.id {
                            fly(plan)
                        }
                    }
                } label: {
                    Label("Download for offline", systemImage: "arrow.down.circle")
                        .font(.headline)
                }
                .disabled(plan == nil)
            }
            if let error = packs.lastError {
                Text(error).font(.footnote).foregroundStyle(EFIS.amber)
            }
        }
    }

    // MARK: Saved flights

    private var savedSection: some View {
        Section {
            if packs.packs.isEmpty {
                Text("No flights downloaded yet.").foregroundStyle(.secondary)
            }
            ForEach(packs.packs) { pack in
                Button {
                    if pack.isComplete {
                        packs.activate(pack.id)
                        fly(pack.plan)
                    } else if packs.progress == nil {
                        // Resume an interrupted download; tiles on disk are kept.
                        Task {
                            await packs.prepare(pack.plan)
                            if packs.activePack?.id == pack.id { fly(pack.plan) }
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(pack.plan.title)  \(pack.plan.origin.code) → \(pack.plan.destination.code)")
                                .font(EFIS.digits(15, .bold))
                                .foregroundStyle(.primary)
                            Text(pack.plan.date.formatted(date: .abbreviated, time: .omitted) + " · "
                                 + ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if pack.id == packs.activePackID {
                            Text("ACTIVE").font(EFIS.digits(12, .bold)).foregroundStyle(EFIS.green)
                        } else {
                            Text(pack.isComplete ? "READY" : "TAP TO RESUME")
                                .font(EFIS.digits(12, .bold))
                                .foregroundStyle(pack.isComplete ? EFIS.cyan : EFIS.amber)
                        }
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { packs.delete(packs.packs[index].id) }
            }
        } header: {
            Text("Downloaded flights")
        } footer: {
            Text("Flights are removed automatically a week after their date.")
        }
    }

    private func fly(_ plan: FlightPlan) {
        routePlanner.adopt(flightPlan: plan)
        flightData.selectedAltitudeFt = plan.reachableCruiseFt
        dismiss()
        onReady()
    }
}

/// Searchable list of the built-in airports.
struct AirportSearchView: View {
    let title: String
    let onPick: (Airport) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(AirportDatabase.shared.search(query)) { airport in
                Button {
                    onPick(airport)
                } label: {
                    HStack {
                        Text(airport.code)
                            .font(EFIS.digits(16, .bold))
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(airport.name).lineLimit(1)
                            Text([airport.city, airport.country, airport.icao]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "City, airport or code")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
