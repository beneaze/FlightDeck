import SwiftUI

/// Layout of the A380-style Vertical Display strip, in our own units: the
/// strip is 1000 wide like the ND canvas, with a band for the range labels
/// across the top, the profile plot under it, and the altitude tape standing
/// a fixed distance left of the plot. Everything else is placed relative to
/// those.
enum VD {
    static let width: CGFloat = 1000
    /// Band above the plot that carries the distance labels.
    static let labelBand: CGFloat = 32
    static let plotHeight: CGFloat = 260
    static var height: CGFloat { labelBand + plotHeight }

    /// The plot leaves room on the left for the altitude tape and its
    /// labels, and a narrower margin on the right.
    static let plotLeft: CGFloat = 195
    static let plotRightMargin: CGFloat = 100
    static var plot: CGRect {
        CGRect(x: plotLeft, y: labelBand, width: width - plotLeft - plotRightMargin, height: plotHeight)
    }

    /// The altitude tape's spine stands this far left of the plot.
    static var altitudeTapeX: CGFloat { plotLeft - 58 }
    static let tapeDash: CGFloat = 20
    static let lineWidth: CGFloat = 2.6

    static let minAltitudeFt = -500.0
    static let maxAltitudeFt = 70_000.0

    /// The A380's VD frames a 4° slope: a path of that angle runs from one
    /// corner of the plot to the other at the selected range. This is the
    /// height of that window.
    static func fullExtentFt(rangeNm: Double) -> Double {
        rangeNm * 6_076.12 * tan(4 * .pi / 180)
    }

    /// Exaggeration applied to the flight path angle when tilting the
    /// aircraft symbol, so it lies along the path as drawn: a 4° path
    /// appears at the plot's diagonal angle.
    static var fpaToDisplayAngle: Double {
        atan(Double(plot.height / plot.width)) * 180 / .pi / 4
    }

    /// Altitude-tape dash spacing: the round step closest to an eighth of
    /// the window shown.
    static func dashStepFt(extentFt: Double) -> Double {
        let candidates: [Double] = [10, 20, 25, 50, 100, 200, 250, 500, 1_000, 2_000, 5_000, 10_000]
        let target = extentFt / 8
        return candidates.min { abs(log($0 / target)) < abs(log($1 / target)) } ?? 500
    }
}

/// Vertical Display — the profile strip beneath the ND on A350/A380 flight
/// decks: the aircraft against an altitude tape on the left, distance along
/// the bottom, and the planned path running out ahead of it.
///
/// Here the planned path is the road: the strip plots the ground elevation of
/// the planned route from the aircraft out to the selected range — the
/// climbs and descents ahead — as a ground silhouette with the route profile
/// along its top. An airliner draws its terrain from an on-board database;
/// this one gets the route's heights from a digital elevation model when the
/// route is planned (see ``RoutePlanner``).
struct VerticalDisplayView: View {
    var altitudeFt: Double
    var selectedAltitudeFt: Double
    var flightPathAngleDeg: Double
    var rangeNm: Double
    /// Ground elevation of the planned route ahead of the aircraft: distance
    /// out along the route, in NM, and the height there. Empty when no
    /// profile is available.
    var routeElevation: [(distanceNm: Double, elevationFt: Double)]
    /// Why the profile is missing while a route is active — "LOADING" or
    /// "NOT AVAIL" — or nil.
    var elevationStatus: String?
    var destinationName: String?
    var destinationDistanceNm: Double?
    /// Whose flight deck the strip belongs to: the A380 layout with its cyan
    /// labels and yellow aircraft, or the 737 VSD — altitude axis on the
    /// left, range axis along the bottom, a side-view airplane with its
    /// flight path running ahead over green terrain.
    var style: DisplayStyle = .airbus
    /// In flight: the window follows the aircraft at a height set by the
    /// range, as the airliner's VD does, and the ground ahead shows where it
    /// reaches into it (see `flightWindow`).
    var showsGround = false

    /// The annunciation when there is no profile: in flight it is the
    /// terrain from the flight pack that is missing, not a route profile.
    private func flagText(loading: Bool) -> String {
        if showsGround { return "TERRAIN NOT AVAIL" }
        return loading ? "ROUTE ELEV LOADING" : "ROUTE ELEV NOT AVAIL"
    }

