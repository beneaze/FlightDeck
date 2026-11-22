import Foundation
import CoreLocation
import CoreGraphics
import ImageIO

/// One web-mercator tile: zoom, column, row.
struct TileID: Hashable, Codable, Sendable {
    let z: Int
    let x: Int
    let y: Int

    /// Path of the tile below a tile directory: `z/x/y.png`.
    var relativePath: String { "\(z)/\(x)/\(y).png" }

    /// The tile containing a coordinate at a zoom level.
    static func containing(_ coordinate: CLLocationCoordinate2D, zoom: Int) -> TileID {
        let (fx, fy) = WebMercator.tileXY(coordinate, zoom: zoom)
        let n = 1 << zoom
        return TileID(z: zoom, x: ((Int(floor(fx)) % n) + n) % n, y: min(n - 1, max(0, Int(floor(fy)))))
    }
}

/// Web-mercator tile maths.
enum WebMercator {
    /// Latitude limit of the projection.
    static let maxLatitude = 85.0511

    /// Fractional tile coordinates of a point at a zoom level.
    static func tileXY(_ c: CLLocationCoordinate2D, zoom: Int) -> (x: Double, y: Double) {
        let n = Double(1 << zoom)
        let lat = min(maxLatitude, max(-maxLatitude, c.latitude)) * .pi / 180
        let x = (c.longitude + 180) / 360 * n
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n
        return (x, y)
    }

    /// Ground size of one tile pixel (256 px tiles) at a latitude and zoom.
    static func metersPerPixel(latitude: Double, zoom: Int) -> Double {
        156_543.034 * cos(latitude * .pi / 180) / Double(1 << zoom)
    }
}

/// Elevation tiles on disk: Terrarium-encoded PNGs from the AWS Open Data
/// "Terrain Tiles" set, stored as `directory/z/x/y.png`. Heights are read
/// from the best zoom level on disk and interpolated bilinearly. Decoded
/// tiles are kept in a small LRU cache; everything is thread-safe, so the
/// ND's terrain image can be built off the main thread.
final class TerrainStore: @unchecked Sendable {
    let directory: URL

    /// Zoom levels looked for, finest first.
    static let zoomLevels = [12, 11, 10, 9, 8, 7]

    /// The order to try zoom levels in for a sampling limit: the finest
    /// level up to `maxZoom` first, then — when only finer tiles are on disk,
    /// as in a flight pack whose coarsest level is z8 — the finer ones,
    /// coarsest of those first.
    static func zoomOrder(maxZoom: Int) -> [Int] {
        zoomLevels.filter { $0 <= maxZoom } + zoomLevels.filter { $0 > maxZoom }.reversed()
    }

