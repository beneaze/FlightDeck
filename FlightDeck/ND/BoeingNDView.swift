import SwiftUI
import CoreLocation

/// Boeing 737NG Navigation Display in expanded MAP mode: track up, the
/// aircraft low in the picture, the compass arc across the top at the
/// selected range, the flight plan in magenta.
///
/// Drawn into one 1000-unit canvas laid out by ``B737ND``, then scaled to
/// fill the width the way the A320 ND does — the same data and controls, in
/// the 737's symbology.
struct BoeingNDView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @EnvironmentObject private var packs: FlightPackStore
    @StateObject private var terrain = NDTerrainLayer()

    @State private var rangeIndex = AircraftProfile.b737.ndDefaultRangeIndex
    @State private var rangeChangeCount = 0

    var profile: AircraftProfile = .b737

    private var rangeNm: Double { profile.ndRangesNm[rangeIndex] }

    /// Track up: the map and rose are turned so the ground track points
    /// straight up the track line.
    private var upDeg: Double { flightData.trackDeg }

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
                                style: .boeing,
                                showsGround: isFlying)
                .frame(height: 104)
            controlBar
        }
        .background(Boeing.background)
        .onReceive(flightData.$location) { _ in updateTerrain() }
        .onChange(of: rangeIndex) { updateTerrain() }
    }

    private var isFlying: Bool { routePlanner.transportMode == .plane }

    private var elevationStatus: String? {
        if isFlying { return packs.activeTerrain == nil ? "NO TERRAIN" : nil }
        return routePlanner.destination == nil ? nil : routePlanner.elevationStatus
    }

    private func updateTerrain() {
        terrain.update(store: isFlying ? packs.activeTerrain : nil, location: flightData.location,
                       upDeg: upDeg, rangeNm: rangeNm, altitudeFt: flightData.altitudeFt)
    }

    // MARK: Display

    private var display: some View {
        Canvas { context, size in
            // Fill the width, as the A320 ND does: the compass arc reaches the
            // display sides at up to a 60° half-span, unless the height — the
            // band from the data blocks down to just below the aircraft — is
            // the tighter constraint.
            let bandHeight = B737ND.bandBottom - B737ND.bandTop
            let widthAtMaxSpan = 2 * B737ND.ringRadius * CGFloat(sin(B737ND.maxHalfSpanDeg * .pi / 180))
            let scale = min(size.height / bandHeight, size.width / widthAtMaxSpan)
            let offsetY = max(0, (size.height - bandHeight * scale) / 2)

            var ctx = context
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))

            var sector = ctx
            sector.translateBy(x: size.width / 2 - B737ND.center.x * scale,
                               y: offsetY - B737ND.bandTop * scale)
            sector.scaleBy(x: scale, y: scale)

            // The display edges in sector coordinates.
            let bounds = CGRect(x: B737ND.center.x - size.width / 2 / scale,
                                y: B737ND.bandTop - offsetY / scale,
                                width: size.width / scale, height: size.height / scale)

            drawRangeRings(sector)
            drawMap(sector)
            drawTrackLine(sector)
            drawCompass(sector)
            drawAirplane(sector)
            drawHeadingBox(sector)

            // Data blocks anchor to the display corners, not to the sector.
            var left = ctx
            left.scaleBy(x: scale, y: scale)
            drawSpeeds(left)
            drawWind(left)

            var right = ctx
            right.translateBy(x: size.width - B737ND.canvas * scale, y: 0)
            right.scaleBy(x: scale, y: scale)
            drawToWaypoint(right)

            if routePlanner.destination == nil, let error = routePlanner.errorMessage {
                sector.boeingText(error, at: CGPoint(x: B737ND.center.x, y: bounds.maxY - 40),
                                  size: B737ND.fontSmall, Boeing.amber)
            }
        }
    }

    /// Everything inside the compass ring — the map's window.
    private var ringClip: Path {
        let c = B737ND.center, r = B737ND.ringRadius
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    // MARK: Compass

    private func drawCompass(_ context: GraphicsContext) {
        let c = B737ND.center
        let r = B737ND.ringRadius

        // The visible part of the ring, running a little past the last
        // graduation either side.
        var ring = Path()
        for step in stride(from: -B737ND.ringSpanDeg, through: B737ND.ringSpanDeg, by: 1.5) {
            let p = B737ND.point(bearingDeg: step, radius: r)
            step == -B737ND.ringSpanDeg ? ring.move(to: p) : ring.addLine(to: p)
        }
        context.stroke(ring, with: .color(Boeing.white), lineWidth: B737ND.line)

        // Graduations every 5° point inward from the ring; the value every
        // 10°, large every 30°, turns with the rose.
        for deg in stride(from: 0, to: 360, by: 5) {
            let diff = angularDifference(Double(deg), upDeg)
            guard abs(diff) <= B737ND.tickSpanDeg else { continue }
            var tick = context
            tick.translateBy(x: c.x, y: c.y)
            tick.rotate(by: .degrees(diff))
            let tens = deg % 10 == 0
            tick.line(from: CGPoint(x: 0, y: -r),
                      to: CGPoint(x: 0, y: -r + (tens ? B737ND.majorTick : B737ND.minorTick)),
                      Boeing.white, width: B737ND.line)
            if tens {
                // Each label sits a fixed gap inside its tick, measured to
                // the label's centre, so the larger thirties sit deeper.
                let large = deg % 30 == 0
                let size = large ? B737ND.fontLarge : B737ND.fontMedium
                tick.boeingText("\(deg / 10)",
                                at: CGPoint(x: 0, y: -r + B737ND.majorTick + B737ND.labelGap + size / 2),
                                size: size)
            }
        }

        // Heading pointer: a hollow triangle outside the ring at the heading —
        // the only pointer; the track is the line straight up from the aircraft.
        let drift = angularDifference(flightData.headingDeg, upDeg)
        if abs(drift) <= B737ND.tickSpanDeg {
            var pointer = context
            pointer.translateBy(x: c.x, y: c.y)
            pointer.rotate(by: .degrees(drift))
            let half = B737ND.pointerHalfWidth, height = B737ND.pointerHeight
            pointer.polygon([CGPoint(x: 0, y: -r), CGPoint(x: -half, y: -r - height),
                             CGPoint(x: half, y: -r - height)],
                            fill: Boeing.background, stroke: Boeing.white, lineWidth: B737ND.line)
        }

        // MCP heading bug on the ring: always shown, at the MCP heading —
        // the route course until a heading has been set. While HDG SEL is
        // engaged the selected heading line runs dashed from the aircraft
        // to the bug.
        let autoFlight = flightData.autoFlight
        if let course = autoFlight.headingTargetDeg
            ?? Guidance(flightData: flightData, routePlanner: routePlanner).bearing {
            let diff = angularDifference(course, upDeg)
            if autoFlight.isHeadingSelected {
                var line = context
                line.clip(to: ringClip)
                var p = Path()
                p.move(to: B737ND.planeApex)
                p.addLine(to: polarPoint(B737ND.planeApex, diff, 2 * r))
                line.stroke(p, with: .color(Boeing.magenta),
                            style: StrokeStyle(lineWidth: B737ND.thinLine, dash: B737ND.headingLineDash))
            }
            if abs(diff) <= B737ND.tickSpanDeg {
                var bug = context
                bug.translateBy(x: c.x, y: c.y)
                bug.rotate(by: .degrees(diff))
                // A box standing on the ring with a V notch cut into its top,
                // the notch's point on the selected heading.
                let w = B737ND.bugHalfWidth, h = B737ND.bugHeight
                let notch = B737ND.bugNotchHalfWidth, depth = B737ND.bugNotchDepth
                bug.polygon([
                    CGPoint(x: -w, y: -r), CGPoint(x: -w, y: -r - h), CGPoint(x: -notch, y: -r - h),
                    CGPoint(x: 0, y: -r - h + depth), CGPoint(x: notch, y: -r - h), CGPoint(x: w, y: -r - h),
                    CGPoint(x: w, y: -r),
                ], stroke: Boeing.magenta, lineWidth: B737ND.line)
            }
        }
    }

    /// The heading readout at the top of the rose: HDG and MAG in green either
    /// side of a box that is open at the top, with the track line running
    /// straight down from the box's bottom edge onto the arc.
    private func drawHeadingBox(_ context: GraphicsContext) {
        let box = B737ND.headingBox
        let ringTop = B737ND.center.y - B737ND.ringRadius
        context.fill(Path(box), with: .color(Boeing.background))
        var outline = Path()
        outline.move(to: CGPoint(x: box.minX, y: box.minY))
        outline.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        outline.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        outline.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        context.stroke(outline, with: .color(Boeing.white), lineWidth: B737ND.line)
        context.line(from: CGPoint(x: box.midX, y: box.maxY), to: CGPoint(x: box.midX, y: ringTop),
                     Boeing.white, width: B737ND.line)
        context.boeingText(String(format: "%03d", Int(flightData.headingDeg.rounded()) % 360),
                           at: CGPoint(x: box.midX, y: box.midY), size: B737ND.fontReadout)
        let gap = B737ND.headingLabelGap
        context.boeingText("HDG", at: CGPoint(x: box.minX - gap, y: box.midY), size: B737ND.fontSmall + 2,
                           Boeing.green, anchor: .trailing)
        context.boeingText("MAG", at: CGPoint(x: box.maxX + gap, y: box.midY), size: B737ND.fontSmall + 2,
                           Boeing.green, anchor: .leading)
    }

    // MARK: Range rings and track line

    /// Thin arcs at each quarter of the range, ahead of the aircraft only,
    /// with the half-range value beside the track line.
    private func drawRangeRings(_ context: GraphicsContext) {
        let c = B737ND.center
        var ctx = context
        ctx.clip(to: Path(CGRect(x: -4_000, y: -4_000, width: 8_000, height: 4_000 + c.y)))
        for quarter in 1...3 {
            let r = B737ND.ringRadius * CGFloat(quarter) / 4
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(Boeing.white), lineWidth: B737ND.thinLine)
        }
        // Half the range, just left of the track line above the middle ring.
        context.boeingText(rangeLabel(rangeNm / 2),
                           at: CGPoint(x: c.x - B737ND.rangeLabelInset,
                                       y: c.y - B737ND.ringRadius / 2 - B737ND.rangeLabelInset),
                           size: B737ND.fontMedium, anchor: .trailing)
    }

    private func rangeLabel(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        var text = String(format: value < 1 ? "%.2f" : "%.1f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The track line runs straight up from the aircraft to the ring, with a
    /// cross tick at each range ring.
    private func drawTrackLine(_ context: GraphicsContext) {
        let c = B737ND.center
        context.line(from: B737ND.planeApex, to: CGPoint(x: c.x, y: c.y - B737ND.ringRadius + B737ND.line),
                     Boeing.white, width: B737ND.line)
        let half = B737ND.trackTickHalfWidth
        for quarter in 1...3 {
            let y = c.y - B737ND.ringRadius * CGFloat(quarter) / 4
            context.line(from: CGPoint(x: c.x - half, y: y), to: CGPoint(x: c.x + half, y: y),
                         Boeing.white, width: B737ND.line)
        }
    }

    // MARK: Map

    private func drawMap(_ context: GraphicsContext) {
        guard let location = flightData.location else {
            context.boeingText("MAP", at: B737ND.flagPoint, size: B737ND.fontLarge, Boeing.amber)
            return
        }
        guard rangeChangeCount == 0 else {
            context.boeingText("MAP RANGE CHANGE", at: B737ND.flagPoint, size: B737ND.fontMedium,
                               Boeing.amber)
            return
        }

        var ctx = context
        ctx.clip(to: ringClip)

        let g = NDGeometry(apex: B737ND.center, radius: B737ND.ringRadius,
                           rangeNm: rangeNm, origin: location.coordinate, headingDeg: upDeg)

        // In flight: terrain under everything, then the airports around.
        if isFlying {
            terrain.draw(in: ctx, geometry: g, clipCenter: B737ND.center, clipRadius: B737ND.ringRadius,
                         sweepOrigin: B737ND.planeApex)
        }

        // The active route: one solid magenta line.
        let coordinates = routePlanner.remainingRouteCoordinates(maximumCount: 400)
        let routePoints = coordinates.map(g.project)
        if routePoints.count > 1 {
            var path = Path()
            path.addLines(routePoints)
            ctx.stroke(path, with: .color(Boeing.magenta), lineWidth: B737ND.routeLine)
        }

        if routePlanner.routeCoordinates.count < 2, let waypoint = routePlanner.waypoints.first {
            var leg = Path()
            leg.move(to: g.apex)
            leg.addLine(to: g.project(waypoint.coordinate))
            ctx.stroke(leg, with: .color(Boeing.magenta), lineWidth: B737ND.routeLine)
        }

        // Other airports (the ARPT map switch): cyan circles, the idents
        // kept off the route line.
        if isFlying {
            let planned = Set(routePlanner.flightPlan.map { [$0.origin.icao, $0.destination.icao] } ?? [])
            for airport in g.airportsInView(excluding: planned) {
                drawAirportSymbol(ctx, at: g.project(airport.coordinate), ident: airport.icao,
                                  color: Boeing.cyan, avoiding: routePoints)
            }
        }

        drawPlanRunwaysAndAirports(ctx, g, routePoints: routePoints)

        // Waypoints from the active one onward: the active one magenta, the
        // rest white, each with its ident and, under it, its altitude
        // constraint. The VNAV points are green circles with their label.
        for point in routePlanner.ndPlanPoints {
            let at = g.project(point.coordinate)
            switch point.kind {
            case .fix:
                drawWaypointSymbol(ctx, at: at, ident: point.ident, constraintFt: point.constraintFt,
                                   color: point.isActive ? Boeing.magenta : Boeing.white)
            case .topOfClimb, .topOfDescent, .decel:
                drawProfilePoint(ctx, at: at, label: point.ident)
            case .runway:
                if !showsRunwaysToScale {
                    drawWaypointSymbol(ctx, at: at, ident: point.ident, constraintFt: nil,
                                       color: point.isActive ? Boeing.magenta : Boeing.white)
                }
            case .airport:
                break // drawn with the plan's airports
            }
        }
    }

    // MARK: Flight-plan airports and runways

    /// Selected runways are drawn to scale at the short map ranges.
    private var showsRunwaysToScale: Bool { rangeNm <= B737ND.runwayMaxRangeNm }

    /// Origin and destination: the selected runway as a white outline to
    /// scale with dashed extended centreline and its ident at the short
    /// ranges; otherwise, and with no runway selected, a white airport
    /// circle with the ICAO code.
    private func drawPlanRunwaysAndAirports(_ context: GraphicsContext, _ g: NDGeometry,
                                            routePoints: [CGPoint]) {
        guard let plan = routePlanner.flightPlan else { return }
        let runways: [(Runway, Airport)] = [(plan.departureRunway, plan.origin), (plan.approachRunway, plan.destination)]
            .compactMap { runway, airport in runway.map { ($0, airport) } }
        var airports = routePlanner.ndPlanAirports
        if showsRunwaysToScale {
            for (runway, _) in runways where g.isInView(runway.coordinate, margin: 1.5) {
                let shape = g.runwayShape(runway, minimumWidth: B737ND.runwayMinWidth,
                                          centrelineNm: B737ND.runwayCentrelineNm)
                context.stroke(shape.centrelinePath, with: .color(Boeing.white),
                               style: StrokeStyle(lineWidth: B737ND.thinLine, dash: B737ND.runwayCentrelineDash))
                context.polygon(shape.outline, fill: Boeing.background, stroke: Boeing.white,
                                lineWidth: B737ND.thinLine)
                context.boeingText(runway.fixIdent, at: shape.labelAnchor(offset: B737ND.runwayMinWidth + 8),
                                   size: B737ND.fontSmall, Boeing.white, anchor: .leading)
            }
        } else {
            airports += runways.map(\.1)
        }
        for airport in airports where g.isInView(airport.coordinate) {
            drawAirportSymbol(context, at: g.project(airport.coordinate), ident: airport.icao,
                              color: Boeing.white, avoiding: routePoints)
        }
    }

    /// An airport: a circle with its ident below right, moved to another
    /// side when that would put it across the route.
    private func drawAirportSymbol(_ context: GraphicsContext, at p: CGPoint, ident: String,
                                   color: Color, avoiding route: [CGPoint]) {
        let r = B737ND.airportRadius
        context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(color), lineWidth: B737ND.line * 0.8)
        let width = context.boeingTextWidth(ident, size: B737ND.fontSmall), height = B737ND.fontSmall
        let dx = 1.6 * r, dy = 1.4 * r
        let candidates = [
            CGRect(x: p.x + dx, y: p.y + dy - height / 2, width: width, height: height),
            CGRect(x: p.x + dx, y: p.y - dy - height / 2, width: width, height: height),
            CGRect(x: p.x - dx - width, y: p.y + dy - height / 2, width: width, height: height),
            CGRect(x: p.x - dx - width, y: p.y - dy - height / 2, width: width, height: height),
        ]
        let label = NDLabels.place(candidates, avoiding: route)
        context.boeingText(ident, at: CGPoint(x: label.minX, y: label.midY), size: B737ND.fontSmall,
                           color, anchor: .leading)
    }

    /// The four-point waypoint star, drawn in outline: points on the axes,
    /// waists between. The ident sits below right in the star's colour, the
    /// altitude constraint on the line under it.
    private func drawWaypointSymbol(_ context: GraphicsContext, at p: CGPoint, ident: String,
                                    constraintFt: Double?, color: Color) {
        let outer = B737ND.starRadius, inner = B737ND.starRadius * 0.3
        let star = (0..<8).map { i in polarPoint(p, Double(i) * 45, i % 2 == 0 ? outer : inner) }
        context.polygon(star, fill: Boeing.background, stroke: color, lineWidth: B737ND.line * 0.75)
        let identAt = CGPoint(x: p.x + 1.3 * outer, y: p.y + 1.2 * outer)
        context.boeingText(ident, at: identAt, size: B737ND.fontSmall, color, anchor: .leading)
        if let constraintFt {
            context.boeingText(constraintText(constraintFt),
                               at: CGPoint(x: identAt.x, y: identAt.y + B737ND.fontSmall),
                               size: B737ND.fontSmall, color, anchor: .leading)
        }
    }

    /// "FL120" from the flight levels up (as the MCDU writes them), else
    /// feet: "5000".
    private func constraintText(_ feet: Double) -> String {
        feet >= 10_000 ? "FL\(Int((feet / 100).rounded()))" : "\(Int((feet / 10).rounded()) * 10)"
    }

    /// T/C, T/D and DECEL: a small green circle on the path, labelled.
    private func drawProfilePoint(_ context: GraphicsContext, at p: CGPoint, label: String) {
        let r = B737ND.profilePointRadius
        context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(Boeing.green), lineWidth: B737ND.line * 0.8)
        context.boeingText(label, at: CGPoint(x: p.x + 1.8 * r, y: p.y + 1.6 * r),
                           size: B737ND.fontSmall, Boeing.green, anchor: .leading)
    }

    // MARK: Aircraft symbol

    /// A hollow isosceles triangle, apex up at the aircraft's position.
    private func drawAirplane(_ context: GraphicsContext) {
        let apex = B737ND.planeApex
        let half = B737ND.planeHalfWidth, length = B737ND.planeLength
        context.polygon([apex, CGPoint(x: apex.x - half, y: apex.y + length),
                         CGPoint(x: apex.x + half, y: apex.y + length)],
                        fill: Boeing.background, stroke: Boeing.white, lineWidth: B737ND.heavyLine)
    }

    // MARK: Data blocks

    private func drawSpeeds(_ context: GraphicsContext) {
        let unit = flightData.speedUnit.perKnot
        let y = B737ND.row(0), margin = B737ND.blockMargin
        let gsValueRight = margin + B737ND.speedColumnWidth
        let tasLabelX = gsValueRight + B737ND.columnGap
        let tasValueRight = tasLabelX + B737ND.speedColumnWidth + B737ND.columnGap
        context.boeingText("GS", at: CGPoint(x: margin, y: y), size: B737ND.fontSmall, anchor: .leading)
        context.boeingText("\(Int((flightData.groundSpeedKts * unit).rounded()))",
                           at: CGPoint(x: gsValueRight, y: y), size: B737ND.fontValue, anchor: .trailing)
        context.boeingText("TAS", at: CGPoint(x: tasLabelX, y: y), size: B737ND.fontSmall, anchor: .leading)
        context.boeingText("\(Int((flightData.tasKts * unit).rounded()))",
                           at: CGPoint(x: tasValueRight, y: y), size: B737ND.fontValue, anchor: .trailing)
    }

    /// Wind direction and speed under the speeds, the arrow below them
    /// pointing the way the wind blows across the display.
    private func drawWind(_ context: GraphicsContext) {
        let direction = flightData.windDirDeg
        let speed = flightData.windSpeedKts
        let directionText = direction.map { String(format: "%03d", Int($0.rounded()) % 360) } ?? "---"
        let speedText = speed.map { "\(Int(($0 * flightData.speedUnit.perKnot).rounded()))" } ?? "--"
        context.boeingText("\(directionText)°/\(speedText)",
                           at: CGPoint(x: B737ND.blockMargin + 2, y: B737ND.row(1)),
                           size: B737ND.fontMedium, anchor: .leading)

        guard let direction, let speed, speed > 2 else { return }
        let half = B737ND.windArrowHalfLength
        var ctx = context
        ctx.translateBy(x: B737ND.blockMargin + 60, y: B737ND.row(1) + B737ND.rowHeight / 2 + half + 4)
        ctx.rotate(by: .degrees(direction - upDeg + 180))
        ctx.line(from: CGPoint(x: 0, y: half), to: CGPoint(x: 0, y: -half), Boeing.white, width: B737ND.line)
        let head = half * 0.55
        ctx.polygon([CGPoint(x: 0, y: -half), CGPoint(x: -head * 0.6, y: -half + head),
                     CGPoint(x: head * 0.6, y: -half + head)], fill: Boeing.white)
    }

    /// Active waypoint block, top right: ident, ETA and distance to go, all
    /// right-aligned on the display edge; the distance leaves room for "NM".
    private func drawToWaypoint(_ context: GraphicsContext) {
        guard let waypoint = routePlanner.toWaypoint else { return }
        let right = B737ND.canvas - B737ND.blockMargin
        context.boeingText(waypoint.ident, at: CGPoint(x: right, y: B737ND.row(0)), size: B737ND.fontValue,
                           Boeing.magenta, anchor: .trailing)
        guard let location = flightData.location,
              let distance = routePlanner.distanceNm(to: waypoint, from: location) else { return }

        if let eta = utcArrival(afterNm: distance) {
            context.boeingText(eta, at: CGPoint(x: right, y: B737ND.row(1)), size: B737ND.fontMedium,
                               anchor: .trailing)
        }
        let unitWidth = B737ND.fontSmall * 1.6
        context.boeingText(distance > 20 ? "\(Int(distance.rounded()))" : String(format: "%.1f", distance),
                           at: CGPoint(x: right - unitWidth - 4, y: B737ND.row(2)), size: B737ND.fontMedium,
                           anchor: .trailing)
        context.boeingText("NM", at: CGPoint(x: right - unitWidth, y: B737ND.row(2) + 1),
                           size: B737ND.fontSmall - 4, anchor: .leading)
    }

    private func utcArrival(afterNm distance: Double) -> String? {
        guard flightData.groundSpeedKts > 10 else { return nil }
        let arrival = Date().addingTimeInterval(distance / flightData.groundSpeedKts * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute], from: arrival)
        return String(format: "%02d%02dz", parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: Controls

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
        .background(Boeing.background)
    }

    private func setRange(_ newIndex: Int) {
        guard profile.ndRangesNm.indices.contains(newIndex), newIndex != rangeIndex else { return }
        rangeIndex = newIndex
        rangeChangeCount += 1
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            rangeChangeCount -= 1
        }
    }
}

