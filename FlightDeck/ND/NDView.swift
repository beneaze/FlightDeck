import SwiftUI
import CoreLocation

/// A320 Navigation Display in ARC mode: the aircraft sits low in the sector,
/// the compass rose arcs across the top, and the flight plan runs away from
/// the aircraft between dashed range arcs.
///
/// Like the PFD, the whole instrument is drawn into one canvas in the
/// display's native 768-unit coordinate system (see ``ND``), then scaled to
/// fit. Geometry, colours and type sizes follow the FlyByWire A32NX ND.
struct NDView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner

    @State private var rangeIndex = AircraftProfile.a320.ndDefaultRangeIndex
    /// Non-zero while the display is "recomputing" after a range change — the
    /// real unit blanks the map for half a second and shows RANGE CHANGE.
    @State private var rangeChangeCount = 0

    var profile: AircraftProfile = .a320

    private var rangeNm: Double { profile.ndRangesNm[rangeIndex] }

    var body: some View {
        VStack(spacing: 0) {
            display
            VerticalDisplayView(altitudeFt: flightData.altitudeFt,
                                selectedAltitudeFt: flightData.selectedAltitudeFt,
                                flightPathAngleDeg: flightData.flightPathAngleDeg,
                                rangeNm: rangeNm,
                                destinationName: routePlanner.destination?.name,
                                destinationDistanceNm: routePlanner.distanceToGoNm(
                                    from: flightData.location))
                .frame(height: 92)
            controlBar
        }
        .background(EFIS.background)
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

            // Layer order: rose underlay, map, then the track indication over
            // the flight plan — so the line stays visible with a route active
            // — and the aircraft symbol on top.
            drawCompass(sector)
            drawRangeArcs(sector, bounds)
            drawMap(sector, bounds)
            drawTrackIndication(sector)
            drawAirplane(sector)

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
                text(sector, error, x: ND.center.x, y: bounds.maxY - 12,
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
        ctx.stroke(ring, with: .color(.white), lineWidth: 2)

        // Graduations every 5° stand outward of the ring: 29 px at 10°
        // multiples, 15 px between. Labels rotate with the rose, in the large
        // face every 30° and the small face otherwise.
        for deg in stride(from: 0, to: 360, by: 5) {
            let diff = angularDifference(Double(deg), heading)
            guard abs(diff) <= ND.tickSpanDeg else { continue }

            var tick = ctx
            tick.translateBy(x: ND.center.x, y: ND.center.y)
            tick.rotate(by: .degrees(diff))

            let major = deg % 10 == 0
            tick.line(from: CGPoint(x: 0, y: -ND.ringRadius),
                      to: CGPoint(x: 0, y: -ND.ringRadius - (major ? 29 : 15)),
                      .white, width: 2)

            if major {
                let size: CGFloat = deg % 30 == 0 ? 34 : 22
                tick.digits("\(deg / 10)",
                            at: CGPoint(x: 0, y: -(529 + size * 0.36)),
                            size: size, .white)
            }
        }
    }

    private func drawRangeArcs(_ context: GraphicsContext, _ bounds: CGRect) {
        for arc in ND.rangeArcs {
            var ctx = context
            ctx.clip(to: arc.clip(in: bounds))
            let circle = Path(ellipseIn: CGRect(x: ND.center.x - arc.radius,
                                                y: ND.center.y - arc.radius,
                                                width: arc.radius * 2,
                                                height: arc.radius * 2))
            ctx.stroke(circle, with: .color(.white),
                       style: StrokeStyle(lineWidth: 2, dash: arc.dash,
                                          dashPhase: arc.dashPhase))
        }

        // The half and three-quarter arcs carry their distance at both ends.
        let threeQuarter = rangeLabel(rangeNm * 0.75)
        text(context, threeQuarter, x: 58, y: 482, size: ND.fontSmallest, EFIS.cyan)
        text(context, threeQuarter, x: 709, y: 482, size: ND.fontSmallest, EFIS.cyan,
             anchor: .trailing)

        let half = rangeLabel(rangeNm * 0.5)
        text(context, half, x: 175, y: 528, size: ND.fontSmallest, EFIS.cyan)
        text(context, half, x: 592, y: 528, size: ND.fontSmallest, EFIS.cyan,
             anchor: .trailing)
    }

    private func rangeLabel(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        var text = String(format: value < 1 ? "%.2f" : "%.1f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
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

        var line = Path()
        line.move(to: CGPoint(x: 0, y: 149 - ND.center.y))
        line.addLine(to: .zero)
        ctx.stroke(line, with: .color(EFIS.background),
                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
        ctx.stroke(line, with: .color(EFIS.green),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        // The diamond disappears once the drift angle would carry it off the
        // visible sector.
        guard abs(diff) <= 40 else { return }
        var diamond = Path()
        diamond.move(to: CGPoint(x: 0, y: -492))
        diamond.addLine(to: CGPoint(x: -6, y: -482))
        diamond.addLine(to: CGPoint(x: 0, y: -472))
        diamond.addLine(to: CGPoint(x: 6, y: -482))
        diamond.closeSubpath()
        ctx.stroke(diamond, with: .color(EFIS.background),
                   style: StrokeStyle(lineWidth: 4.5, lineJoin: .round))
        ctx.stroke(diamond, with: .color(EFIS.green),
                   style: StrokeStyle(lineWidth: 3, lineJoin: .round))
    }

    // MARK: Map

    private func drawMap(_ context: GraphicsContext, _ bounds: CGRect) {
        guard let location = flightData.location else {
            text(context, "MAP NOT AVAIL", x: 384, y: 320.6, size: ND.fontLarge,
                 EFIS.red, anchor: .center)
            return
        }

        // While the new scale is computed the map blanks and the annunciation
        // shows in the middle of the sector.
        guard rangeChangeCount == 0 else {
            text(context, "RANGE CHANGE", x: 384, y: 320, size: ND.fontIntermediate,
                 EFIS.green, anchor: .center)
            return
        }

        var ctx = context
        ctx.clip(to: ND.mapClip(in: bounds))

        let g = NDGeometry(apex: ND.planeCenter, radius: ND.mapRadius,
                           rangeNm: rangeNm, origin: location.coordinate,
                           headingDeg: flightData.headingDeg)

        // The not-yet-flown part of the plan; sequenced legs disappear behind.
        let coordinates = routePlanner.remainingRouteCoordinates(maximumCount: 400)
        if coordinates.count > 1 {
            var path = Path()
            for (index, coordinate) in coordinates.enumerated() {
                let p = g.project(coordinate)
                index == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.stroke(path, with: .color(EFIS.green), lineWidth: 1.75)
        }

        // With no computed route, the direct-to leg is the active flight plan.
        if routePlanner.route == nil, let waypoint = routePlanner.waypoints.first {
            var leg = Path()
            leg.move(to: g.apex)
            leg.addLine(to: g.project(waypoint.coordinate))
            ctx.stroke(leg, with: .color(EFIS.green), lineWidth: 1.75)
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

    private func drawWaypointSymbol(_ context: GraphicsContext, at: CGPoint,
                                    ident: String, color: Color) {
        let half: CGFloat = 4.5 * 2.0.squareRoot()
        var diamond = Path()
        diamond.move(to: CGPoint(x: at.x, y: at.y - half))
        diamond.addLine(to: CGPoint(x: at.x + half, y: at.y))
        diamond.addLine(to: CGPoint(x: at.x, y: at.y + half))
        diamond.addLine(to: CGPoint(x: at.x - half, y: at.y))
        diamond.closeSubpath()
        context.stroke(diamond, with: .color(EFIS.background), lineWidth: 3.25)
        context.stroke(diamond, with: .color(color), lineWidth: 1.75)
        text(context, ident, x: at.x + 15, y: at.y + 17, size: ND.fontMap, color)
    }

    // MARK: Aircraft symbol

    private func drawAirplane(_ context: GraphicsContext) {
        // Wings, fuselage and tailplane as three strokes of one path.
        var plane = Path()
        plane.move(to: CGPoint(x: 343, y: 626))
        plane.addLine(to: CGPoint(x: 425, y: 626))
        plane.move(to: CGPoint(x: 384, y: 596.5))
        plane.addLine(to: CGPoint(x: 384, y: 666.75))
        plane.move(to: CGPoint(x: 372.5, y: 657))
        plane.addLine(to: CGPoint(x: 396, y: 657))
        context.stroke(plane, with: .color(EFIS.background),
                       style: StrokeStyle(lineWidth: 8, lineCap: .round))
        context.stroke(plane, with: .color(EFIS.yellow),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round))

        // Yellow lubber line, fixed at the top of the rose.
        var lubber = Path()
        lubber.move(to: CGPoint(x: 384, y: 108))
        lubber.addLine(to: CGPoint(x: 384, y: 148))
        context.stroke(lubber, with: .color(EFIS.background),
                       style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
        context.stroke(lubber, with: .color(EFIS.yellow),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round))
    }

    // MARK: Data blocks

    /// Ground speed and true airspeed, top left, in the selected unit.
    private func drawSpeeds(_ context: GraphicsContext) {
        let unit = flightData.speedUnit.perKnot
        text(context, "GS", x: 2, y: 25, size: ND.fontSmallest, .white)
        text(context, "\(Int((flightData.groundSpeedKts * unit).rounded()))",
             x: 91, y: 25, size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
        text(context, "TAS", x: 97, y: 25, size: ND.fontSmallest, .white)
        text(context, "\(Int((flightData.tasKts * unit).rounded()))",
             x: 203, y: 25, size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
    }

    /// Wind vector under the speeds: direction/speed and an arrow pointing the
    /// way the wind is blowing across the display.
    private func drawWind(_ context: GraphicsContext) {
        let direction = flightData.windDirDeg
        let speed = flightData.windSpeedKts

        let directionText = direction.map { String(format: "%03d", Int($0.rounded()) % 360) } ?? "---"
        let speedText = speed.map { "\(Int(($0 * flightData.speedUnit.perKnot).rounded()))" } ?? "---"

        text(context, directionText, x: 48, y: 58, size: ND.fontSmall, EFIS.green,
             anchor: .trailing)
        text(context, "/", x: 54, y: 57, size: ND.fontSmallest, .white)
        text(context, speedText, x: 73, y: 58, size: ND.fontSmall, EFIS.green)

        guard let direction, let speed, speed > 2 else { return }
        var ctx = context
        ctx.translateBy(x: 26, y: 83)
        ctx.rotate(by: .degrees(direction - flightData.headingDeg + 180))
        var arrow = Path()
        arrow.move(to: CGPoint(x: 0, y: 15))
        arrow.addLine(to: CGPoint(x: 0, y: -15))
        arrow.move(to: CGPoint(x: -6.5, y: -3))
        arrow.addLine(to: CGPoint(x: 0, y: -15))
        arrow.addLine(to: CGPoint(x: 6.5, y: -3))
        ctx.stroke(arrow, with: .color(EFIS.green),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    /// TO-waypoint block, top right: the active waypoint's ident, bearing,
    /// along-route distance and ETA — not the final destination's.
    private func drawToWaypoint(_ context: GraphicsContext) {
        guard let waypoint = routePlanner.activeWaypoint else { return }

        text(context, waypoint.ident,
             x: 677, y: 25, size: ND.fontIntermediate, .white, anchor: .trailing)

        guard let location = flightData.location else { return }

        let bearing = NDGeometry(apex: .zero, radius: 1, rangeNm: 1,
                                 origin: location.coordinate, headingDeg: 0)
            .vector(to: waypoint.coordinate).bearingDeg
        text(context, String(format: "%03d", Int(bearing.rounded()) % 360),
             x: 747, y: 25, size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
        text(context, "°", x: 763, y: 27, size: ND.fontIntermediate, EFIS.cyan,
             anchor: .trailing)

        if let distance = routePlanner.distanceNm(to: waypoint, from: location) {
            if distance > 20 {
                text(context, "\(Int(distance.rounded()))", x: 729, y: 57,
                     size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
            } else {
                // Below 20 NM the distance gains a decimal, set in small type.
                let parts = String(format: "%.1f", distance).split(separator: ".")
                text(context, String(parts[0]), x: 696, y: 57,
                     size: ND.fontIntermediate, EFIS.green, anchor: .trailing)
                text(context, ".", x: 693, y: 57, size: ND.fontSmallest, EFIS.green)
                text(context, String(parts[1]), x: 710, y: 57,
                     size: ND.fontSmallest, EFIS.green)
            }
            text(context, "NM", x: 762, y: 57, size: ND.fontSmallest, EFIS.cyan,
                 anchor: .trailing)

            if let eta = utcArrival(afterNm: distance) {
                text(context, eta, x: 762, y: 91, size: ND.fontIntermediate, EFIS.green,
                     anchor: .trailing)
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

    /// Draw text the way the reference SVG positions it: `y` is the baseline
    /// and `anchor` the horizontal alignment.
    private func text(_ context: GraphicsContext, _ string: String,
                      x: CGFloat, y: CGFloat, size: CGFloat, _ color: Color,
                      anchor: UnitPoint = .leading) {
        context.digits(string, at: CGPoint(x: x, y: y - size * 0.36),
                       size: size, color, anchor: anchor)
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
        .frame(height: 480)
}