    /// Tiles fetched as needed (car routes), in Caches — the system may purge
    /// them, which only means they are fetched again.
    static let onDemand: TerrainStore = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return TerrainStore(directory: caches.appendingPathComponent("TerrainTiles", isDirectory: true))
    }()

    /// Short credit for the menu. The data sources' licences ask for this
    /// list wherever the terrain is shown; ``fullAttribution`` is the
    /// complete text for the README and the privacy policy.
    static let attribution = """
        Terrain: Terrain Tiles (AWS Open Data) — USGS 3DEP, SRTM and GMTED2010; NOAA ETOPO1; \
        Copernicus EU-DEM (EU); ArcticDEM (DigitalGlobe, NSF); Geoscience Australia; DGM Österreich; \
        Open Government Licence – Canada; INEGI; LINZ (New Zealand); Kartverket; \
        © Environment Agency (UK).
        """

    static let fullAttribution = """
        * ArcticDEM terrain data DEM(s) were created from DigitalGlobe, Inc., imagery and \
        funded under National Science Foundation awards 1043681, 1559691, and 1542736;
        * Australia terrain data © Commonwealth of Australia (Geoscience Australia) 2017;
        * Austria terrain data © offene Daten Österreichs – Digitales Geländemodell (DGM) Österreich;
        * Canada terrain data contains information licensed under the Open Government Licence – Canada;
        * Europe terrain data produced using Copernicus data and information funded by the \
        European Union - EU-DEM layers;
        * Global ETOPO1 terrain data U.S. National Oceanic and Atmospheric Administration
        * Mexico terrain data source: INEGI, Continental relief, 2016;
        * New Zealand terrain data Copyright 2011 Crown copyright (c) Land Information New \
        Zealand and the New Zealand Government (All rights reserved);
        * Norway terrain data © Kartverket;
        * United Kingdom terrain data © Environment Agency copyright and/or database right 2015. \
        All rights reserved;
        * United States 3DEP (formerly NED) and global GMTED2010 and SRTM terrain data courtesy \
        of the U.S. Geological Survey.
        """

    /// Generation of the files on disk. Downloads bump it, so stores drop
    /// their "no such tile" memory and look again.
    nonisolated(unsafe) private static var diskGeneration = 0
    private static let generationLock = NSLock()

    static func noteTilesAdded() {
        generationLock.lock()
        diskGeneration += 1
        generationLock.unlock()
    }

    private static var currentGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return diskGeneration
    }

    /// A decoded tile: 256 × 256 heights in metres, row-major from the top.
    typealias Heights = [Int16]

    private let lock = NSLock()
    private var cache: [TileID: Heights] = [:]
    private var recency: [TileID] = []
    private var missing: Set<TileID> = []
    private var missingGeneration = -1
    private let cacheLimit = 64

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: Lookups

    /// Height of the ground surface in feet. The tiles carry the sea floor
    /// too (negative heights); for the displays the sea surface is the
    /// ground, so anything below sea level reads 0.
    func elevationFt(at coordinate: CLLocationCoordinate2D) -> Double? {
        elevationMeters(at: coordinate).map { max(0, $0) * 3.28084 }
    }

    /// Raw height in metres — negative over the sea floor — at the finest
    /// zoom on disk no finer than `maxZoom`.
    func elevationMeters(at coordinate: CLLocationCoordinate2D, maxZoom: Int = 12) -> Double? {
        for zoom in Self.zoomOrder(maxZoom: maxZoom) {
            let tile = TileID.containing(coordinate, zoom: zoom)
            if let heights = heights(for: tile) {
                return Self.sample(heights, tile: tile, at: coordinate)
            }
        }
        return nil
    }

    /// Ground along a straight line from `start` on `trackDeg`, `samples`
    /// points out to `spanNm`, the sea surface counting as ground (see
    /// ``elevationFt(at:)``). Points without data are left out; empty when
    /// there is no data at all.
    func profile(from start: CLLocationCoordinate2D, trackDeg: Double, spanNm: Double,
                 samples: Int) -> [(distanceNm: Double, elevationFt: Double)] {
        guard samples > 1, spanNm > 0 else { return [] }
        // Sample no finer than the spacing calls for.
        let spacingMeters = spanNm * 1_852 / Double(samples - 1)
        let zoom = Self.zoom(forSpacingMeters: spacingMeters, latitude: start.latitude)
        var result: [(distanceNm: Double, elevationFt: Double)] = []
        result.reserveCapacity(samples)
        for i in 0..<samples {
            let distance = spanNm * Double(i) / Double(samples - 1)
            let point = GreatCircle.destination(from: start, courseDeg: trackDeg, distanceNm: distance)
            if let meters = elevationMeters(at: point, maxZoom: zoom) {
                result.append((distance, max(0, meters) * 3.28084))
            }
        }
        return result
    }

    /// The zoom whose pixels are about as fine as a sampling interval.
    static func zoom(forSpacingMeters spacing: Double, latitude: Double) -> Int {
        let equatorPixel = 156_543.034 * max(0.05, cos(latitude * .pi / 180))
        let ideal = Int(ceil(log2(equatorPixel / max(spacing, 1))))
        return min(12, max(7, ideal))
    }

    // MARK: Tile planning

    /// Every tile within `corridorNm` either side of a route.
    static func tiles(alongRoute route: [CLLocationCoordinate2D], corridorNm: Double,
                      zoom: Int) -> Set<TileID> {
        guard let first = route.first else { return [] }
        var tiles: Set<TileID> = []
        // Densify so no stretch of corridor is skipped between samples.
        let step = max(1, min(corridorNm, 20))
        var samples: [CLLocationCoordinate2D] = [first]
        for (a, b) in zip(route, route.dropFirst()) {
            let distance = GreatCircle.distanceNm(a, b)
            let count = max(1, Int(ceil(distance / step)))
            for i in 1...count {
                samples.append(GreatCircle.intermediate(a, b, fraction: Double(i) / Double(count)))
            }
        }
        for point in samples {
            tiles.formUnion(Self.tiles(around: point, radiusNm: corridorNm, zoom: zoom))
        }
        return tiles
    }

    /// Every tile touching the box of `radiusNm` around a point.
    static func tiles(around center: CLLocationCoordinate2D, radiusNm: Double,
                      zoom: Int) -> Set<TileID> {
        let latSpan = radiusNm / 60
        let lonSpan = min(180, radiusNm / (60 * max(0.01, cos(center.latitude * .pi / 180))))
        let north = min(WebMercator.maxLatitude, center.latitude + latSpan)
        let south = max(-WebMercator.maxLatitude, center.latitude - latSpan)
        let n = 1 << zoom
        let (westX, northY) = WebMercator.tileXY(.init(latitude: north, longitude: center.longitude - lonSpan),
                                                 zoom: zoom)
        let (eastX, southY) = WebMercator.tileXY(.init(latitude: south, longitude: center.longitude + lonSpan),
                                                 zoom: zoom)
        var tiles: Set<TileID> = []
        let x0 = Int(floor(westX)), x1 = Int(floor(eastX))
        let y0 = max(0, Int(floor(northY))), y1 = min(n - 1, Int(floor(southY)))
        guard y0 <= y1 else { return [] }
        // Columns wrap across the antimeridian.
        for x in x0...max(x0, min(x1, x0 + n - 1)) {
            for y in y0...y1 {
                tiles.insert(TileID(z: zoom, x: ((x % n) + n) % n, y: y))
            }
        }
        return tiles
    }

    func fileURL(for tile: TileID) -> URL {
        directory.appendingPathComponent(tile.relativePath)
    }

    // MARK: Decoding and cache

    /// The decoded heights of a tile, from the cache or disk; nil when the
    /// tile isn't on disk or can't be read.
    func heights(for tile: TileID) -> Heights? {
        lock.lock()
        let generation = Self.currentGeneration
        if generation != missingGeneration {
            missing.removeAll()
            missingGeneration = generation
        }
        if let cached = cache[tile] {
            if let index = recency.firstIndex(of: tile) { recency.remove(at: index) }
            recency.append(tile)
            lock.unlock()
            return cached
        }
        if missing.contains(tile) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let decoded = Self.decode(contentsOf: fileURL(for: tile))

        lock.lock()
        defer { lock.unlock() }
        guard let decoded else {
            missing.insert(tile)
            return nil
        }
        cache[tile] = decoded
        recency.append(tile)
        if recency.count > cacheLimit {
            cache.removeValue(forKey: recency.removeFirst())
        }
        return decoded
    }

    /// Terrarium decoding straight from the PNG's pixel bytes — never
    /// through a colour-managed redraw, which would alter the encoded
    /// heights. Elevation (m) = R·256 + G + B/256 − 32768.
    static func decode(contentsOf url: URL) -> Heights? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(pngData: data)
    }

    static func decode(pngData data: Data) -> Heights? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == 256, image.height == 256, image.bitsPerComponent == 8,
              image.colorSpace?.model == .rgb,
              let pixels = image.dataProvider?.data,
              let base = CFDataGetBytePtr(pixels)
        else { return nil }

        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel == 3 || bytesPerPixel == 4 else { return nil }
        let bytesPerRow = image.bytesPerRow
        guard CFDataGetLength(pixels) >= bytesPerRow * 256 else { return nil }

        // Where R, G and B sit within a pixel.
        let alphaFirst: Bool
        switch image.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst: alphaFirst = true
        default: alphaFirst = false
        }
        let littleEndian = image.byteOrderInfo == .order32Little || image.byteOrderInfo == .order16Little
        var r = 0, g = 1, b = 2
        if bytesPerPixel == 4 {
            // Logical order ARGB or RGBA; a little-endian 32-bit word reverses it.
            let logical = alphaFirst ? [1, 2, 3] : [0, 1, 2]
            if littleEndian {
                r = 3 - logical[0]; g = 3 - logical[1]; b = 3 - logical[2]
            } else {
                r = logical[0]; g = logical[1]; b = logical[2]
            }
        }

        var heights = Heights(repeating: 0, count: 256 * 256)
        for row in 0..<256 {
            let rowBase = base + row * bytesPerRow
            for column in 0..<256 {
                let p = rowBase + column * bytesPerPixel
                let meters = Double(p[r]) * 256 + Double(p[g]) + Double(p[b]) / 256 - 32_768
                heights[row * 256 + column] = Int16(clamping: Int(meters.rounded()))
            }
        }
        return heights
    }

    /// Bilinear sample within a tile; pixel values sit at pixel centres, and
    /// the edge pixels are held at the tile border.
    static func sample(_ heights: Heights, tile: TileID, at c: CLLocationCoordinate2D) -> Double {
        let (fx, fy) = WebMercator.tileXY(c, zoom: tile.z)
        let n = Double(1 << tile.z)
        var localX = fx - Double(tile.x)
        if localX < 0 { localX += n }              // across the antimeridian
        let px = min(255, max(0, localX * 256 - 0.5))
        let py = min(255, max(0, (fy - Double(tile.y)) * 256 - 0.5))
        let x0 = Int(px), y0 = Int(py)
        let x1 = min(255, x0 + 1), y1 = min(255, y0 + 1)
        let tx = px - Double(x0), ty = py - Double(y0)
        let h00 = Double(heights[y0 * 256 + x0]), h10 = Double(heights[y0 * 256 + x1])
        let h01 = Double(heights[y1 * 256 + x0]), h11 = Double(heights[y1 * 256 + x1])
        let top = h00 + (h10 - h00) * tx
        let bottom = h01 + (h11 - h01) * tx
        return top + (bottom - top) * ty
    }
}

