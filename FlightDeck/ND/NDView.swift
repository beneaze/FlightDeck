import SwiftUI
import CoreLocation

/// A320 Navigation Display, in the mode the EFIS panel selects:
/// - ARC: the aircraft low in the sector, the compass rose arcing across the
///   top, the flight plan running away between dashed range arcs;
/// - ROSE NAV: the full rose round the aircraft, the map all round it;
/// - ROSE LS / ROSE VOR: the full rose with the approach or VOR course
///   pointer and its deviation bar instead of the map;
/// - PLAN: north up, centred on the TO waypoint, the aircraft where it is.
///
/// Like the PFD, the whole instrument is drawn into one canvas in our own
/// 1000-unit layout (see ``ND``), then scaled to fit, so its proportions
/// never drift with the screen size.
struct NDView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @EnvironmentObject private var packs: FlightPackStore
    @StateObject private var terrain = NDTerrainLayer()

    /// Non-zero while the display is "recomputing" after a range or mode
    /// change — the real unit blanks the map for half a second and shows
    /// RANGE CHANGE or MODE CHANGE.
    @State private var rangeChangeCount = 0
    @State private var modeChangeCount = 0

    var profile: AircraftProfile = .a320

    private var af: AutoFlight { flightData.autoFlight }
    private var mode: NDMode { af.ndMode }
    /// The range set on the EFIS panel or with the range keys.
    private var rangeIndex: Int { af.ndRangeIndex.clamped(to: 0...(profile.ndRangesNm.count - 1)) }
    private var rangeNm: Double { profile.ndRangesNm[rangeIndex] }
    /// Nautical miles from the map's centre to the ring: the selected range
    /// in ARC; in ROSE and PLAN the range is the ring's diameter.
    private var mapRangeNm: Double { mode == .arc ? rangeNm : rangeNm / 2 }
    private var isBlanked: Bool { rangeChangeCount > 0 || modeChangeCount > 0 }

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
        .onChange(of: rangeIndex) {
            blank(range: true)
            updateTerrain()
        }
        .onChange(of: mode) {
            blank(range: false)
            updateTerrain()
        }
        .onChange(of: flightData.autoFlight.terrainOnND) { updateTerrain() }
    }

    private var isFlying: Bool { routePlanner.transportMode == .plane }

    private var elevationStatus: String? {
        if isFlying { return packs.activeTerrain == nil ? "NO TERRAIN" : nil }
        return routePlanner.destination == nil ? nil : routePlanner.elevationStatus
    }

    /// Terrain shows in plane mode with the TERR ON ND pushbutton on, in
    /// ARC and ROSE NAV.
    private var showsTerrain: Bool { isFlying && af.terrainOnND && mode.showsTerrain }

    private func updateTerrain() {
        terrain.update(store: showsTerrain ? packs.activeTerrain : nil, location: flightData.location,
                       upDeg: flightData.headingDeg, rangeNm: mapRangeNm, altitudeFt: flightData.altitudeFt,
                       verticalSpeedFpm: flightData.verticalSpeedFpm)
    }

    /// Blank the map for the half second the real unit takes.
    private func blank(range: Bool) {
        if range { rangeChangeCount += 1 } else { modeChangeCount += 1 }
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            if range { rangeChangeCount -= 1 } else { modeChangeCount -= 1 }
        }
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

            let layout = NDLayout(mode: mode, bounds: bounds)

            // Layer order: terrain at the bottom, then the rose, map, the track
            // indication over the flight plan — so the line stays visible
            // with a route active — and the aircraft symbol on top.
            drawTerrain(sector, bounds, layout)
            drawCompass(sector, layout)
            drawRangeRings(sector, bounds, layout)
            if isBlanked || flightData.location == nil {
                drawMapAnnunciation(sector, layout)
            } else if mode.showsMap {
                drawMap(sector, bounds, layout)
            } else {
                drawRadioCourse(sector, bounds, layout)
            }
            if mode != .plan {
                drawTrackIndication(sector, layout)
                drawSelectedHeading(sector, bounds, layout)
            }
            drawAirplane(sector, layout)
            drawTerrainReadout(sector, bounds)

            // Data blocks anchor to the display corners, not to the sector.
            var left = ctx
            left.scaleBy(x: scale, y: scale)
            drawSpeeds(left)
            drawWind(left)

            var right = ctx
            right.translateBy(x: size.width - ND.canvas * scale, y: 0)
            right.scaleBy(x: scale, y: scale)
            if mode.showsMap { drawToWaypoint(right) } else { drawRadioBlock(right) }

            if routePlanner.destination == nil, let error = routePlanner.errorMessage {
                text(sector, error, x: ND.center.x, y: bounds.maxY - ND.fontSmallest,
                     size: ND.fontSmallest, EFIS.amber, anchor: .center)
            }
        }
    }

    // MARK: Compass rose

    private func drawCompass(_ context: GraphicsContext, _ layout: NDLayout) {
        if layout.mode == .plan { drawPlanCompass(context, layout); return }
        let ctx = context
        let heading = flightData.headingDeg
        let r = layout.ringRadius

        // ARC: the visible part of the heading ring, running a little past
        // the last graduation either side. ROSE: the whole ring.
        if layout.isArc {
            var ring = Path()
            for step in stride(from: -ND.ringSpanDeg, through: ND.ringSpanDeg, by: 1.5) {
                let p = layout.point(bearingDeg: step, radius: r)
                step == -ND.ringSpanDeg ? ring.move(to: p) : ring.addLine(to: p)
            }
            ctx.stroke(ring, with: .color(.white), lineWidth: ND.lineWidth)
        } else {
            ctx.stroke(layout.ringPath, with: .color(.white), lineWidth: ND.lineWidth)
        }

        // A graduation every 5°, long at the tens, rotating with the rose.
        // ARC labels every ten, the 30° ones large; the full rose labels
        // every 30°, the cardinal points large.
        let tickSpan = layout.isArc ? ND.tickSpanDeg : 180
        for deg in stride(from: 0, to: 360, by: 5) {
            let diff = angularDifference(Double(deg), heading)
            guard abs(diff) <= tickSpan else { continue }

            var tick = ctx
            tick.translateBy(x: layout.center.x, y: layout.center.y)
            tick.rotate(by: .degrees(diff))

            let major = deg % 10 == 0
            tick.line(from: CGPoint(x: 0, y: -r),
                      to: CGPoint(x: 0, y: -r - (major ? layout.majorTick : layout.minorTick)),
                      .white, width: ND.lineWidth)

            let labelled = layout.isArc ? major : deg % 30 == 0
            if labelled {
                let large = layout.isArc ? deg % 30 == 0 : deg % 90 == 0
                tick.digits("\(deg / 10)", at: CGPoint(x: 0, y: -layout.labelRadius),
                            size: large ? layout.labelLarge : layout.labelSmall, .white)
            }
        }

        // The full rose's fixed marks: a small white triangle on the ring
        // every 45° from the lubber line, pointing in.
        guard !layout.isArc else { return }
        for bearing in stride(from: 45.0, to: 360, by: 45) {
            var mark = ctx
            mark.translateBy(x: layout.center.x, y: layout.center.y)
            mark.rotate(by: .degrees(bearing))
            let h = layout.majorTick * 0.8, w = layout.majorTick * 0.4
            var triangle = Path()
            triangle.move(to: CGPoint(x: 0, y: -r + 1))
            triangle.addLine(to: CGPoint(x: -w, y: -r - h))
            triangle.addLine(to: CGPoint(x: w, y: -r - h))
            triangle.closeSubpath()
            mark.fill(triangle, with: .color(.white))
        }
    }

    /// PLAN: north up, the ring with the four cardinal points marked inside
    /// it, upright.
    private func drawPlanCompass(_ context: GraphicsContext, _ layout: NDLayout) {
        let r = layout.ringRadius
        context.stroke(layout.ringPath, with: .color(.white), lineWidth: ND.lineWidth)
        for (deg, letter) in [(0.0, "N"), (90.0, "E"), (180.0, "S"), (270.0, "W")] {
            context.line(from: layout.point(bearingDeg: deg, radius: r),
                         to: layout.point(bearingDeg: deg, radius: r - layout.majorTick),
                         .white, width: ND.lineWidth)
            let at = layout.point(bearingDeg: deg, radius: r - layout.majorTick - layout.labelLarge * 0.75)
            text(context, letter, x: at.x, y: at.y, size: layout.labelLarge, .white, anchor: .center)
        }
    }

    private func drawRangeRings(_ context: GraphicsContext, _ bounds: CGRect, _ layout: NDLayout) {
        guard !layout.isArc else { drawRangeArcs(context, bounds); return }
        // ROSE and PLAN: a dashed ring at half the radius. Each ring's
        // distance — a quarter of the range on the inner one, half on the
        // ring — is written once, just inside it, low on the left.
        let r = layout.ringRadius
        let radius = r / 2
        let circle = Path(ellipseIn: CGRect(x: layout.center.x - radius, y: layout.center.y - radius,
                                            width: radius * 2, height: radius * 2))
        let dash = r * 0.03
        context.stroke(circle, with: .color(.white),
                       style: StrokeStyle(lineWidth: ND.lineWidth, dash: [dash, dash]))
        let size = r * 0.075
        for (ring, value) in [(radius, rangeNm / 4), (r, rangeNm / 2)] {
            let at = layout.point(bearingDeg: 225, radius: ring - r * 0.085)
            text(context, rangeLabel(value), x: at.x, y: at.y, size: size, EFIS.cyan, anchor: .center)
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
        guard showsTerrain, packs.activeTerrain != nil, !isBlanked,
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

    // MARK: Selected heading

    /// The FCU's selected heading: a cyan triangle standing on the ring
    /// among the graduations, its point on the heading — shown only while a
    /// heading is selected (HDG); managed NAV shows none. When the heading
    /// lies beyond the visible part of the arc, its value is written in cyan
    /// at the end of the arc on that side instead; the full rose always
    /// shows it.
    private func drawSelectedHeading(_ context: GraphicsContext, _ bounds: CGRect, _ layout: NDLayout) {
        guard let selected = flightData.autoFlight.selectedHeadingDeg else { return }
        let diff = angularDifference(selected, flightData.headingDeg)

        // The arc's visible end: where the ring leaves the display sides.
        let halfWidth = bounds.width / 2 - ND.selectedHeadingEdgeMargin
        let visibleDeg = layout.isArc
            ? min(ND.tickSpanDeg, asin(Double(min(1, max(0, halfWidth / ND.ringRadius)))) * 180 / .pi)
            : 180

        if abs(diff) <= visibleDeg {
            var bug = context
            bug.translateBy(x: layout.center.x, y: layout.center.y)
            bug.rotate(by: .degrees(diff))
            let r = layout.ringRadius, h = ND.selectedHeadingHeight, w = ND.selectedHeadingHalfWidth
            var triangle = Path()
            triangle.move(to: CGPoint(x: 0, y: -r))
            triangle.addLine(to: CGPoint(x: -w, y: -r - h))
            triangle.addLine(to: CGPoint(x: w, y: -r - h))
            triangle.closeSubpath()
            bug.fill(triangle, with: .color(EFIS.background))
            bug.stroke(triangle, with: .color(EFIS.cyan),
                       style: StrokeStyle(lineWidth: ND.lineWidth * 1.3, lineJoin: .round))
        } else {
            let side: Double = diff < 0 ? -1 : 1
            let at = ND.point(bearingDeg: side * visibleDeg, radius: ND.ringRadius - ND.fontIntermediate)
            text(context, String(format: "%03d", Int(selected.rounded()) % 360),
                 x: at.x, y: at.y, size: ND.fontIntermediate, EFIS.cyan,
                 anchor: side < 0 ? .leading : .trailing)
        }
    }

    // MARK: Track indication

    /// Green track line from the rose centre out to the ring, with a diamond
    /// riding the ring — where the aircraft is actually going, as opposed to
    /// where it is pointing.
    private func drawTrackIndication(_ context: GraphicsContext, _ layout: NDLayout) {
        let diff = angularDifference(flightData.trackDeg, flightData.headingDeg)
        let ringRadius = layout.ringRadius

        var ctx = context
        ctx.translateBy(x: layout.center.x, y: layout.center.y)
        ctx.rotate(by: .degrees(diff))

        // The track line, as on the real ND, only while a heading is
        // selected (HDG / TRK) or there is no route to fly in NAV; in
        // managed NAV the flight-plan line takes its place and only the
        // diamond shows. It stops where the lubber line begins, so the two
        // never overlap when track and heading agree.
        // ROSE LS and ROSE VOR draw no track line: the course pointer is
        // the reference there.
        if mode.showsMap && (flightData.autoFlight.isHeadingSelected || routePlanner.destination == nil) {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: -(ringRadius - ND.lubberHalfLength)))
            line.addLine(to: .zero)
            ctx.stroke(line, with: .color(EFIS.background),
                       style: StrokeStyle(lineWidth: ND.lineWidth * 1.5, lineCap: .round))
            ctx.stroke(line, with: .color(EFIS.green),
                       style: StrokeStyle(lineWidth: ND.lineWidth * 1.25, lineCap: .round))
        }

        // The diamond hangs from the ring, and in ARC disappears once the
        // drift angle would carry it off the visible sector.
        guard abs(diff) <= 40 || !layout.isArc else { return }
        let height: CGFloat = 26, halfWidth: CGFloat = 8
        let top = -ringRadius
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

    /// Annunciations replacing the map sit in the middle of the sector, or
    /// above the aircraft in the full rose.
    private func annunciationY(_ layout: NDLayout) -> CGFloat {
        layout.isArc ? ND.center.y - ND.ringRadius * 0.6 : layout.center.y - layout.ringRadius * 0.4
    }

    /// MAP NOT AVAIL without a position; RANGE CHANGE or MODE CHANGE while
    /// the new picture is computed.
    private func drawMapAnnunciation(_ context: GraphicsContext, _ layout: NDLayout) {
        let y = annunciationY(layout)
        if flightData.location == nil {
            text(context, "MAP NOT AVAIL", x: layout.center.x, y: y, size: ND.fontLarge, EFIS.red, anchor: .center)
        } else if modeChangeCount > 0 {
            text(context, "MODE CHANGE", x: layout.center.x, y: y, size: ND.fontIntermediate, EFIS.green,
                 anchor: .center)
        } else {
            text(context, "RANGE CHANGE", x: layout.center.x, y: y, size: ND.fontIntermediate, EFIS.green,
                 anchor: .center)
        }
    }

    /// The map's projection: heading up about the aircraft in ARC and ROSE;
    /// in PLAN north up about the TO waypoint (the aircraft's position when
    /// there is none), as the real PLAN centres on the waypoint the MCDU's
    /// F-PLN page shows second.
    private func mapGeometry(_ layout: NDLayout, location: CLLocation) -> NDGeometry {
        if layout.mode == .plan {
            return NDGeometry(apex: layout.center, radius: layout.mapRadius, rangeNm: mapRangeNm,
                              origin: routePlanner.toWaypoint?.coordinate ?? location.coordinate, headingDeg: 0)
        }
        return NDGeometry(apex: layout.planeCenter, radius: layout.mapRadius, rangeNm: mapRangeNm,
                          origin: location.coordinate, headingDeg: flightData.headingDeg)
    }

    /// The terrain picture: the bottom layer of the display, so the rose,
    /// range arcs, route, symbols and every label stay drawn over it.
    private func drawTerrain(_ context: GraphicsContext, _ bounds: CGRect, _ layout: NDLayout) {
        guard showsTerrain, !isBlanked, let location = flightData.location else { return }
        var ctx = context
        ctx.clip(to: layout.mapClip(in: bounds))
        terrain.draw(in: ctx, geometry: mapGeometry(layout, location: location),
                     clipCenter: layout.center, clipRadius: layout.ringRadius,
                     sweepOrigin: layout.planeCenter, aheadOnly: layout.isArc)
    }

    private func drawMap(_ context: GraphicsContext, _ bounds: CGRect, _ layout: NDLayout) {
        guard let location = flightData.location else { return }

        var ctx = context
        ctx.clip(to: layout.mapClip(in: bounds))

        let g = mapGeometry(layout, location: location)

        // The not-yet-flown part of the plan; sequenced legs disappear behind.
        // Airbus draws the whole active flight plan, active leg included, in
        // green — magenta is kept for constraints and managed targets. Solid
        // while NAV flies it; dashed while a heading is selected (HDG).
        let coordinates = routePlanner.remainingRouteCoordinates(maximumCount: 400)
        let routePoints = coordinates.map(g.project)
        let routeStyle = flightData.autoFlight.isHeadingSelected
            ? StrokeStyle(lineWidth: ND.routeWidth, dash: ND.routeDash)
            : StrokeStyle(lineWidth: ND.routeWidth)
        if routePoints.count > 1 {
            var path = Path()
            path.addLines(routePoints)
            ctx.stroke(path, with: .color(EFIS.green), style: routeStyle)
        }

        // With no computed route, the direct-to leg is the active flight plan.
        if routePlanner.routeCoordinates.count < 2, let waypoint = routePlanner.waypoints.first {
            var leg = Path()
            leg.move(to: g.project(location.coordinate))
            leg.addLine(to: g.project(waypoint.coordinate))
            ctx.stroke(leg, with: .color(EFIS.green), style: routeStyle)
        }

        // The map option lit on the EFIS panel, in magenta under the plan.
        if isFlying { drawMapOption(ctx, g, routePoints: routePoints) }

        // The flight plan's own airports and runways, in white.
        drawPlanRunwaysAndAirports(ctx, g, routePoints: routePoints)

        // Waypoints from the TO waypoint onward: the TO waypoint white, the
        // rest of the plan green, each with its ident. Pseudo waypoints of
        // the vertical profile have their own symbols and no ident.
        for point in routePlanner.ndPlanPoints {
            let at = g.project(point.coordinate)
            switch point.kind {
            case .fix:
                if let constraint = point.constraintFt {
                    drawConstraintCircle(ctx, at: at, constraintFt: constraint)
                    // CSTR: the constraint's value under the ident.
                    if af.ndOption == .constraints {
                        text(ctx, constraintText(constraint), x: at.x + 2.3 * ND.waypointHalf,
                             y: at.y + 1.5 * ND.waypointHalf + ND.fontMap * 1.05, size: ND.fontMap, EFIS.magenta)
                    }
                }
                drawWaypointSymbol(ctx, at: at, ident: point.ident,
                                   color: point.isActive ? .white : EFIS.green)
            case .topOfClimb:
                drawLevelOffSymbol(ctx, at: at, color: EFIS.cyan)
            case .topOfDescent:
                drawTopOfDescentSymbol(ctx, at: at, color: .white)
            case .decel:
                drawDecelSymbol(ctx, at: at, color: EFIS.magenta)
            case .runway:
                // Drawn by the runway symbol at the ranges that show it;
                // further out the runway fix is a waypoint like the others.
                if !showsRunwaysToScale {
                    drawWaypointSymbol(ctx, at: at, ident: point.ident,
                                       color: point.isActive ? .white : EFIS.green)
                }
            case .airport:
                break // drawn with the plan's airports
            }
        }
    }

    // MARK: Map options

    /// What the lit option pushbutton adds: other airports (ARPT), VORs and
    /// DMEs (VOR.D), NDBs (NDB) or the database's enroute waypoints (WPT,
    /// from imported X-Plane data). CSTR is drawn with the plan's fixes.
    private func drawMapOption(_ context: GraphicsContext, _ g: NDGeometry, routePoints: [CGPoint]) {
        let searchNm = g.rangeNm * 1.3
        switch af.ndOption {
        case .airports:
            let planned = Set(routePlanner.flightPlan.map { [$0.origin.icao, $0.destination.icao] } ?? [])
            for airport in g.airportsInView(excluding: planned) {
                drawAirportSymbol(context, at: g.project(airport.coordinate), ident: airport.icao,
                                  color: EFIS.magenta, avoiding: routePoints)
            }
        case .vorDme, .ndb:
            let wantNDB = af.ndOption == .ndb
            for navaid in NavDatabase.shared.navaids(near: g.origin, withinNm: searchNm)
            where navaid.kind.isNDB == wantNDB {
                drawNavaidSymbol(context, at: g.project(navaid.coordinate), navaid: navaid)
            }
        case .waypoints:
            // Enroute fixes are dense: up to the 80 NM range only.
            guard g.rangeNm <= 80 else { return }
            for fix in XPlaneNavData.shared.enrouteFixes(near: g.origin, withinNm: searchNm).prefix(400) {
                drawWaypointSymbol(context, at: g.project(fix.coordinate), ident: fix.ident, color: EFIS.magenta)
            }
        case .constraints, nil:
            break
        }
    }

    /// Our own navaid symbols, after the Airbus set: a cross for a VOR, the
    /// cross in a circle with a DME, a circle for a DME alone, a triangle
    /// for an NDB; the ident below right.
    private func drawNavaidSymbol(_ context: GraphicsContext, at: CGPoint, navaid: Navaid) {
        let r = ND.waypointHalf * 1.3
        var p = Path()
        switch navaid.kind {
        case .ndb, .ndbDme:
            p.move(to: CGPoint(x: at.x, y: at.y - r))
            p.addLine(to: CGPoint(x: at.x + r * 0.95, y: at.y + r * 0.7))
            p.addLine(to: CGPoint(x: at.x - r * 0.95, y: at.y + r * 0.7))
            p.closeSubpath()
        case .dme:
            p.addEllipse(in: CGRect(x: at.x - r * 0.8, y: at.y - r * 0.8, width: r * 1.6, height: r * 1.6))
        case .vor, .vorDme, .vortac, .tacan:
            p.move(to: CGPoint(x: at.x - r, y: at.y)); p.addLine(to: CGPoint(x: at.x + r, y: at.y))
            p.move(to: CGPoint(x: at.x, y: at.y - r)); p.addLine(to: CGPoint(x: at.x, y: at.y + r))
            if navaid.kind != .vor {
                p.addEllipse(in: CGRect(x: at.x - r * 0.62, y: at.y - r * 0.62, width: r * 1.24, height: r * 1.24))
            }
        }
        context.stroke(p, with: .color(EFIS.background), lineWidth: ND.routeWidth * 1.85)
        context.stroke(p, with: .color(EFIS.magenta), lineWidth: ND.routeWidth)
        text(context, navaid.ident, x: at.x + 1.5 * r, y: at.y + 1.2 * r, size: ND.fontMap, EFIS.magenta)
    }

    /// A constraint as the MCDU writes it: a flight level from 10 000 ft.
    private func constraintText(_ feet: Double) -> String {
        feet >= 10_000 ? "FL" + String(format: "%03d", Int((feet / 100).rounded())) : "\(Int(feet.rounded()))"
    }

    // MARK: Flight-plan airports and runways

    /// The real ND draws a selected runway to scale at the short ranges and
    /// falls back to the airport symbol beyond them.
    private var showsRunwaysToScale: Bool { rangeNm <= ND.runwayMaxRangeNm }

    /// Origin and destination: the selected runway as a white outline to
    /// scale, with its ident and a dashed extended centreline, at the short
    /// ranges; otherwise — and for an airport with no runway selected — a
    /// white airport star with the ICAO code.
    private func drawPlanRunwaysAndAirports(_ context: GraphicsContext, _ g: NDGeometry,
                                            routePoints: [CGPoint]) {
        guard let plan = routePlanner.flightPlan else { return }
        let runways: [(Runway, Airport)] = [(plan.departureRunway, plan.origin), (plan.approachRunway, plan.destination)]
            .compactMap { runway, airport in runway.map { ($0, airport) } }
        var airports = routePlanner.ndPlanAirports
        if showsRunwaysToScale {
            for (runway, _) in runways where g.isInView(runway.coordinate, margin: 1.5) {
                drawRunway(context, g.runwayShape(runway, minimumWidth: ND.runwayMinWidth,
                                                  centrelineNm: ND.runwayCentrelineNm),
                           ident: runway.fixIdent)
            }
        } else {
            airports += runways.map(\.1)
        }
        for airport in airports where g.isInView(airport.coordinate) {
            drawAirportSymbol(context, at: g.project(airport.coordinate), ident: airport.icao,
                              color: .white, avoiding: routePoints)
        }
    }

    private func drawRunway(_ context: GraphicsContext, _ shape: NDRunwayShape, ident: String) {
        context.stroke(shape.centrelinePath, with: .color(.white),
                       style: StrokeStyle(lineWidth: ND.lineWidth, dash: ND.runwayCentrelineDash))
        context.fill(shape.outlinePath, with: .color(EFIS.background))
        context.stroke(shape.outlinePath, with: .color(.white),
                       style: StrokeStyle(lineWidth: ND.lineWidth, lineJoin: .miter))
        let anchor = shape.labelAnchor(offset: ND.runwayMinWidth + 6)
        text(context, ident, x: anchor.x, y: anchor.y, size: ND.fontMap, .white)
    }

    /// An airport: a star of four bars, its ident below right — moved to
    /// the other side when that would put it across the flight plan.
    private func drawAirportSymbol(_ context: GraphicsContext, at: CGPoint, ident: String,
                                   color: Color, avoiding route: [CGPoint]) {
        let r = ND.airportStarRadius
        var star = Path()
        for deg in stride(from: 0.0, to: 180, by: 45) {
            let a = deg * .pi / 180
            star.move(to: CGPoint(x: at.x - r * CGFloat(sin(a)), y: at.y - r * CGFloat(cos(a))))
            star.addLine(to: CGPoint(x: at.x + r * CGFloat(sin(a)), y: at.y + r * CGFloat(cos(a))))
        }
        context.stroke(star, with: .color(EFIS.background), lineWidth: ND.routeWidth * 1.8)
        context.stroke(star, with: .color(color), lineWidth: ND.routeWidth * 0.8)

        let width = CGFloat(ident.count) * ND.advance(ND.fontMap), height = ND.fontMap
        let dx = 1.6 * r, dy = 1.2 * r
        let candidates = [
            CGRect(x: at.x + dx, y: at.y + dy - height / 2, width: width, height: height),
            CGRect(x: at.x + dx, y: at.y - dy - height / 2, width: width, height: height),
            CGRect(x: at.x - dx - width, y: at.y + dy - height / 2, width: width, height: height),
            CGRect(x: at.x - dx - width, y: at.y - dy - height / 2, width: width, height: height),
        ]
        let label = NDLabels.place(candidates, avoiding: route)
        text(context, ident, x: label.minX, y: label.midY, size: ND.fontMap, color)
    }

    private func drawWaypointSymbol(_ context: GraphicsContext, at: CGPoint,
                                    ident: String, color: Color) {
        let half = ND.waypointHalf
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

    /// Altitude constraint: a circle round the waypoint, magenta while the
    /// constraint is predicted to be met. Amber (predicted missed) needs FMS
    /// predictions and the constraint's type, neither of which the plan
    /// carries, so only the met state is drawn.
    private func drawConstraintCircle(_ context: GraphicsContext, at: CGPoint, constraintFt: Double) {
        let r = ND.constraintCircleRadius
        let circle = Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r))
        context.stroke(circle, with: .color(EFIS.background), lineWidth: ND.routeWidth * 1.85)
        context.stroke(circle, with: .color(EFIS.magenta), lineWidth: ND.routeWidth)
    }

    /// Level-off (top of climb): a rising stroke into a level arrow, its
    /// knee on the point. Upright on the screen whatever the heading.
    private func drawLevelOffSymbol(_ context: GraphicsContext, at: CGPoint, color: Color) {
        let s = ND.profileSymbolSize
        var p = Path()
        p.move(to: CGPoint(x: at.x - s, y: at.y + 0.7 * s))
        p.addLine(to: at)
        p.addLine(to: CGPoint(x: at.x + s, y: at.y))
        p.move(to: CGPoint(x: at.x + 0.55 * s, y: at.y - 0.35 * s))
        p.addLine(to: CGPoint(x: at.x + s, y: at.y))
        p.addLine(to: CGPoint(x: at.x + 0.55 * s, y: at.y + 0.35 * s))
        strokeProfileSymbol(context, p, color)
    }

    /// Top of descent: a level stroke into a descending arrow, its knee on
    /// the point.
    private func drawTopOfDescentSymbol(_ context: GraphicsContext, at: CGPoint, color: Color) {
        let s = ND.profileSymbolSize
        let tip = CGPoint(x: at.x + 0.85 * s, y: at.y + 0.6 * s)
        var p = Path()
        p.move(to: CGPoint(x: at.x - s, y: at.y))
        p.addLine(to: at)
        p.addLine(to: tip)
        // Arrowhead along the descending stroke.
        let a = atan2(tip.y - at.y, tip.x - at.x), head = 0.45 * s, spread = 0.45
        p.move(to: CGPoint(x: tip.x - head * cos(a - spread), y: tip.y - head * sin(a - spread)))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x - head * cos(a + spread), y: tip.y - head * sin(a + spread)))
        strokeProfileSymbol(context, p, color)
    }

    /// Decelerate point: a "D" in a circle.
    private func drawDecelSymbol(_ context: GraphicsContext, at: CGPoint, color: Color) {
        let r = ND.decelRadius
        let circle = Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r))
        context.fill(circle, with: .color(EFIS.background))
        context.stroke(circle, with: .color(color), lineWidth: ND.routeWidth)
        text(context, "D", x: at.x, y: at.y, size: ND.fontMap * 0.85, color, anchor: .center)
    }

    private func strokeProfileSymbol(_ context: GraphicsContext, _ path: Path, _ color: Color) {
        context.stroke(path, with: .color(EFIS.background),
                       style: StrokeStyle(lineWidth: ND.routeWidth * 2.2, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: ND.routeWidth * 1.2, lineCap: .round, lineJoin: .round))
    }

    // MARK: Aircraft symbol

    private func drawAirplane(_ context: GraphicsContext, _ layout: NDLayout) {
        var ctx = context
        if layout.mode == .plan {
            // PLAN: the aircraft where it is on the north-up map, pointing
            // along its heading.
            guard let location = flightData.location else { return }
            let at = mapGeometry(layout, location: location).project(location.coordinate)
            ctx.translateBy(x: at.x, y: at.y)
            ctx.rotate(by: .degrees(flightData.headingDeg))
        } else {
            ctx.translateBy(x: layout.planeCenter.x, y: layout.planeCenter.y)
        }

        // Wings, fuselage and tailplane as three strokes of one path.
        typealias A = ND.Airplane
        var plane = Path()
        plane.move(to: CGPoint(x: -A.wingHalfSpan, y: 0))
        plane.addLine(to: CGPoint(x: A.wingHalfSpan, y: 0))
        plane.move(to: CGPoint(x: 0, y: -A.nose))
        plane.addLine(to: CGPoint(x: 0, y: A.tail))
        plane.move(to: CGPoint(x: -A.tailplaneHalfSpan, y: A.tailplaneAt))
        plane.addLine(to: CGPoint(x: A.tailplaneHalfSpan, y: A.tailplaneAt))
        ctx.stroke(plane, with: .color(EFIS.background),
                   style: StrokeStyle(lineWidth: ND.symbolWidth * 1.6, lineCap: .round))
        ctx.stroke(plane, with: .color(EFIS.yellow),
                   style: StrokeStyle(lineWidth: ND.symbolWidth, lineCap: .round))

        guard layout.mode != .plan else { return }
        // Yellow lubber line, fixed across the top of the ring.
        let ringTop = layout.center.y - layout.ringRadius
        var lubber = Path()
        lubber.move(to: CGPoint(x: layout.center.x, y: ringTop - ND.lubberHalfLength))
        lubber.addLine(to: CGPoint(x: layout.center.x, y: ringTop + ND.lubberHalfLength))
        context.stroke(lubber, with: .color(EFIS.background),
                       style: StrokeStyle(lineWidth: ND.symbolWidth * 1.1, lineCap: .round))
        context.stroke(lubber, with: .color(EFIS.yellow),
                       style: StrokeStyle(lineWidth: ND.symbolWidth, lineCap: .round))
    }

    // MARK: ROSE LS and ROSE VOR

    /// The course ROSE LS or ROSE VOR shows. There is no radio receiver on
    /// a phone, so both are worked out from the position:
    /// - LS: the approach runway's localiser — the course along the runway,
    ///   the deviation as seen from its far end, 0.8° a dot — and a 3° glide
    ///   path to the threshold;
    /// - VOR: the first VOR on the plan from the TO waypoint on (else the TO
    ///   waypoint itself), the course the leg into it, 5° a dot.
    private struct RadioCourse {
        let label: String
        let frequency: String?
        let ident: String
        /// Course, degrees true like everything else on the map.
        let courseDeg: Double
        /// Dots, positive with the course lying to the right; nil out of range.
        let deviationDots: Double?
        /// VOR: whether the station lies behind.
        let isFrom: Bool
        /// LS: the glide path, in dots, positive with the path below.
        let glideDots: Double?
        let color: Color
    }

    private var radioCourse: RadioCourse? {
        guard let location = flightData.location else { return nil }
        let here = location.coordinate
        func bearing(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D) -> (bearingDeg: Double, distanceNm: Double) {
            NDGeometry(apex: .zero, radius: 1, rangeNm: 1, origin: from, headingDeg: 0).vector(to: to)
        }

        if mode == .roseLS {
            guard let plan = routePlanner.flightPlan, let runway = plan.approachRunway else { return nil }
            let antenna = GreatCircle.destination(from: runway.coordinate, courseDeg: runway.headingDeg,
                                                  distanceNm: max(runway.lengthNm, 0.5))
            let toAntenna = bearing(here, antenna)
            let deviation = angularDifference(toAntenna.bearingDeg, runway.headingDeg)
            let inRange = toAntenna.distanceNm <= 25 && abs(deviation) <= 35
            let glide = Guidance(flightData: flightData, routePlanner: routePlanner).glideDeviation
            return RadioCourse(label: "ILS1", frequency: nil, ident: runway.fixIdent,
                               courseDeg: runway.headingDeg,
                               deviationDots: inRange ? deviation / 0.8 : nil, isFrom: false,
                               glideDots: inRange ? glide.map { $0 * 2 } : nil, color: EFIS.magenta)
        }

        // ROSE VOR.
        guard let first = routePlanner.toWaypointIndex else { return nil }
        let waypoints = routePlanner.waypoints
        let candidates = waypoints.indices.filter { $0 >= first }.prefix(12)
        func vor(at index: Int) -> Navaid? {
            NavDatabase.shared.navaids(waypoints[index].ident, near: waypoints[index].coordinate).first {
                $0.kind.isVOR && GreatCircle.distanceNm($0.coordinate, waypoints[index].coordinate) < 1
            }
        }
        let found = candidates.lazy.compactMap { i in vor(at: i).map { (i, $0) } }.first
        let index = found?.0 ?? first
        let station = found?.1.coordinate ?? waypoints[index].coordinate
        let previous = index > 0 ? waypoints[index - 1].coordinate : routePlanner.flightPlan?.origin.coordinate
        let toStation = bearing(here, station)
        let course = previous.map { bearing($0, station).bearingDeg } ?? toStation.bearingDeg
        var deviation = angularDifference(toStation.bearingDeg, course)
        let isFrom = abs(deviation) > 90
        if isFrom { deviation = angularDifference(course, normalizedHeading(toStation.bearingDeg + 180)) }
        return RadioCourse(label: "VOR1", frequency: found?.1.frequencyText, ident: waypoints[index].ident,
                           courseDeg: course, deviationDots: deviation / 5, isFrom: isFrom,
                           glideDots: nil, color: EFIS.cyan)
    }

    /// ROSE LS and ROSE VOR, round the aircraft: a circle of short marks
    /// a dot out; the deviation dots, one and two dots either side across
    /// the course, the outer pair on the inner range ring; the course
    /// pointer — its head from the ring to the inner part of the rose with
    /// a crossbar, its tail opposite with a short one — and between them
    /// the deviation bar, with the TO / FROM chevron beside it in ROSE VOR.
    /// In ROSE LS the glide scale stands at the right.
    private func drawRadioCourse(_ context: GraphicsContext, _ bounds: CGRect, _ layout: NDLayout) {
        let r = layout.ringRadius, dot = layout.dotSpacing
        let c = layout.center

        for bearing in stride(from: 0.0, to: 360, by: 30) {
            context.line(from: layout.point(bearingDeg: bearing, radius: dot * 0.86),
                         to: layout.point(bearingDeg: bearing, radius: dot * 1.08), .white, width: ND.lineWidth)
        }

        guard let course = radioCourse else { return }
        var ctx = context
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: .degrees(angularDifference(course.courseDeg, flightData.headingDeg)))

        let dotRadius = r * 0.022
        for n: CGFloat in [-2, -1, 1, 2] {
            ctx.stroke(Path(ellipseIn: CGRect(x: n * dot - dotRadius, y: -dotRadius,
                                              width: 2 * dotRadius, height: 2 * dotRadius)),
                       with: .color(.white), lineWidth: ND.lineWidth)
        }

        let inner = r * 0.37
        var pointer = Path()
        pointer.move(to: CGPoint(x: 0, y: -r))
        pointer.addLine(to: CGPoint(x: 0, y: -inner))
        pointer.move(to: CGPoint(x: -r * 0.08, y: -r * 0.5))
        pointer.addLine(to: CGPoint(x: r * 0.08, y: -r * 0.5))
        pointer.move(to: CGPoint(x: 0, y: inner))
        pointer.addLine(to: CGPoint(x: 0, y: r))
        pointer.move(to: CGPoint(x: -r * 0.04, y: r * 0.5))
        pointer.addLine(to: CGPoint(x: r * 0.04, y: r * 0.5))
        if let deviation = course.deviationDots {
            let x = CGFloat(deviation.clamped(to: -2.2...2.2)) * dot
            pointer.move(to: CGPoint(x: x, y: -inner))
            pointer.addLine(to: CGPoint(x: x, y: inner))
            // VOR: the chevron beside the bar towards the centre, past its
            // tail end, pointing to the station — along the course for TO,
            // back down it for FROM.
            if mode == .roseVOR {
                let cx = x - (x >= 0 ? 1 : -1) * r * 0.075
                let cy = course.isFrom ? -r * 0.52 : r * 0.52
                let arm = r * 0.05, back: CGFloat = course.isFrom ? -arm : arm
                let tip = CGPoint(x: cx, y: cy - back)
                pointer.move(to: CGPoint(x: cx - arm, y: tip.y + back))
                pointer.addLine(to: tip)
                pointer.addLine(to: CGPoint(x: cx + arm, y: tip.y + back))
            }
        }
        let width = ND.lineWidth * 1.6
        ctx.stroke(pointer, with: .color(EFIS.background),
                   style: StrokeStyle(lineWidth: width * 2, lineCap: .round, lineJoin: .round))
        ctx.stroke(pointer, with: .color(course.color),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))

        guard mode == .roseLS else { return }
        // The glide scale beside the rose, its diamond where the path is.
        let x = min(c.x + layout.labelRadius + 60, bounds.maxX - 40)
        for n: CGFloat in [-2, -1, 1, 2] {
            context.stroke(Path(ellipseIn: CGRect(x: x - dotRadius, y: c.y + n * dot - dotRadius,
                                                  width: 2 * dotRadius, height: 2 * dotRadius)),
                           with: .color(.white), lineWidth: ND.lineWidth)
        }
        context.line(from: CGPoint(x: x - r * 0.06, y: c.y), to: CGPoint(x: x + r * 0.06, y: c.y),
                     EFIS.yellow, width: ND.lineWidth * 1.5)
        if let glide = course.glideDots {
            let y = c.y + CGFloat(glide.clamped(to: -2.2...2.2)) * dot
            let h = r * 0.06, w = r * 0.04
            var diamond = Path()
            diamond.move(to: CGPoint(x: x, y: y - h))
            diamond.addLine(to: CGPoint(x: x + w, y: y))
            diamond.addLine(to: CGPoint(x: x, y: y + h))
            diamond.addLine(to: CGPoint(x: x - w, y: y))
            diamond.closeSubpath()
            context.stroke(diamond, with: .color(EFIS.magenta), lineWidth: ND.lineWidth * 1.4)
        }
    }

    /// Top right in ROSE LS and ROSE VOR: the receiver and its frequency
    /// (the decimals small), the course, the station's ident.
    private func drawRadioBlock(_ context: GraphicsContext) {
        let edge = ND.canvas - Self.blockMargin
        let large = ND.advance(ND.fontIntermediate), small = ND.advance(ND.fontSmallest)
        let course = radioCourse
        let label = mode == .roseLS ? "ILS1" : "VOR1"

        // Row 0: VOR1  115.10, the receiver's name in its own column.
        var labelRight = edge
        if let frequency = course?.frequency {
            let parts = frequency.split(separator: ".", maxSplits: 1).map(String.init)
            let decimals = parts.count > 1 ? "." + parts[1] : ""
            text(context, decimals, x: edge, y: Self.row(0), size: ND.fontSmallest, .white, anchor: .trailing)
            let wholeRight = edge - CGFloat(decimals.count) * small
            text(context, parts[0], x: wholeRight, y: Self.row(0), size: ND.fontIntermediate, .white,
                 anchor: .trailing)
            labelRight = wholeRight - CGFloat(parts[0].count) * large - large
        }
        text(context, label, x: labelRight, y: Self.row(0), size: ND.fontIntermediate, .white, anchor: .trailing)

        // Row 1: CRS 210°.
        let crs = course.map { String(format: "%03d", Int($0.courseDeg.rounded()) % 360) } ?? "---"
        text(context, "°", x: edge, y: Self.row(1), size: ND.fontIntermediate, EFIS.cyan, anchor: .trailing)
        text(context, crs, x: edge - large, y: Self.row(1), size: ND.fontIntermediate, EFIS.cyan, anchor: .trailing)
        text(context, "CRS", x: edge - 5 * large, y: Self.row(1), size: ND.fontSmallest, .white, anchor: .trailing)

        // Row 2: the station — white for a VOR, magenta for the localiser.
        if let course {
            text(context, course.ident, x: edge, y: Self.row(2), size: ND.fontIntermediate,
                 mode == .roseLS ? EFIS.magenta : .white, anchor: .trailing)
        }
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
        guard let waypoint = routePlanner.toWaypoint else { return }

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

    /// The range keys move the same range as the EFIS panel's selector;
    /// the change blanks the map (see `onChange(of: rangeIndex)`).
    private func setRange(_ newIndex: Int) {
        guard profile.ndRangesNm.indices.contains(newIndex), newIndex != rangeIndex else { return }
        flightData.autoFlight.ndRangeIndex = newIndex
    }
}

#Preview {
    NDView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
        .environmentObject(FlightPackStore())
        .frame(height: 480)
}
