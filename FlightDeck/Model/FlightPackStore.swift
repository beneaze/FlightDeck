import Foundation
import CoreLocation

/// Everything the displays need for one flight, kept on the device so the
/// app works in flight without a connection: the plan, and the terrain tiles
/// along its route.
struct FlightPack: Identifiable, Codable {
    let plan: FlightPlan
    var tileCount: Int
    var bytes: Int64
    var isComplete: Bool
    let created: Date

    var id: UUID { plan.id }
}

/// Prepares, stores and selects flight packs.
///
/// Packs live in Application Support/FlightPacks/<id>/ — `plan.json`,
/// `pack.json` and `tiles/z/x/y.png` — excluded from iCloud backup, as they
/// can always be downloaded again. A pack expires a week after its flight's
/// date and is removed on the next launch.
///
/// Terrain plan per pack: z8 (~600 m) along a ±80 NM corridor, z10 within
/// 40 NM and z11 within 15 NM of both airports, for the climb-out and the
/// approach.
@MainActor
final class FlightPackStore: ObservableObject {
    @Published private(set) var packs: [FlightPack] = []
    @Published private(set) var activePackID: UUID? {
        didSet { UserDefaults.standard.set(activePackID?.uuidString, forKey: Self.activeKey) }
    }
    @Published private(set) var progress: (planID: UUID, done: Int, total: Int, bytes: Int64)?
    @Published private(set) var lastError: String?

    static let corridorNm = 80.0
    static let expiry: TimeInterval = 7 * 24 * 3600
    private static let activeKey = "activeFlightPackID"

    private let root: URL
    private var terrainCache: (id: UUID, store: TerrainStore)?

    var activePack: FlightPack? { packs.first { $0.id == activePackID } }

    /// The terrain of the active pack, one store per pack so its decoded
    /// tiles stay cached.
    var activeTerrain: TerrainStore? {
        guard let id = activePackID, packs.contains(where: { $0.id == id }) else { return nil }
        if let cached = terrainCache, cached.id == id { return cached.store }
        let store = TerrainStore(directory: tilesDirectory(id))
        terrainCache = (id, store)
        return store
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("FlightPacks", isDirectory: true)
        prepareRoot()
        loadPacks()
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey),
           let id = UUID(uuidString: raw), packs.contains(where: { $0.id == id }) {
            activePackID = id
        } else {
            activePackID = nil
        }
    }

    // MARK: Preparing

    /// Save the plan, download its terrain, and make it the active pack.
    /// Running it again for a partly downloaded pack resumes: tiles already
    /// on disk are skipped.
    func prepare(_ plan: FlightPlan) async {
        lastError = nil
        let directory = packDirectory(plan.id)
        let tiles = Self.tiles(for: plan)
        var pack = FlightPack(plan: plan, tileCount: tiles.count, bytes: 0, isComplete: false,
                              created: packs.first { $0.id == plan.id }?.created ?? Date())
        do {
            try FileManager.default.createDirectory(at: tilesDirectory(plan.id), withIntermediateDirectories: true)
            try write(plan, to: directory.appendingPathComponent("plan.json"))
            try write(pack, to: directory.appendingPathComponent("pack.json"))
        } catch {
            lastError = "COULD NOT SAVE FLIGHT"
            return
        }
        upsert(pack)

        progress = (plan.id, 0, tiles.count, 0)
        do {
            let id = plan.id
            try await TerrainDownloader.download(tiles, into: tilesDirectory(plan.id)) { [weak self] done, total, bytes in
                Task { @MainActor in
                    guard let self, self.progress?.planID == id else { return }
                    self.progress = (id, done, total, bytes)
                }
            }
            pack.bytes = directorySize(tilesDirectory(plan.id))
            pack.isComplete = true
            try? write(pack, to: directory.appendingPathComponent("pack.json"))
            upsert(pack)
            progress = nil
            activate(plan.id)
        } catch {
            pack.bytes = directorySize(tilesDirectory(plan.id))
            try? write(pack, to: directory.appendingPathComponent("pack.json"))
            upsert(pack)
            progress = nil
            lastError = (error as? URLError)?.code == .notConnectedToInternet
                ? "NO CONNECTION — TRY AGAIN ON THE GROUND"
                : "DOWNLOAD FAILED — TRY AGAIN"
        }
    }

    /// The terrain tiles a plan needs.
    static func tiles(for plan: FlightPlan) -> Set<TileID> {
        var tiles = TerrainStore.tiles(alongRoute: plan.coordinates, corridorNm: corridorNm, zoom: 8)
        for airport in [plan.origin, plan.destination] {
            // Finer terrain for climb-out and approach, where the ground is
            // close: z10 (~150 m) out to 25 NM, z11 (~75 m) within 10 NM.
            tiles.formUnion(TerrainStore.tiles(around: airport.coordinate, radiusNm: 25, zoom: 10))
            tiles.formUnion(TerrainStore.tiles(around: airport.coordinate, radiusNm: 10, zoom: 11))
        }
        return tiles
    }

    // MARK: Selecting and removing

    func activate(_ id: UUID?) {
        activePackID = id.flatMap { id in packs.contains { $0.id == id } ? id : nil }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: packDirectory(id))
        packs.removeAll { $0.id == id }
        if activePackID == id { activePackID = nil }
        if terrainCache?.id == id { terrainCache = nil }
    }

    // MARK: Disk

    private func packDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func tilesDirectory(_ id: UUID) -> URL {
        packDirectory(id).appendingPathComponent("tiles", isDirectory: true)
    }

    private func prepareRoot() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Read every pack on disk, deleting expired and unreadable ones.
    private func loadPacks() {
        let fileManager = FileManager.default
        let decoder = JSONDecoder()
        var loaded: [FlightPack] = []
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for directory in entries {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("pack.json")),
                  let pack = try? decoder.decode(FlightPack.self, from: data)
            else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            if pack.plan.date.addingTimeInterval(Self.expiry) < Date() {
                try? fileManager.removeItem(at: directory)
                continue
            }
            loaded.append(pack)
        }
        packs = loaded.sorted { $0.plan.date > $1.plan.date }
    }

    private func upsert(_ pack: FlightPack) {
        packs.removeAll { $0.id == pack.id }
        packs.append(pack)
        packs.sort { $0.plan.date > $1.plan.date }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