    /// The altitude window and tape step. The A380 VD frames a 4° slope at
    /// the selected range; a road rarely climbs that steeply, so
    /// when the ground ahead is flatter the window tightens onto it — never
    /// closer than a quarter of the full window — and the aircraft is kept
    /// inside with a margin, taking priority over the path.
    private var verticalRange: (lowerFt: Double, upperFt: Double, stepFt: Double) {
        let full = VD.fullExtentFt(rangeNm: rangeNm)
        let heights = routeElevation.map(\.elevationFt)

        if showsGround { return flightWindow(full: full) }

        guard let low = heights.min(), let high = heights.max() else {
            // No path: the aircraft sits in the middle of the window.
            let lower = max(VD.minAltitudeFt, min(altitudeFt - 0.5 * full, VD.maxAltitudeFt - full))
            return (lower, lower + full, VD.dashStepFt(extentFt: full))
        }

        // The ground sits in the lower part of the window, sky above it.
        let extent = min(full, max(full / 4, (high - low) * 1.6))
        var lower = max(VD.minAltitudeFt, low - 0.15 * extent)
        if altitudeFt < lower + 0.05 * extent {
            lower = max(VD.minAltitudeFt, altitudeFt - 0.15 * extent)
        } else if altitudeFt > lower + 0.95 * extent {
            lower = min(VD.maxAltitudeFt, altitudeFt + 0.15 * extent) - extent
        }
        return (lower, lower + extent, VD.dashStepFt(extentFt: extent))
    }

    /// The window in flight, as the airliner's VD frames it: a fixed height
    /// for the range (the 4° slope), centred on the aircraft and moving
    /// with it. The ground shows only where it reaches into the window, so
    /// at cruise the window holds sky and the airplane, not a scale
    /// stretched down to sea level. Low down the window starts at the
    /// bottom of the scale.
    ///
    /// The scale never runs far beyond what the airliner can reach: its
    /// top stays within a little of the certified ceiling (A320 FL398,
    /// 737NG FL410), FL410 to FL450 depending on the range, the window
    /// shifting down instead and the aircraft riding above the middle at
    /// cruise. An aircraft actually higher than that is still kept in view.
    private func flightWindow(full: Double) -> (lowerFt: Double, upperFt: Double, stepFt: Double) {
        let ceilingFt = style == .boeing ? 41_000.0 : 39_800.0
        let topLimit = min(45_000, ceilingFt + max(1_000, 0.1 * full))
        let extent = min(max(full, 1_000), topLimit - VD.minAltitudeFt)

        var lower = max(VD.minAltitudeFt, altitudeFt - 0.5 * extent)
        lower = max(VD.minAltitudeFt, min(lower, topLimit - extent))
        // Keep the aircraft inside with a margin whatever the envelope says.
        if altitudeFt > lower + 0.9 * extent {
            lower = min(VD.maxAltitudeFt - extent, altitudeFt - 0.9 * extent)
        }
        return (lower, lower + extent, VD.dashStepFt(extentFt: extent))
    }

    var body: some View {
        switch style {
        case .airbus: airbusBody
        case .boeing: boeingBody
        }
    }

    // MARK: - Airbus