#Preview {
    BoeingNDView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
        .environmentObject(FlightPackStore())
        .frame(height: 480)
}

/// Layout of the 737-style ND in expanded MAP mode, on a 1000-unit canvas:
/// the aircraft low in the picture, the compass arc across the top at the
/// selected range, the heading box above the arc and the data blocks in the
/// top corners. A few design values below; everything else is placed from
/// them.
enum B737ND {
    static let canvas: CGFloat = 1000

    // MARK: Rose

    /// The heading box sits at the top centre; the compass ring's top lies a
    /// fixed gap below it, and the ring's radius is the full selected range.
    static let headingBoxWidth: CGFloat = 112
    static let headingBoxHeight: CGFloat = 54
    static let headingBoxTop: CGFloat = 26
    static let ringGapBelowBox: CGFloat = 22
    static let ringRadius: CGFloat = 680

    static var headingBox: CGRect {
        CGRect(x: canvas / 2 - headingBoxWidth / 2, y: headingBoxTop,
               width: headingBoxWidth, height: headingBoxHeight)
    }
    /// Centre of the compass rose and the range rings.
    static var center: CGPoint {
        CGPoint(x: canvas / 2, y: headingBox.maxY + ringGapBelowBox + ringRadius)
    }
    /// Apex of the aircraft symbol, just under the rose centre.
    static var planeApex: CGPoint { CGPoint(x: center.x, y: center.y + 6) }

