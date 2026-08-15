import SwiftUI
import MapKit

/// Full-screen Apple Maps destination picker: search or tap the map to choose
/// a destination, then FLY plans the route and returns to the instruments.
struct DestinationPickerView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @Environment(\.dismiss) private var dismiss

    /// Called after FLY, so the presenter can put the side menu away too.
    var onFly: () -> Void = {}

    @StateObject private var search = DestinationSearchModel()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedName: String?
    @State private var selectedCoordinate: CLLocationCoordinate2D?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            ZStack(alignment: .top) {
                map
                if !search.completions.isEmpty { resultsList }
            }
            flyBar
        }
        .background(Color(.systemBackground))
        .onAppear {
            if let location = flightData.location {
                search.focus(on: location.coordinate)
            }
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search destination…", text: $search.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.query.isEmpty {
                Button {
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            Button("Cancel") { dismiss() }
        }
        .padding(12)
        .background(Color(.systemBackground))
    }

    private var resultsList: some View {
        List(Array(search.completions.enumerated()), id: \.offset) { _, completion in
            Button {
                Task { await choose(completion) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 280)
        .background(Color(.systemBackground))
    }

    private func choose(_ completion: MKLocalSearchCompletion) async {
        do {
            let response = try await MKLocalSearch(request: .init(completion: completion)).start()
            guard let item = response.mapItems.first else { return }
            select(name: item.name ?? completion.title, coordinate: item.placemark.coordinate)
        } catch {
            // Leave the current selection untouched; the user can try again.
        }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                UserAnnotation()
                if let selectedCoordinate, let selectedName {
                    Marker(selectedName, coordinate: selectedCoordinate)
                }
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    select(name: "MAP PT", coordinate: coordinate)
                }
            }
        }
    }

    private func select(name: String, coordinate: CLLocationCoordinate2D) {
        selectedName = name
        selectedCoordinate = coordinate
        search.clear()
        camera = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    // MARK: Fly

    private var flyBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedName ?? "No destination selected")
                    .font(EFIS.digits(14, .bold))
                    .foregroundStyle(selectedName == nil ? .secondary : .primary)
                    .lineLimit(1)
                if selectedName != nil {
                    Text("Route is planned from the current position")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                fly()
            } label: {
                Text("FLY")
                    .font(EFIS.digits(16, .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(EFIS.cyan, in: RoundedRectangle(cornerRadius: 8))
            }
            .disabled(selectedCoordinate == nil)
            .opacity(selectedCoordinate == nil ? 0.4 : 1)
        }
        .padding(14)
        .background(Color(.systemBackground))
    }

    private func fly() {
        guard let selectedName, let selectedCoordinate else { return }
        let origin = flightData.location?.coordinate
        Task { await routePlanner.fly(to: selectedName, at: selectedCoordinate, from: origin) }
        dismiss()
        onFly()
    }
}

/// Live search suggestions, Apple Maps style.
@MainActor
final class DestinationSearchModel: NSObject, ObservableObject {
    @Published var query = "" {
        didSet {
            if query.isEmpty {
                completions = []
            } else {
                completer.queryFragment = query
            }
        }
    }
    @Published private(set) var completions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Bias suggestions toward the aircraft's surroundings.
    func focus(on coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
    }

    func clear() {
        query = ""
        completions = []
    }
}

extension DestinationSearchModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.completions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter,
                               didFailWithError error: Error) {
        Task { @MainActor in self.completions = [] }
    }
}

#Preview {
    DestinationPickerView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
}