    private var airbusBody: some View {
        Canvas { context, size in
            let scale = min(size.width / VD.width, size.height / VD.height)
            var ctx = context
            ctx.translateBy(x: (size.width - VD.width * scale) / 2,
                            y: (size.height - VD.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)

            let range = verticalRange
            let plot = VD.plot

            func y(forFeet feet: Double) -> CGFloat {
                plot.minY + CGFloat((range.upperFt - feet) / (range.upperFt - range.lowerFt)) * plot.height
            }
            func x(forNm nm: Double) -> CGFloat {
                plot.minX + CGFloat(nm / rangeNm) * plot.width
            }

            drawAltitudeTape(ctx, range: range, y: y)
            drawRangeGrid(ctx)
            drawProfile(ctx, x: x, y: y)
            drawDestination(ctx, x: x)
            drawTargetAltitude(ctx, range: range, y: y)
            drawAircraft(ctx, y: y)
            drawFlags(ctx)
        }
        .background(EFIS.background)
    }

    // MARK: Altitude tape

    /// The tape's spine with a dash every step and a label every second dash
    /// — in hundreds of feet, as flight levels are printed, unless the step
    /// is too fine for that to be unambiguous.
    private func drawAltitudeTape(_ context: GraphicsContext,
                                  range: (lowerFt: Double, upperFt: Double, stepFt: Double),
                                  y: (Double) -> CGFloat) {
        let plot = VD.plot
        let tapeX = VD.altitudeTapeX
        var clipped = context
        clipped.clip(to: Path(CGRect(x: 0, y: plot.minY, width: plot.minX - 26, height: plot.height)))

        clipped.line(from: CGPoint(x: tapeX, y: plot.minY), to: CGPoint(x: tapeX, y: plot.maxY),
                     .white, width: VD.lineWidth)

        let flightLevels = range.stepFt >= 50
        var feet = max(0, (range.lowerFt / range.stepFt).rounded(.up) * range.stepFt)
        while feet <= range.upperFt {
            let ty = y(feet)
            clipped.line(from: CGPoint(x: tapeX, y: ty), to: CGPoint(x: tapeX + VD.tapeDash, y: ty),
                         .white, width: VD.lineWidth)
            if feet.truncatingRemainder(dividingBy: range.stepFt * 2) == 0 {
                let label = flightLevels ? "\(Int((feet / 100).rounded(.down)))" : "\(Int(feet))"
                text(clipped, label, x: tapeX - 13, y: ty, size: ND.fontSmallest, .white,
                     anchor: .trailing)
            }
            feet += range.stepFt
        }

        if flightLevels {
            text(context, "FL", x: 6, y: plot.midY, size: ND.fontSmallest, .white)
        }

        // The aircraft's altitude on the tape.
        let planeY = y(altitudeFt).clampedTo(plot.minY...plot.maxY)
        clipped.line(from: CGPoint(x: tapeX - 10, y: planeY), to: CGPoint(x: tapeX + 13, y: planeY),
                     EFIS.yellow, width: VD.lineWidth * 2)
    }

    // MARK: Distance grid

    /// The plot's top edge, quarter-range verticals (dashed inside, solid at
    /// the ends) and the cyan distance labels centred in the band above.
    private func drawRangeGrid(_ context: GraphicsContext) {
        let plot = VD.plot
        context.line(from: CGPoint(x: plot.minX, y: plot.minY), to: CGPoint(x: plot.maxX, y: plot.minY),
                     .white, width: VD.lineWidth)
        for quarter in 0...4 {
            let gx = plot.minX + plot.width * CGFloat(quarter) / 4
            var line = Path()
            line.move(to: CGPoint(x: gx, y: plot.minY))
            line.addLine(to: CGPoint(x: gx, y: plot.maxY))
            let solid = quarter == 0 || quarter == 4
            context.stroke(line, with: .color(.white),
                           style: StrokeStyle(lineWidth: VD.lineWidth, dash: solid ? [] : [10, 10]))
            text(context, rangeLabel(rangeNm * Double(quarter) / 4), x: gx, y: VD.labelBand / 2,
                 size: ND.fontSmallest, EFIS.cyan, anchor: .center)
        }
    }

    private func rangeLabel(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        var text = String(format: value < 1 ? "%.2f" : "%.1f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: Route profile

    /// The ground along the route, filled down to the bottom of the plot, with
    /// the route's own profile — the planned path — along its top in the
    /// display's green.
    private func drawProfile(_ context: GraphicsContext,
                             x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        guard routeElevation.count > 1 else { return }
        let plot = VD.plot
        var clipped = context
        clipped.clip(to: Path(plot))

        var profile = Path()
        for (index, point) in routeElevation.enumerated() {
            let p = CGPoint(x: x(point.distanceNm), y: y(point.elevationFt))
            index == 0 ? profile.move(to: p) : profile.addLine(to: p)
        }

        var ground = profile
        ground.addLine(to: CGPoint(x: x(routeElevation.last!.distanceNm), y: plot.maxY + 10))
        ground.addLine(to: CGPoint(x: x(routeElevation[0].distanceNm), y: plot.maxY + 10))
        ground.closeSubpath()
        clipped.fill(ground, with: .color(EFIS.ground.opacity(0.6)))

        clipped.stroke(profile, with: .color(EFIS.green),
                       style: StrokeStyle(lineWidth: VD.lineWidth, lineJoin: .round))
    }

    private func drawDestination(_ context: GraphicsContext, x: (Double) -> CGFloat) {
        guard let distance = destinationDistanceNm, distance <= rangeNm,
              let name = destinationName else { return }
        let plot = VD.plot
        let tx = x(distance)
        var clipped = context
        clipped.clip(to: Path(plot))
        clipped.line(from: CGPoint(x: tx, y: plot.minY), to: CGPoint(x: tx, y: plot.maxY),
                     EFIS.green.opacity(0.7), width: VD.lineWidth)
        let ident = name.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(7).description
        text(clipped, ident, x: tx - 8, y: plot.maxY - 20, size: ND.fontSmallest, EFIS.green,
             anchor: .trailing, shadow: true)
    }

    // MARK: Target altitude

    /// The FCU altitude: a cyan bracket on the tape while it is inside the
    /// window, its value printed above the tape when it is not — as the PFD
    /// altitude tape does with its bug.
    private func drawTargetAltitude(_ context: GraphicsContext,
                                    range: (lowerFt: Double, upperFt: Double, stepFt: Double),
                                    y: (Double) -> CGFloat) {
        if range.lowerFt...range.upperFt ~= selectedAltitudeFt {
            // A tall bracket straddling the tape, open on the left, with a
            // V notch in its right side pointing at the selected altitude.
            let cy = y(selectedAltitudeFt)
            let left = VD.altitudeTapeX - 7, right = left + 16
            let halfHeight: CGFloat = 24, notch: CGFloat = 8
            var bracket = Path()
            bracket.move(to: CGPoint(x: left, y: cy + halfHeight))
            bracket.addLine(to: CGPoint(x: left, y: cy - halfHeight))
            bracket.addLine(to: CGPoint(x: right, y: cy - halfHeight))
            bracket.addLine(to: CGPoint(x: right, y: cy - notch))
            bracket.addLine(to: CGPoint(x: right - notch, y: cy))
            bracket.addLine(to: CGPoint(x: right, y: cy + notch))
            bracket.addLine(to: CGPoint(x: right, y: cy + halfHeight))
            bracket.closeSubpath()
            context.stroke(bracket, with: .color(EFIS.cyan), lineWidth: VD.lineWidth)
        } else {
            text(context, "\(Int(selectedAltitudeFt))", x: VD.altitudeTapeX - 6, y: VD.labelBand / 2,
                 size: ND.fontSmall, EFIS.cyan, anchor: .trailing)
        }
    }

    // MARK: Aircraft

    /// The yellow aircraft symbol, seen from the side, nose just inside the
    /// plot's left edge at its altitude, tilted along the flight path angle.
    private func drawAircraft(_ context: GraphicsContext, y: (Double) -> CGFloat) {
        let plot = VD.plot
        let planeY = y(altitudeFt).clampedTo(plot.minY...plot.maxY)
        let length: CGFloat = 34, finHeight: CGFloat = 13, finChord: CGFloat = 15
        let nose = plot.minX + 16

        var ctx = context
        ctx.translateBy(x: nose - length / 2, y: planeY)
        ctx.rotate(by: .degrees(-flightPathAngleDeg * VD.fpaToDisplayAngle))

        var body = Path()
        body.move(to: CGPoint(x: -length / 2, y: 0))
        body.addLine(to: CGPoint(x: length / 2, y: 0))
        ctx.stroke(body, with: .color(EFIS.yellow),
                   style: StrokeStyle(lineWidth: VD.lineWidth * 2, lineCap: .round))

        // Fin: a right triangle standing on the tail end, its vertical edge
        // at the very back.
        var fin = Path()
        fin.move(to: CGPoint(x: -length / 2, y: 0))
        fin.addLine(to: CGPoint(x: -length / 2, y: -finHeight))
        fin.addLine(to: CGPoint(x: -length / 2 + finChord, y: 0))
        fin.closeSubpath()
        ctx.fill(fin, with: .color(EFIS.yellow))
        ctx.stroke(fin, with: .color(EFIS.yellow),
                   style: StrokeStyle(lineWidth: VD.lineWidth * 1.5, lineJoin: .round))
    }

    // MARK: Flags

    private func drawFlags(_ context: GraphicsContext) {
        guard routeElevation.isEmpty, let status = elevationStatus else { return }
        let loading = status == "LOADING"
        let plot = VD.plot
        text(context, flagText(loading: loading),
             x: plot.midX, y: plot.midY, size: ND.fontSmall, loading ? EFIS.green : EFIS.amber,
             anchor: .center, shadow: true)
    }

    /// Draw text with its vertical centre on `y` and `anchor` setting the
    /// horizontal alignment. `shadow` adds a dark under-print so the text
    /// stays legible over the profile.
    private func text(_ context: GraphicsContext, _ string: String,
                      x: CGFloat, y: CGFloat, size: CGFloat, _ color: Color,
                      anchor: UnitPoint = .leading, shadow: Bool = false) {
        let point = CGPoint(x: x, y: y)
        if shadow {
            for dx in [-2.0, 2.0] {
                for dy in [-2.0, 2.0] {
                    context.digits(string, at: CGPoint(x: point.x + dx, y: point.y + dy),
                                   size: size, EFIS.background, anchor: anchor)
                }
            }
        }
        context.digits(string, at: point, size: size, color, anchor: anchor)
    }

    // MARK: - Boeing

    /// The 737 Vertical Situation Display: a grey band down the left carries
    /// the altitude scale with the MCP altitude in magenta at its top; the
    /// plot beside it has the range axis along its bottom, the airplane as a
    /// hollow triangle whose apex marks its position and altitude, the flight
    /// path vector running ahead from the apex, terrain filled green, amber
    /// and red by its height relative to the airplane, the MCP altitude as a
    /// dashed magenta line, and waypoints as dashed verticals with their
    /// idents along the top.
    private var boeingBody: some View {
        Canvas { context, size in
            let scale = min(size.width / B737VSD.width, size.height / B737VSD.height)
            var ctx = context
            ctx.translateBy(x: (size.width - B737VSD.width * scale) / 2,
                            y: (size.height - B737VSD.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)

            let range = verticalRange
            let plot = B737VSD.plot
            func y(_ feet: Double) -> CGFloat {
                plot.minY + CGFloat((range.upperFt - feet) / (range.upperFt - range.lowerFt)) * plot.height
            }
            func x(_ nm: Double) -> CGFloat {
                plot.minX + B737VSD.originOffset
                    + CGFloat(nm / rangeNm) * (plot.width - B737VSD.originOffset - B737VSD.rightMargin)
            }

            ctx.fill(Path(B737VSD.band), with: .color(Boeing.grey))
            ctx.fill(Path(B737VSD.bottomBand), with: .color(Boeing.grey))
            boeingTerrain(ctx, x: x, y: y)
            boeingAxes(ctx, range: range, x: x, y: y)
            boeingDestination(ctx, x: x, y: y)
            boeingTargetAltitude(ctx, range: range, y: y)
            boeingAircraft(ctx, x: x, y: y)
            boeingFlags(ctx)
        }
        .background(Boeing.background)
    }

    /// Altitude scale on the band: a tick every step at the band's edge, the
    /// value every second one. Range axis along the plot's bottom: a tick
    /// every eighth of the range, the distance at every quarter.
    private func boeingAxes(_ context: GraphicsContext,
                            range: (lowerFt: Double, upperFt: Double, stepFt: Double),
                            x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        let plot = B737VSD.plot
        var feet = (range.lowerFt / range.stepFt).rounded(.up) * range.stepFt
        while feet <= range.upperFt {
            let ty = y(feet)
            let labelled = feet.truncatingRemainder(dividingBy: range.stepFt * 2) == 0
            context.line(from: CGPoint(x: plot.minX - (labelled ? B737VSD.majorTick : B737VSD.minorTick), y: ty),
                         to: CGPoint(x: plot.minX, y: ty), Boeing.white, width: B737VSD.line)
            // Values on the band, thousands set off from the hundreds
            // ("4 000"); none hard against the top, where the MCP altitude
            // sits.
            if labelled, ty >= plot.minY + B737VSD.line * 2.5 {
                context.boeingText(boeingAltitudeLabel(feet), at: CGPoint(x: B737VSD.altitudeLabelX, y: ty),
                                   size: B737VSD.altitudeFont, anchor: .trailing)
            }
            feet += range.stepFt
        }

        // Range axis along the plot's bottom edge: a tick every eighth, the
        // distance at every quarter on the strip beneath.
        for eighth in 0...8 {
            let nm = rangeNm * Double(eighth) / 8
            let gx = x(nm)
            context.line(from: CGPoint(x: gx, y: plot.maxY), to: CGPoint(x: gx, y: plot.maxY - B737VSD.rangeTick),
                         Boeing.white, width: B737VSD.line)
            if eighth % 2 == 0 {
                context.boeingText(boeingRangeLabel(nm), at: CGPoint(x: gx, y: B737VSD.bottomBand.midY),
                                   size: B737VSD.font)
            }
        }
    }

    /// Distances read with one decimal ("5.0", "10.0"); two at street-scale
    /// ranges where one would not tell them apart.
    private func boeingRangeLabel(_ value: Double) -> String {
        String(format: rangeNm < 1 ? "%.2f" : "%.1f", value)
    }

    /// Altitudes with the thousands set off: "4 000", "12 000"; plain below
    /// a thousand.
    private func boeingAltitudeLabel(_ feet: Double) -> String {
        let value = Int(feet.rounded())
        guard abs(value) >= 1_000 else { return "\(value)" }
        return "\(value / 1_000) " + String(format: "%03d", abs(value) % 1_000)
    }

    /// The ground along the route, filled in horizontal colour bands by its
    /// height relative to the vehicle and clipped to the terrain silhouette.
    private func boeingTerrain(_ context: GraphicsContext,
                               x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        guard routeElevation.count > 1 else { return }
        let plot = B737VSD.plot
        // The ground runs back under the airplane to the band's edge at the
        // height it has here.
        var ground = Path()
        ground.move(to: CGPoint(x: plot.minX, y: y(routeElevation[0].elevationFt)))
        for point in routeElevation {
            ground.addLine(to: CGPoint(x: x(point.distanceNm), y: y(point.elevationFt)))
        }
        let below = plot.maxY + 25
        ground.addLine(to: CGPoint(x: x(routeElevation.last!.distanceNm), y: below))
        ground.addLine(to: CGPoint(x: plot.minX, y: below))
        ground.closeSubpath()

        var clipped = context
        clipped.clip(to: Path(plot))
        clipped.clip(to: ground)
        let amberFrom = y(altitudeFt + B737VSD.amberAboveFt)
        let redFrom = y(altitudeFt + B737VSD.redAboveFt)
        clipped.fill(Path(CGRect(x: plot.minX, y: amberFrom, width: plot.width, height: below - amberFrom)),
                     with: .color(B737VSD.terrainGreen))
        clipped.fill(Path(CGRect(x: plot.minX, y: redFrom, width: plot.width, height: amberFrom - redFrom)),
                     with: .color(B737VSD.terrainAmber))
        clipped.fill(Path(CGRect(x: plot.minX, y: plot.minY - 25, width: plot.width, height: redFrom - plot.minY + 25)),
                     with: .color(B737VSD.terrainRed))
    }

    /// The destination as a waypoint: a dashed vertical through the plot at
    /// its distance, its ident along the top, a star where it meets the ground.
    private func boeingDestination(_ context: GraphicsContext,
                                   x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        guard let distance = destinationDistanceNm, distance <= rangeNm,
              let name = destinationName else { return }
        let plot = B737VSD.plot
        let tx = x(distance)
        var line = Path()
        line.move(to: CGPoint(x: tx, y: plot.minY))
        line.addLine(to: CGPoint(x: tx, y: plot.maxY))
        context.stroke(line, with: .color(Boeing.white),
                       style: StrokeStyle(lineWidth: B737VSD.thinLine, dash: [B737VSD.dash, B737VSD.dash]))

        // Ident over the top of the plot, kept clear of its ends.
        let ident = name.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(7).description
        let inset = B737VSD.font * 1.5
        context.boeingText(ident, at: CGPoint(x: min(max(tx, plot.minX + inset), plot.maxX - inset),
                                              y: plot.minY - B737VSD.font * 0.67),
                           size: B737VSD.font)

        if let elevation = routeElevation.min(by: { abs($0.distanceNm - distance) < abs($1.distanceNm - distance) })?.elevationFt {
            let r = B737VSD.starRadius
            let p = CGPoint(x: tx, y: y(elevation).clampedTo(plot.minY + r * 0.67...plot.maxY - r * 0.67))
            let star = (0..<8).map { i in polarPoint(p, Double(i) * 45, i % 2 == 0 ? r : r / 3) }
            context.polygon(star, fill: Boeing.white)
        }
    }

    /// The MCP altitude: its value in magenta on the black patch above the
    /// band — thousands large, hundreds small — and, while it is inside the
    /// window, the Boeing altitude bracket on the scale with a dashed line
    /// across the plot.
    private func boeingTargetAltitude(_ context: GraphicsContext,
                                      range: (lowerFt: Double, upperFt: Double, stepFt: Double),
                                      y: (Double) -> CGFloat) {
        let plot = B737VSD.plot
        let selected = Int(selectedAltitudeFt.rounded())
        // Right-aligned near the band's edge, centred in the black patch:
        // hundreds small, thousands large and baseline-ish level with them.
        let right = B737VSD.band.maxX - 15
        let midY = B737VSD.topPatch / 2
        let small = B737VSD.font * 0.83, large = B737VSD.font * 1.25
        let hundreds = String(format: "%03d", abs(selected) % 1_000)
        let hundredsWidth = context.boeingTextWidth(hundreds, size: small)
        context.boeingText(hundreds, at: CGPoint(x: right, y: midY + small * 0.12), size: small,
                           Boeing.magenta, anchor: .trailing)
        if abs(selected) >= 1_000 {
            context.boeingText("\(selected / 1_000)", at: CGPoint(x: right - hundredsWidth - 2, y: midY),
                               size: large, Boeing.magenta, anchor: .trailing)
        }

        guard range.lowerFt...range.upperFt ~= selectedAltitudeFt else { return }
        let ty = y(selectedAltitudeFt)
        // The altitude bracket: a box on the scale, open into a small V on its
        // outboard side pointing at the altitude.
        let w = B737VSD.bracketWidth, h = B737VSD.bracketHalfHeight
        let notch = B737VSD.bracketNotchDepth
        let bx = plot.minX - w - B737VSD.line / 2
        context.polygon([
            CGPoint(x: bx, y: ty - h), CGPoint(x: bx + w, y: ty - h), CGPoint(x: bx + w, y: ty + h),
            CGPoint(x: bx, y: ty + h), CGPoint(x: bx, y: ty + notch * 0.67), CGPoint(x: bx + notch, y: ty),
            CGPoint(x: bx, y: ty - notch * 0.67),
        ], stroke: Boeing.magenta, lineWidth: B737VSD.line)
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: ty))
        line.addLine(to: CGPoint(x: plot.maxX, y: ty))
        context.stroke(line, with: .color(Boeing.magenta),
                       style: StrokeStyle(lineWidth: B737VSD.line, dash: [B737VSD.dash * 1.25, B737VSD.dash]))
    }

    /// The airplane: a hollow right-angled triangle lying between the band's
    /// edge and the 0 NM point, its apex there marking position and altitude,
    /// with the flight path vector running ahead from the apex to a quarter
    /// of the range.
    private func boeingAircraft(_ context: GraphicsContext,
                                x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        let plot = B737VSD.plot
        let h = B737VSD.airplaneHeight
        let ay = y(altitudeFt).clampedTo(plot.minY + h + B737VSD.line...plot.maxY - B737VSD.line / 2)
        let apex = CGPoint(x: x(0), y: ay)
        let back = plot.minX + B737VSD.line
        context.polygon([apex, CGPoint(x: back, y: ay), CGPoint(x: back, y: ay - h)],
                        stroke: Boeing.white, lineWidth: B737VSD.line)

        var clipped = context
        clipped.clip(to: Path(plot))
        let ahead = rangeNm / 4
        let endFeet = altitudeFt + tan(flightPathAngleDeg * .pi / 180) * ahead * 6_076.12
        clipped.line(from: apex, to: CGPoint(x: x(ahead), y: ay + (y(endFeet) - y(altitudeFt))),
                     Boeing.white, width: B737VSD.line)
    }

    private func boeingFlags(_ context: GraphicsContext) {
        guard routeElevation.isEmpty, let status = elevationStatus else { return }
        let plot = B737VSD.plot
        let loading = status == "LOADING"
        context.boeingText(flagText(loading: loading),
                           at: CGPoint(x: plot.midX, y: plot.midY), size: B737VSD.font,
                           loading ? Boeing.green : Boeing.amber)
    }
}

extension CGFloat {
    func clampedTo(_ range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

#Preview("A380") {
    VerticalDisplayView(altitudeFt: 1_250, selectedAltitudeFt: 2_000, flightPathAngleDeg: 1.5,
                        rangeNm: 10,
                        routeElevation: stride(from: 0.0, through: 10, by: 0.25).map {
                            (distanceNm: $0, elevationFt: 1_200 + 400 * sin($0 / 2) + 30 * $0)
                        },
                        elevationStatus: nil,
                        destinationName: "BOSTON", destinationDistanceNm: 8.2)
        .frame(width: 393, height: 104)
        .background(.black)
}

#Preview("737") {
    VerticalDisplayView(altitudeFt: 1_250, selectedAltitudeFt: 2_000, flightPathAngleDeg: 1.5,
                        rangeNm: 10,
                        routeElevation: stride(from: 0.0, through: 10, by: 0.25).map {
                            (distanceNm: $0, elevationFt: 1_200 + 400 * sin($0 / 2) + 130 * $0)
                        },
                        elevationStatus: nil,
                        destinationName: "BOSTON", destinationDistanceNm: 8.2,
                        style: .boeing)
        .frame(width: 393, height: 104)
        .background(.black)
}

/// Layout of the 737-style Vertical Situation Display strip under the ND,
/// in its own units (1000 × 210): a grey band down the left carrying the
/// altitude scale, a black patch above it for the MCP altitude, a black plot
/// with the range axis on a grey strip along its bottom, and the airplane's
/// apex a little in from the plot's left edge.
enum B737VSD {
    static let width: CGFloat = 1000
    static let height: CGFloat = 210

    /// Black patch at the top left that carries the MCP altitude.
    static let topPatch: CGFloat = 35
    static let bandWidth: CGFloat = 175
    static let bottomStripHeight: CGFloat = 40
    /// The plot starts a little below the band's top and ends this far
    /// short of the right edge.
    static let plotTopInset: CGFloat = 7.5
    static let plotRightMargin: CGFloat = 40

    /// The grey underlay is L-shaped: a band down the left for the altitude
    /// scale and a strip along the bottom for the distances.
    static var band: CGRect { CGRect(x: 0, y: topPatch, width: bandWidth, height: height - topPatch) }
    static var bottomBand: CGRect {
        CGRect(x: 0, y: height - bottomStripHeight, width: width, height: bottomStripHeight)
    }
    static var plot: CGRect {
        let top = topPatch + plotTopInset
        return CGRect(x: bandWidth, y: top, width: width - bandWidth - plotRightMargin,
                      height: bottomBand.minY - top)
    }
    /// Right edge of the altitude labels on the band, clear of the ticks.
    static var altitudeLabelX: CGFloat { bandWidth - 55 }
    /// The range scale does not start at the plot's edge: the 0 NM point —
    /// the airplane's apex — sits this far in, with the triangle behind it,
    /// and the scale ends short of the right edge.
    static let originOffset: CGFloat = 55
    static let rightMargin: CGFloat = 20

    static let line: CGFloat = 3.75
    static let thinLine: CGFloat = 3
    static let dash: CGFloat = 10
    static let majorTick: CGFloat = 22
    static let minorTick: CGFloat = 12
    static let rangeTick: CGFloat = 10
    static let starRadius: CGFloat = 15
    static let bracketWidth: CGFloat = 25
    static let bracketHalfHeight: CGFloat = 17.5
    static let bracketNotchDepth: CGFloat = 7.5
    static let airplaneHeight: CGFloat = 20

    static let font: CGFloat = 30
    static let altitudeFont: CGFloat = 27.5

    // Terrain is coloured in bands by its height relative to the aircraft.
    // The 737 paints terrain from 500 ft below to 2000 ft above the airplane
    // amber and higher terrain red; a car drives *on* its terrain, so here the
    // road ahead is green up to 500 ft above the vehicle, amber to 2000 ft
    // above and red beyond — the same bands, hung from the road instead of
    // from a flight path above it.
    static let terrainGreen = Color(red: 110 / 255, green: 230 / 255, blue: 80 / 255)
    static let terrainAmber = Color(red: 240 / 255, green: 200 / 255, blue: 60 / 255)
    static let terrainRed   = Color(red: 230 / 255, green: 70 / 255, blue: 40 / 255)
    static let amberAboveFt = 500.0
    static let redAboveFt = 2_000.0
}
