import SwiftUI
import CoreLocation

/// A320 Navigation Display in ARC mode: the aircraft sits low in the sector,
/// the compass rose arcs across the top, and the flight plan runs away from
/// the aircraft between dashed range arcs.
///
/// Like the PFD, the whole instrument is drawn into one canvas in our own
/// 1000-unit layout (see ``ND``), then scaled to fit, so its proportions
/// never drift with the screen size.
struct NDView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @EnvironmentObject private var packs: FlightPackStore
    @StateObject private var terrain = NDTerrainLayer()

    @State private var rangeIndex = AircraftProfile.a320.ndDefaultRangeIndex
    /// Non-zero while the display is "recomputing" after a range change — the
    /// real unit blanks the map for half a second and shows RANGE CHANGE.
    @State private var rangeChangeCount = 0

    var profile: AircraftProfile = .a320

    private var rangeNm: Double { profile.ndRangesNm[rangeIndex] }

    /// The route's ground profile from the aircraft out to the selected
    /// range, in nautical miles ahead.
    private var routeElevationAhead: [(distanceNm: Double, elevationFt: Double)] {
        if isFlying {
            // In flight: the ground along the current track, from the pack.
            guard let store = packs.activeTerrain, let location = flightData.location else { return [] }
            return store.profile(from: location.coordinate, trackDeg: flightData.trackDeg,
                                 spanNm: rangeNm, samples: 64)
        }
        guard let profile = routePlanner.elevationProfile else { return [] }
        return profile.ahead(fromMeters: routePlanner.alongTrackMeters, spanMeters: rangeNm * 1852)
            .map { (distanceNm: $0.distanceMeters / 1852, elevationFt: $0.elevationFt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            display
            VerticalDisplayView(altitudeFt: flightData.altitudeFt,
                                selectedAltitudeFt: flightData.selectedAltitudeFt,
                                flightPathAngleDeg: flightData.flightPathAngleDeg,
                                rangeNm: rangeNm,
                                routeElevation: routeElevationAhead,
                                elevationStatus: elevationStatus,
                                destinationName: routePlanner.destination?.name,
                                destinationDistanceNm: routePlanner.distanceToGoNm(
                                    from: flightData.location),
                                showsGround: isFlying)
                .frame(height: 104)
            controlBar
        }
        .background(EFIS.background)
        .onReceive(flightData.$location) { _ in updateTerrain() }
        .onChange(of: rangeIndex) { updateTerrain() }
        .onChange(of: flightData.autoFlight.terrainOnND) { updateTerrain() }
    }

    private var isFlying: Bool { routePlanner.transportMode == .plane }

    private var elevationStatus: String? {
        if isFlying { return packs.activeTerrain == nil ? "NO TERRAIN" : nil }
        return routePlanner.destination == nil ? nil : routePlanner.elevationStatus
    }

    /// Terrain shows in plane mode with the EFIS panel's terrain switch on
    /// (the Airbus TERR ON ND pushbutton, the Boeing TERR switch).
    private var showsTerrain: Bool { isFlying && flightData.autoFlight.terrainOnND }

    private func updateTerrain() {
        terrain.update(store: showsTerrain ? packs.activeTerrain : nil, location: flightData.location,
                       upDeg: flightData.headingDeg, rangeNm: rangeNm, altitudeFt: flightData.altitudeFt,
                       verticalSpeedFpm: flightData.verticalSpeedFpm)
    }

    // MARK: Display

    private var display: some View {
        Canvas { context, size in
            // Fill the width: the ring reaches the display sides at up to a
            // 60° half-span, unless the height (the band from the rose's top
            // labels to just below the aircraft) is the tighter constraint.
            let bandHeight = ND.bandBottom - ND.bandTop
            let widthAtMaxSpan = 2 * ND.ringRadius * CGFloat(sin(ND.maxHalfSpanDeg * .pi / 180))
            let scale = min(size.height / bandHeight, size.width / widthAtMaxSpan)
            let offsetY = max(0, (size.height - bandHeight * scale) / 2)

            var ctx = context
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))

            var sector = ctx
            sector.translateBy(x: size.width / 2 - ND.center.x * scale,
                               y: offsetY - ND.bandTop * scale)
            sector.scaleBy(x: scale, y: scale)

            // The display edges in sector coordinates, for everything that
            // must run out to them however wide the screen is.
            let bounds = CGRect(x: ND.center.x - size.width / 2 / scale,
                                y: ND.bandTop - offsetY / scale,
                                width: size.width / scale,
                                height: size.height / scale)

            // Layer order: terrain at the bottom, then the rose, map, the track
            // indication over the flight plan — so the line stays visible
            // with a route active — and the aircraft symbol on top.
            drawTerrain(sector, bounds)
            drawCompass(sector)
            drawRangeArcs(sector, bounds)
            drawMap(sector, bounds)
            drawTrackIndication(sector)
            drawAirplane(sector)
            drawTerrainReadout(sector, bounds)

            // Data blocks anchor to the display corners, not to the sector.
            var left = ctx
            left.scaleBy(x: scale, y: scale)
            drawSpeeds(left)
            drawWind(left)

            var right = ctx
            right.translateBy(x: size.width - ND.canvas * scale, y: 0)
            right.scaleBy(x: scale, y: scale)
            drawToWaypoint(right)

            if routePlanner.destination == nil, let error = routePlanner.errorMessage {
                text(sector, error, x: ND.center.x, y: bounds.maxY - ND.fontSmallest,
                     size: ND.fontSmallest, EFIS.amber, anchor: .center)
            }
        }
    }

    // MARK: Compass rose

    private func drawCompass(_ context: GraphicsContext) {
        let ctx = context
        let heading = flightData.headingDeg

        // The visible part of the heading ring, running a little past the
        // last graduation either side.
        var ring = Path()
        for step in stride(from: -ND.ringSpanDeg, through: ND.ringSpanDeg, by: 1.5) {
            let p = ND.point(bearingDeg: step, radius: ND.ringRadius)
            step == -ND.ringSpanDeg ? ring.move(to: p) : ring.addLine(to: p)
        }
        ctx.stroke(ring, with: .color(.white), lineWidth: ND.lineWidth)

        // A graduation every 5°, long at the tens. The tens carry their
        // heading in tens of degrees, rotating with the rose; every third one
        // (the 30° marks) is set large.
        for deg in stride(from: 0, to: 360, by: 5) {
            let diff = angularDifference(Double(deg), heading)
            guard abs(diff) <= ND.tickSpanDeg else { continue }

            var tick = ctx
            tick.translateBy(x: ND.center.x, y: ND.center.y)
            tick.rotate(by: .degrees(diff))

            let major = deg % 10 == 0
            tick.line(from: CGPoint(x: 0, y: -ND.ringRadius),
                      to: CGPoint(x: 0, y: -ND.ringRadius - (major ? ND.majorTick : ND.minorTick)),
                      .white, width: ND.lineWidth)

            if major {
                let size = deg % 30 == 0 ? ND.roseLabelLarge : ND.roseLabelSmall
                tick.digits("\(deg / 10)", at: CGPoint(x: 0, y: -ND.labelRadius),
                            size: size, .white)
            }
        }
    }

    private func drawRangeArcs(_ context: GraphicsContext, _ bounds: CGRect) {
        var ctx = context
        ctx.clip(to: ND.rangeArcClip(in: bounds))
        for fraction in ND.rangeArcFractions {
            let radius = ND.ringRadius * fraction
            let circle = Path(ellipseIn: CGRect(x: ND.center.x - radius, y: ND.center.y - radius,
                                                width: radius * 2, height: radius * 2))
            ctx.stroke(circle, with: .color(.white),
                       style: StrokeStyle(lineWidth: ND.lineWidth, dash: ND.rangeArcDash))
        }

        // The half and three-quarter arcs carry their distance at both ends.
        for fraction in [0.5, 0.75] {
            let label = rangeLabel(rangeNm * fraction)
            let left = ND.point(bearingDeg: -ND.rangeLabelBearingDeg,
                                radius: ND.ringRadius * CGFloat(fraction))
            let right = ND.point(bearingDeg: ND.rangeLabelBearingDeg,
                                 radius: ND.ringRadius * CGFloat(fraction))
            text(context, label, x: left.x + ND.rangeLabelInset, y: left.y,
                 size: ND.fontSmallest, EFIS.cyan)
            text(context, label, x: right.x - ND.rangeLabelInset, y: right.y,
                 size: ND.fontSmallest, EFIS.cyan, anchor: .trailing)
        }
    }

    private func rangeLabel(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        var text = String(format: value < 1 ? "%.2f" : "%.1f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// With terrain on the ND: TERR in cyan in the lower right corner, and
    /// above it the highest and lowest terrain elevations of the picture in
    /// hundreds of feet, each in the colour of its band.
    private func drawTerrainReadout(_ context: GraphicsContext, _ bounds: CGRect) {
        guard showsTerrain, packs.activeTerrain != nil, rangeChangeCount == 0,
              flightData.location != nil else { return }
        let x = bounds.maxX - 24
        var y = bounds.maxY - ND.fontSmallest
        text(context, "TERR", x: x, y: y, size: ND.fontSmallest, EFIS.cyan, anchor: .trailing)
        guard let readout = terrain.readout else { return }
        let rows = [(readout.lowestFt, readout.lowestHue), (readout.highestFt, readout.highestHue)]
        for case let (ft?, hue) in rows {
            y -= ND.fontIntermediate * 1.05
            text(context, NDTerrainRenderer.hundredsOfFeet(ft), x: x, y: y, size: ND.fontIntermediate,
                 Self.color(hue), anchor: .trailing)
        }
    }

    private static func color(_ hue: NDTerrainRenderer.Hue) -> Color {
        switch hue {
        case .red: return EFIS.red
        case .amber: return EFIS.amber
        case .green: return EFIS.green
        case .cyan: return EFIS.cyan
        case .magenta: return EFIS.magenta
        }
    }

    // MARK: Track indication

    /// Green track line from the rose centre out to the ring, with a diamond
    /// riding the ring — where the aircraft is actually going, as opposed to
    /// where it is pointing.
    private func drawTrackIndication(_ context: GraphicsContext) {
        let diff = angularDifference(flightData.trackDeg, flightData.headingDeg)

        var ctx = context
        ctx.translateBy(x: ND.center.x, y: ND.center.y)
        ctx.rotate(by: .degrees(diff))

        // The line stops where the lubber line begins, so the two never
        // overlap when track and heading agree.
        var line = Path()
        line.move(to: CGPoint(x: 0, y: -(ND.ringRadius - ND.lubberHalfLength)))
        line.addLine(to: .zero)
        ctx.stroke(line, with: .color(EFIS.background),
                   style: StrokeStyle(lineWidth: ND.lineWidth * 1.5, lineCap: .round))
        ctx.stroke(line, with: .color(EFIS.green),
                   style: StrokeStyle(lineWidth: ND.lineWidth * 1.25, lineCap: .round))

        // The diamond hangs from the ring, and disappears once the drift
        // angle would carry it off the visible sector.
        guard abs(diff) <= 40 else { return }
        let height: CGFloat = 26, halfWidth: CGFloat = 8
        let top = -ND.ringRadius
        var diamond = Path()
        diamond.move(to: CGPoint(x: 0, y: top))
        diamond.addLine(to: CGPoint(x: -halfWidth, y: top + height / 2))
        diamond.addLine(to: CGPoint(x: 0, y: top + height))
        diamond.addLine(to: CGPoint(x: halfWidth, y: top + height / 2))
        diamond.closeSubpath()
        ctx.stroke(diamond, with: .color(EFIS.background),
                   style: StrokeStyle(lineWidth: ND.lineWidth * 2.25, lineJoin: .round))
        ctx.stroke(diamond, with: .color(EFIS.green),
                   style: StrokeStyle(lineWidth: ND.lineWidth * 1.5, lineJoin: .round))
    }

    // MARK: Map

    /// Annunciations replacing the map sit in the middle of the sector.
    private var sectorMidY: CGFloat { ND.center.y - ND.ringRadius * 0.6 }

    /// The terrain picture: the bottom layer of the display, so the rose,
    /// range arcs, route, symbols and every label stay drawn over it.
    private func drawTerrain(_ context: GraphicsContext, _ bounds: CGRect) {
        guard showsTerrain, rangeChangeCount == 0, let location = flightData.location else { return }
        var ctx = context
        ctx.clip(to: ND.mapClip(in: bounds))
        let g = NDGeometry(apex: ND.planeCenter, radius: ND.mapRadius,
                           rangeNm: rangeNm, origin: location.coordinate,
                           headingDeg: flightData.headingDeg)
        terrain.draw(in: ctx, geometry: g, clipCenter: ND.center, clipRadius: ND.ringRadius,
                     sweepOrigin: ND.planeCenter)
    }

    private func drawMap(_ context: GraphicsContext, _ bounds: CGRect) {
        guard let location = flightData.location else {
            text(context, "MAP NOT AVAIL", x: ND.center.x, y: sectorMidY, size: ND.fontLarge,
                 EFIS.red, anchor: .center)
            return
        }

        // While the new scale is computed the map blanks and the annunciation
        // shows in the middle of the sector.
        guard rangeChangeCount == 0 else {
            text(context, "RANGE CHANGE", x: ND.center.x, y: sectorMidY, size: ND.fontIntermediate,
                 EFIS.green, anchor: .center)
            return
        }

        var ctx = context
        ctx.clip(to: ND.mapClip(in: bounds))

        let g = NDGeometry(apex: ND.planeCenter, radius: ND.mapRadius,
                           rangeNm: rangeNm, origin: location.coordinate,
                           headingDeg: flightData.headingDeg)

        // In flight: the airports around (the terrain is drawn first, under
        // everything; see drawTerrain).
        if isFlying {
            let planned = Set(routePlanner.flightPlan.map { [$0.origin.icao, $0.destination.icao] } ?? [])
            for airport in g.airportsInView(excluding: planned) {
                drawAirportSymbol(ctx, at: g.project(airport.coordinate), ident: airport.icao)
            }
        }

        // The not-yet-flown part of the plan; sequenced legs disappear behind.
        let coordinates = routePlanner.remainingRouteCoordinates(maximumCount: 400)
        if coordinates.count > 1 {
            var path = Path()
            for (index, coordinate) in coordinates.enumerated() {
                let p = g.project(coordinate)
                index == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.stroke(path, with: .color(EFIS.green), lineWidth: ND.routeWidth)
        }

        // With no computed route, the direct-to leg is the active flight plan.
        if routePlanner.routeCoordinates.count < 2, let waypoint = routePlanner.waypoints.first {
            var leg = Path()
            leg.move(to: g.apex)
            leg.addLine(to: g.project(waypoint.coordinate))
            ctx.stroke(leg, with: .color(EFIS.green), lineWidth: ND.routeWidth)
        }

        // Waypoints from the TO waypoint onward: the active one white, the
        // rest of the plan green, each with its ident.
        for (index, waypoint) in routePlanner.waypoints.enumerated()
        where index >= routePlanner.activeWaypointIndex {
            drawWaypointSymbol(ctx, at: g.project(waypoint.coordinate),
                               ident: waypoint.ident,
                               color: index == routePlanner.activeWaypointIndex
                                   ? .white : EFIS.green)
        }
    }

    /// An airport: a magenta star of four short bars, its ident beside it.
    private func drawAirportSymbol(_ context: GraphicsContext, at: CGPoint, ident: String) {
        let r: CGFloat = 11
        var star = Path()
        for deg in stride(from: 0.0, to: 180, by: 45) {
            let a = deg * .pi / 180
            star.move(to: CGPoint(x: at.x - r * CGFloat(sin(a)), y: at.y - r * CGFloat(cos(a))))
            star.addLine(to: CGPoint(x: at.x + r * CGFloat(sin(a)), y: at.y + r * CGFloat(cos(a))))
        }
        context.stroke(star, with: .color(EFIS.magenta), lineWidth: ND.routeWidth * 0.8)
        text(context, ident, x: at.x + 1.6 * r, y: at.y + 1.2 * r, size: ND.fontMap, EFIS.magenta)
    }

    private func drawWaypointSymbol(_ context: GraphicsContext, at: CGPoint,
                                    ident: String, color: Color) {
        let half: CGFloat = 8.5
        var diamond = Path()
        diamond.move(to: CGPoint(x: at.x, y: at.y - half))
        diamond.addLine(to: CGPoint(x: at.x + half, y: at.y))
        diamond.addLine(to: CGPoint(x: at.x, y: at.y + half))
        diamond.addLine(to: CGPoint(x: at.x - half, y: at.y))
        diamond.closeSubpath()
        context.stroke(diamond, with: .color(EFIS.background), lineWidth: ND.routeWidth * 1.85)
        context.stroke(diamond, with: .color(color), lineWidth: ND.routeWidth)
        // Ident below and to the right of the symbol.
        text(context, ident, x: at.x + 2.3 * half, y: at.y + 1.5 * half, size: ND.fontMap, color)
    }

    // MARK: Aircraft symbol

    private func drawAirplane(_ context: GraphicsContext) {
        // Wings, fuselage and tailplane as three strokes of one path.
        let c = ND.planeCenter
        typealias A = ND.Airplane
        var plane = Path()
        plane.move(to: CGPoint(x: c.x - A.wingHalfSpan, y: c.y))
        plane.addLine(to: CGPoint(x: c.x + A.wingHalfSpan, y: c.y))
        plane.move(to: CGPoint(x: c.x, y: c.y - A.nose))
        plane.addLine(to: CGPoint(x: c.x, y: c.y + A.tail))
        plane.move(to: CGPoint(x: c.x - A.tailplaneHalfSpan, y: c.y + A.tailplaneAt))
        plane.addLine(to: CGPoint(x: c.x + A.tailplaneHalfSpan, y: c.y + A.tailplaneAt))
        context.stroke(plane, with: .color(EFIS.background),
                       style: StrokeStyle(lineWidth: ND.symbolWidth * 1.6, lineCap: .round))
        context.stroke(plane, with: .color(EFIS.yellow),
                       style: StrokeStyle(lineWidth: ND.symbolWidth, lineCap: .round))

        // Yellow lubber line, fixed across the top of the ring.
        let ringTop = ND.center.y - ND.ringRadius
        var lubber = Path()
        lubber.move(to: CGPoint(x: ND.center.x, y: ringTop - ND.lubberHalfLength))
        lubber.addLine(to: CGPoint(x: ND.center.x, y: ringTop + ND.lubberHalfLength))
        context.stroke(lubber, with: .color(EFIS.background),
                       style: StrokeStyle(lineWidth: ND.symbolWidth * 1.1, lineCap: .round))
        context.stroke(lubber, with: .color(EFIS.yellow),
                       style: StrokeStyle(lineWidth: ND.symbolWidth, lineCap: .round))
    }

    // MARK: Data blocks

    // The corner blocks are laid out in rows and in character columns of
    // the monospaced face, from the canvas edges inward.

    /// Distance of the data blocks from the canvas edges.
    private static let blockMargin: CGFloat = 6
    /// Centre line of data-block row `n`, counting from the top.
    private static func row(_ n: Int) -> CGFloat { 20 + 42 * CGFloat(n) }

    /// Ground speed and true airspeed, top left, in the selected unit: each a
    /// small two-or-three-letter label followed by a three-digit value.
    private func drawSpeeds(_ context: GraphicsContext) {
        let unit = flightData.speedUnit.perKnot
        let small = ND.advance(ND.fontSmallest), large = ND.advance(ND.fontIntermediate)
        let y = Self.row(0)

        let gsLabelX = Self.blockMargin
        let gsValueRight = gsLabelX + 3 * small + 3 * large
        let tasLabelX = gsValueRight + small / 2
        let tasValueRight = tasLabelX + 4 * small + 3 * large

        text(context, "GS", x: gsLabelX, y: y, size: ND.fontSmallest, .white)
        text(context, "\(Int((flightData.groundSpeedKts * unit).rounded()))",
             x: gsValueRight, y: y, size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
        text(context, "TAS", x: tasLabelX, y: y, size: ND.fontSmallest, .white)
        text(context, "\(Int((flightData.tasKts * unit).rounded()))",
             x: tasValueRight, y: y, size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
    }

    /// Wind vector under the speeds: direction/speed and an arrow pointing the
    /// way the wind is blowing across the display.
    private func drawWind(_ context: GraphicsContext) {
        let direction = flightData.windDirDeg
        let speed = flightData.windSpeedKts

        let directionText = direction.map { String(format: "%03d", Int($0.rounded()) % 360) } ?? "---"
        let speedText = speed.map { "\(Int(($0 * flightData.speedUnit.perKnot).rounded()))" } ?? "---"

        let digit = ND.advance(ND.fontSmall), small = ND.advance(ND.fontSmallest)
        let y = Self.row(1)
        let directionRight = Self.blockMargin + 3 * digit
        text(context, directionText, x: directionRight, y: y, size: ND.fontSmall, EFIS.green,
             anchor: .trailing)
        text(context, "/", x: directionRight, y: y, size: ND.fontSmallest, .white)
        text(context, speedText, x: directionRight + small, y: y, size: ND.fontSmall, EFIS.green)

        guard let direction, let speed, speed > 2 else { return }
        var ctx = context
        ctx.translateBy(x: Self.blockMargin + 1.5 * digit, y: Self.row(2))
        ctx.rotate(by: .degrees(direction - flightData.headingDeg + 180))
        let halfLength: CGFloat = 20, headWidth: CGFloat = 8.5, headLength: CGFloat = 15.5
        var arrow = Path()
        arrow.move(to: CGPoint(x: 0, y: halfLength))
        arrow.addLine(to: CGPoint(x: 0, y: -halfLength))
        arrow.move(to: CGPoint(x: -headWidth, y: -halfLength + headLength))
        arrow.addLine(to: CGPoint(x: 0, y: -halfLength))
        arrow.addLine(to: CGPoint(x: headWidth, y: -halfLength + headLength))
        ctx.stroke(arrow, with: .color(EFIS.green),
                   style: StrokeStyle(lineWidth: ND.lineWidth * 1.25, lineCap: .round))
    }

    /// TO-waypoint block, top right: the active waypoint's ident, bearing,
    /// along-route distance and ETA — not the final destination's.
    /// Right-aligned on the canvas edge, column by column.
    private func drawToWaypoint(_ context: GraphicsContext) {
        guard let waypoint = routePlanner.activeWaypoint else { return }

        let edge = ND.canvas - Self.blockMargin
        let large = ND.advance(ND.fontIntermediate), small = ND.advance(ND.fontSmallest)

        // Row 0: IDENT  BRG°
        let bearingRight = edge - large
        let identRight = bearingRight - 4 * large
        text(context, waypoint.ident, x: identRight, y: Self.row(0),
             size: ND.fontIntermediate, .white, anchor: .trailing)

        guard let location = flightData.location else { return }

        let bearing = NDGeometry(apex: .zero, radius: 1, rangeNm: 1,
                                 origin: location.coordinate, headingDeg: 0)
            .vector(to: waypoint.coordinate).bearingDeg
        text(context, String(format: "%03d", Int(bearing.rounded()) % 360),
             x: bearingRight, y: Self.row(0), size: ND.fontIntermediate, EFIS.green,
             anchor: .trailing)
        text(context, "°", x: edge, y: Self.row(0), size: ND.fontIntermediate, EFIS.cyan,
             anchor: .trailing)

        if let distance = routePlanner.distanceNm(to: waypoint, from: location) {
            // Row 1: distance, then NM.
            let unitRight = edge
            let numberRight = unitRight - 3 * small
            if distance > 20 {
                text(context, "\(Int(distance.rounded()))", x: numberRight, y: Self.row(1),
                     size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
            } else {
                // Below 20 NM the distance gains a decimal, set in small type.
                let parts = String(format: "%.1f", distance).split(separator: ".")
                let fractionLeft = numberRight - 2 * small
                text(context, "." + String(parts[1]), x: numberRight, y: Self.row(1),
                     size: ND.fontSmallest, EFIS.green, anchor: .trailing)
                text(context, String(parts[0]), x: fractionLeft + small / 4, y: Self.row(1),
                     size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
            }
            text(context, "NM", x: unitRight, y: Self.row(1), size: ND.fontSmallest, EFIS.cyan,
                 anchor: .trailing)

            // Row 2: ETA.
            if let eta = utcArrival(afterNm: distance) {
                text(context, eta, x: edge, y: Self.row(2), size: ND.fontIntermediate,
                     EFIS.green, anchor: .trailing)
            }
        }
    }

    /// UTC clock time after covering `distance` at the current ground speed.
    private func utcArrival(afterNm distance: Double) -> String? {
        guard flightData.groundSpeedKts > 10 else { return nil }
        let arrival = Date().addingTimeInterval(distance / flightData.groundSpeedKts * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute], from: arrival)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Draw text with its vertical centre on `y` and `anchor` setting the
    /// horizontal alignment.
    private func text(_ context: GraphicsContext, _ string: String,
                      x: CGFloat, y: CGFloat, size: CGFloat, _ color: Color,
                      anchor: UnitPoint = .leading) {
        context.digits(string, at: CGPoint(x: x, y: y), size: size, color, anchor: anchor)
    }

    // MARK: Controls

    /// Destination handling lives in the side menu; the bar under the ND only
    /// carries what belongs to the display itself — the range.
    private var controlBar: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)

            Button { setRange(rangeIndex - 1) } label: {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.white)
            }
            Button { setRange(rangeIndex + 1) } label: {
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(EFIS.background)
    }

    private func setRange(_ newIndex: Int) {
        guard profile.ndRangesNm.indices.contains(newIndex), newIndex != rangeIndex
        else { return }
        rangeIndex = newIndex
        rangeChangeCount += 1
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            rangeChangeCount -= 1
        }
    }
}

#Preview {
    NDView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
        .environmentObject(FlightPackStore())
        .frame(height: 480)
}