    /// Where the MAP / MAP RANGE CHANGE flags appear: a little above the
    /// middle of the arc's sector.
    static var flagPoint: CGPoint { CGPoint(x: center.x, y: center.y - 0.45 * ringRadius) }

    // MARK: Symbols and lines

    static let line: CGFloat = 4
    static let thinLine: CGFloat = 2.4
    static let heavyLine: CGFloat = 5
    static let routeLine: CGFloat = 5

    static let majorTick: CGFloat = 42
    static let minorTick: CGFloat = 20
    /// Gap between a ten-degree tick's inner end and its label's edge.
    static let labelGap: CGFloat = 10
    static let pointerHalfWidth: CGFloat = 18
    static let pointerHeight: CGFloat = 28
    static let bugHalfWidth: CGFloat = 26
    static let bugHeight: CGFloat = 24
    static let bugNotchHalfWidth: CGFloat = 14
    static let bugNotchDepth: CGFloat = 16
    static let headingLineDash: [CGFloat] = [20, 14]
    static let headingLabelGap: CGFloat = 12
    static let rangeLabelInset: CGFloat = 16
    static let trackTickHalfWidth: CGFloat = 12
    static let planeHalfWidth: CGFloat = 32
    static let planeLength: CGFloat = 66
    static let starRadius: CGFloat = 20
    static var airportRadius: CGFloat { starRadius * 0.7 }
    static var profilePointRadius: CGFloat { starRadius * 0.6 }