/// Fetches terrain tiles into a tile directory.
enum TerrainDownloader {
    static let baseURL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Airport Wi-Fi can be slow: allow a tile a full minute.
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "terrain-tile-client/1.0"]
        return URLSession(configuration: configuration)
    }()

    /// Fetches the missing tiles (files already present are skipped), at
    /// most 4 at a time. `progress` reports tiles done, the total, and the
    /// bytes on disk so far (present files included). A tile the server
    /// doesn't have is skipped. A tile that still fails after two retries
    /// doesn't stop the others: the rest are fetched, and the error is
    /// thrown at the end, so trying again only needs the missing ones.
    /// With the `simulateOffline` default set (a launch argument), it throws
    /// as an offline device would.
    static func download(_ tiles: Set<TileID>, into directory: URL,
                         progress: @escaping @Sendable (_ done: Int, _ total: Int, _ bytes: Int64) -> Void)
    async throws {
        let fileManager = FileManager.default
        let total = tiles.count
        var done = 0
        var bytes: Int64 = 0
        var pending: [TileID] = []
        for tile in tiles {
            let url = directory.appendingPathComponent(tile.relativePath)
            if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
                done += 1
                bytes += size.int64Value
            } else {
                pending.append(tile)
            }
        }
        progress(done, total, bytes)
        guard !pending.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: "simulateOffline") {
            throw URLError(.notConnectedToInternet)
        }

        defer { TerrainStore.noteTilesAdded() }
        var failure: Error?
        await withTaskGroup(of: Result<Int64, Error>.self) { group in
            var iterator = pending.makeIterator()
            func enqueue() {
                guard let tile = iterator.next() else { return }
                group.addTask {
                    do { return .success(try await fetch(tile, into: directory)) } catch { return .failure(error) }
                }
            }
            for _ in 0..<4 { enqueue() }
            while let result = await group.next() {
                switch result {
                case .success(let size):
                    done += 1
                    bytes += size
                    progress(done, total, bytes)
                case .failure(let error):
                    failure = error
                }
                if !Task.isCancelled { enqueue() }
            }
        }
        if let failure { throw failure }
    }

    /// Downloads one tile and writes it atomically; returns its size, 0 when
    /// the server has no such tile.
    private static func fetch(_ tile: TileID, into directory: URL) async throws -> Int64 {
        let url = URL(string: "\(baseURL)/\(tile.relativePath)")!
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 404 || http.statusCode == 403 { return 0 }
                guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                let target = directory.appendingPathComponent(tile.relativePath)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                return Int64(data.count)
            } catch {
                lastError = error
                if (error as? URLError)?.code == .notConnectedToInternet { throw error }
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
        }
        throw lastError
    }
}