    /// Selected runways are drawn to scale up to this range, with the
    /// extended centreline the 737 shows from the threshold.
    static let runwayMaxRangeNm = 40.0
    static let runwayMinWidth: CGFloat = 10
    static let runwayCentrelineNm = 14.2
    static let runwayCentrelineDash: [CGFloat] = [16, 12]
    static let windArrowHalfLength: CGFloat = 36

    // MARK: Type

    static let fontLarge: CGFloat = 48
    static let fontReadout: CGFloat = 44
    static let fontValue: CGFloat = 40
    static let fontMedium: CGFloat = 36
    static let fontSmall: CGFloat = 30

    // MARK: Data blocks

    static let blockMargin: CGFloat = 6
    static let rowHeight: CGFloat = 46
    /// Centre line of the `n`th row of a corner data block.
    static func row(_ n: Int) -> CGFloat { 28 + CGFloat(n) * rowHeight }
    /// Room for a three-digit speed after its label.
    static let speedColumnWidth: CGFloat = 118
    static let columnGap: CGFloat = 16

    // MARK: Fitting the screen

    /// A phone's ND area is rarely square. As on the A320 ND, the picture
    /// fills the available width — the compass arc reaching the sides at up
    /// to `maxHalfSpanDeg` either side of the track line — and the vertical
    /// band from the top data blocks to just below the aircraft
    /// (`bandTop`…`bandBottom`) is what must fit the height.
    static let maxHalfSpanDeg = 60.0
    static let bandTop: CGFloat = 0
    static var bandBottom: CGFloat { planeApex.y + planeLength + 32 }

    /// The arc itself runs a little past the last graduation.
    static let ringSpanDeg = 75.0
    /// Graduations and labels stop here.
    static let tickSpanDeg = 70.0

    static func point(bearingDeg: Double, radius: CGFloat) -> CGPoint {
        polarPoint(center, bearingDeg, radius)
    }
}
