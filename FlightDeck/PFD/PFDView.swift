import SwiftUI

/// A320-style Primary Flight Display.
///
/// The whole instrument is drawn into one 100-unit canvas (see ``PFD``), then
/// scaled to fit, so every element keeps its place relative to the others.
/// Sizes not owned by the layout spec — stroke widths, symbol sizes, type —
/// are the ``Style`` constants below, in the same units.
struct PFDView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @EnvironmentObject private var speedLimits: SpeedLimitProvider
    @EnvironmentObject private var packs: FlightPackStore

    /// Terrain elevation under the aircraft, from the active flight pack —
    /// plane mode only; on the road the vehicle is on the ground anyway.
    private var groundElevationFt: Double? {
        guard routePlanner.transportMode == .plane, let location = flightData.location else { return nil }
        return packs.activeTerrain?.elevationFt(at: location.coordinate)
    }

    var profile: AircraftProfile = .a320

    /// Stroke widths and type sizes, in canvas units.
    private enum Style {
        static let hairline: CGFloat = 0.22
        static let thin: CGFloat = 0.35
        static let medium: CGFloat = 0.44
        static let heavy: CGFloat = 0.69
        static let scaleType: CGFloat = 3.5
        static let speedType: CGFloat = 3.9
        static let readoutType: CGFloat = 5.0
        static let vsType: CGFloat = 2.9
        static let annunciationType: CGFloat = 4.0
        static let fmaType: CGFloat = 3.3
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / PFD.canvas
            var ctx = context
            ctx.translateBy(x: (size.width - PFD.canvas * scale) / 2,
                            y: (size.height - PFD.canvas * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)

            drawHorizon(ctx)
            drawAircraftReference(ctx)
            drawDeviationScales(ctx)
            drawBankScale(ctx)
            drawSpeedTape(ctx)
            drawAltitudeTape(ctx)
            drawVerticalSpeed(ctx)
            drawHeadingTape(ctx)
            drawOfftapeReadouts(ctx)
            drawFMA(ctx)
        }
        .background(EFIS.background)
    }

    // MARK: - Attitude

    private func drawHorizon(_ context: GraphicsContext) {
        var ctx = context
        ctx.clip(to: PFD.attitudeWindow)

        let center = PFD.horizonCenter
        var sphere = ctx
        sphere.translateBy(x: center.x, y: center.y)
        sphere.rotate(by: .degrees(-flightData.rollDeg))
        sphere.translateBy(x: 0, y: PFD.horizonOffset(pitch: flightData.pitchDeg))

        let ext: CGFloat = 400
        sphere.fill(Path(CGRect(x: -ext, y: -ext, width: 2 * ext, height: ext)),
                    with: .color(EFIS.sky))
        sphere.fill(Path(CGRect(x: -ext, y: 0, width: 2 * ext, height: ext)),
                    with: .color(EFIS.ground))
        sphere.line(from: CGPoint(x: -ext, y: 0), to: CGPoint(x: ext, y: 0), .white, width: Style.medium)

        // Pitch ladder. Each rung sits at its own angle's horizon offset, so the
        // rungs compress at high attitudes exactly as the horizon does.
        for rung in PFD.pitchLadder {
            let y = -PFD.horizonOffset(pitch: rung.deg)
            sphere.line(from: CGPoint(x: -rung.halfWidth, y: y),
                        to: CGPoint(x: rung.halfWidth, y: y), .white, width: Style.thin)
            if rung.labelled {
                let text = "\(abs(Int(rung.deg)))"
                let gap: CGFloat = 3.8
                sphere.digits(text, at: CGPoint(x: -rung.halfWidth - gap, y: y), size: Style.scaleType, .white)
                sphere.digits(text, at: CGPoint(x: rung.halfWidth + gap, y: y), size: Style.scaleType, .white)
            }
        }

        drawFlightDirector(ctx)
    }

    /// Flight director cross bars — green, centred on the commanded attitude.
    /// With no autopilot to follow, they command the flight path back to the
    /// selected altitude and the direct-to course.
    private func drawFlightDirector(_ context: GraphicsContext) {
        guard autoFlight.flightDirector else { return }
        let center = PFD.horizonCenter
        let barY = center.y - PFD.horizonOffset(pitch: guidance.pitchCommandDeg)
        let rollCommand = courseError.clamped(to: -20...20)
        let barX = center.x + CGFloat(rollCommand) * 0.57
        // Each bar reaches a little under half-way to the window's sides.
        let half = PFD.windowHalfWidth * 0.46

        context.line(from: CGPoint(x: center.x - half, y: barY),
                     to: CGPoint(x: center.x + half, y: barY), EFIS.green, width: 0.57)
        context.line(from: CGPoint(x: barX, y: center.y - half),
                     to: CGPoint(x: barX, y: center.y + half), EFIS.green, width: 0.57)
    }

    /// The fixed yellow aircraft reference: an L-shaped bracket either side —
    /// a horizontal bar with a short leg dropping from its inboard end — and
    /// a small square on the horizon centre.
    private func drawAircraftReference(_ context: GraphicsContext) {
        let c = PFD.horizonCenter
        let outer: CGFloat = 21.9          // wing tip, from the centre
        let inner: CGFloat = 12.4          // inboard end of the bar
        let bar: CGFloat = 1.6             // thickness of bar and leg
        let top = c.y - 0.8
        let legBottom = c.y + 3.3

        for side: CGFloat in [-1, 1] {
            func p(_ dx: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + side * dx, y: y) }
            var bracket = Path()
            bracket.move(to: p(outer, top))
            bracket.addLine(to: p(inner, top))
            bracket.addLine(to: p(inner, legBottom))
            bracket.addLine(to: p(inner + bar, legBottom))
            bracket.addLine(to: p(inner + bar, top + bar))
            bracket.addLine(to: p(outer, top + bar))
            bracket.closeSubpath()
            context.fill(bracket, with: .color(EFIS.background))
            context.stroke(bracket, with: .color(EFIS.yellow), lineWidth: Style.thin)
        }

        let side: CGFloat = 1.9
        let square = Path(CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side))
        context.fill(square, with: .color(EFIS.background))
        context.stroke(square, with: .color(EFIS.yellow), lineWidth: Style.thin)
    }

    // MARK: - Bank scale

    private func drawBankScale(_ context: GraphicsContext) {
        let center = PFD.horizonCenter
        let radius = PFD.bankScaleRadius

        func point(_ angleDeg: Double, _ r: CGFloat) -> CGPoint {
            let a = angleDeg * .pi / 180
            return CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))
        }

        // Arc spanning ±31°, just past the 30° marks.
        var arc = Path()
        for step in stride(from: -31.0, through: 31.0, by: 1.0) {
            let p = point(step, radius)
            step == -31 ? arc.move(to: p) : arc.addLine(to: p)
        }
        context.stroke(arc, with: .color(.white), lineWidth: Style.thin)

        // 10/20/30 are small hollow rectangles standing on the arc; 45 is a
        // plain radial tick beyond the end of the arc.
        let markLength: CGFloat = 1.8, markHalfWidth: CGFloat = 0.55
        for angle in [-30.0, -20, -10, 10, 20, 30] {
            let inner = point(angle, radius), outer = point(angle, radius + markLength)
            let a = angle * .pi / 180
            let across = CGPoint(x: cos(a) * markHalfWidth, y: sin(a) * markHalfWidth)
            var mark = Path()
            mark.move(to: CGPoint(x: inner.x - across.x, y: inner.y - across.y))
            mark.addLine(to: CGPoint(x: outer.x - across.x, y: outer.y - across.y))
            mark.addLine(to: CGPoint(x: outer.x + across.x, y: outer.y + across.y))
            mark.addLine(to: CGPoint(x: inner.x + across.x, y: inner.y + across.y))
            mark.closeSubpath()
            context.stroke(mark, with: .color(.white), lineWidth: 0.3)
        }
        for angle in [-45.0, 45] {
            context.line(from: point(angle, radius - 0.1), to: point(angle, radius + 2.6),
                         .white, width: Style.thin)
        }

        // Fixed zero index: a triangle standing on the arc, pointing down.
        context.stroke(triangle(apex: point(0, radius), baseY: center.y - radius - 2.3, halfWidth: 1.6),
                       with: .color(EFIS.yellow), lineWidth: Style.thin)

        // Roll pointer and sideslip target, rotating with the horizon.
        var rolled = context
        rolled.translateBy(x: center.x, y: center.y)
        rolled.rotate(by: .degrees(-flightData.rollDeg))
        rolled.translateBy(x: -center.x, y: -center.y)

        // Pointer just inside the arc, pointing up at the scale.
        rolled.stroke(triangle(apex: point(0, radius - 0.7), baseY: center.y - radius + 3.4, halfWidth: 1.8),
                      with: .color(EFIS.yellow), lineWidth: Style.thin)

        // No yaw sensor on a phone, so the slip target stays centred under the
        // pointer, as it is in coordinated flight: a trapezoid, wider on top.
        let slipTop = center.y - radius + 3.75, slipBottom = center.y - radius + 5.1
        var slip = Path()
        slip.move(to: CGPoint(x: center.x - 1.6, y: slipTop))
        slip.addLine(to: CGPoint(x: center.x + 1.6, y: slipTop))
        slip.addLine(to: CGPoint(x: center.x + 1.23, y: slipBottom))
        slip.addLine(to: CGPoint(x: center.x - 1.23, y: slipBottom))
        slip.closeSubpath()
        rolled.stroke(slip, with: .color(EFIS.yellow), lineWidth: Style.thin)
    }

    /// An isosceles triangle with its apex at `apex` and a horizontal base at
    /// `baseY`.
    private func triangle(apex: CGPoint, baseY: CGFloat, halfWidth: CGFloat) -> Path {
        var p = Path()
        p.move(to: apex)
        p.addLine(to: CGPoint(x: apex.x - halfWidth, y: baseY))
        p.addLine(to: CGPoint(x: apex.x + halfWidth, y: baseY))
        p.closeSubpath()
        return p
    }

    // MARK: - Speed tape

    private func drawSpeedTape(_ context: GraphicsContext) {
        let tape = PFD.speedTape
        let centerY = PFD.horizonCenter.y
        // The whole tape works in the crew-selected display unit; the model
        // stays in knots underneath.
        let unit = flightData.speedUnit.perKnot
        let speed = flightData.groundSpeedKts * unit

        context.fill(Path(tape), with: .color(EFIS.tape))

        func y(for value: Double) -> CGFloat { centerY - CGFloat(value - speed) * PFD.speedScale }

        var clipped = context
        clipped.clip(to: Path(tape.insetBy(dx: -PFD.speedStripWidth, dy: 0)))

        var value = ((speed - 45) / 10).rounded(.down) * 10
        while value <= speed + 45 {
            if value >= 30 {
                let ty = y(for: value)
                let labelled = value.truncatingRemainder(dividingBy: 20) == 0
                clipped.line(from: CGPoint(x: tape.maxX - (labelled ? 2.3 : 1.4), y: ty),
                             to: CGPoint(x: tape.maxX, y: ty), .white, width: Style.thin)
                if labelled {
                    clipped.digits("\(Int(value))", at: CGPoint(x: tape.maxX - 3.15, y: ty),
                                   size: Style.speedType, .white, anchor: .trailing)
                }
            }
            value += 10
        }

        // VMAX barber pole. On the road the posted speed limit is VMAX; with
        // no limit known the aircraft's VMO stands in, off the top of the
        // tape at any speed a car reaches. Past VMAX the pole is pinned, so
        // the tape stays striped.
        // In plane mode the tape shows ground speed, not airspeed, so a
        // maximum airspeed has nothing to mark and no pole is drawn.
        if routePlanner.transportMode.isRoad {
            let vmaxKts = speedLimits.limitKts ?? profile.vmo
            drawBarberPole(clipped, PFD.vmaxPole,
                           anchorY: min(y(for: vmaxKts * unit), centerY + PFD.vmaxPoleMaxOffset),
                           endY: tape.minY - 1.3, visible: tape.minY...tape.maxY, color: EFIS.red)
        }

        // The airliner's low-speed protections — the amber VLS bar and the
        // alpha-protection pole — are not drawn: they belong to a wing, and a
        // car has no minimum speed.

        // Speed trend arrow — where the speed will be in 10 seconds.
        if flightData.isSpeedTrendShown {
            drawTrendArrow(clipped, trend: flightData.speedTrendKts * unit, centerY: centerY)
        }

        // Selected speed: a cyan triangle on the tape's edge, or the value
        // in cyan above or below the tape when it is off the scale.
        if let selected = autoFlight.selectedSpeedKts.map({ $0 * unit }) {
            let sy = y(for: selected)
            if sy < tape.minY {
                context.digits("\(Int(selected.rounded()))", at: CGPoint(x: tape.midX, y: tape.minY - 2.0),
                               size: Style.speedType, EFIS.cyan)
            } else if sy > tape.maxY {
                context.digits("\(Int(selected.rounded()))", at: CGPoint(x: tape.midX, y: tape.maxY + 2.0),
                               size: Style.speedType, EFIS.cyan)
            } else {
                var bug = Path()
                bug.move(to: CGPoint(x: tape.maxX - 0.3, y: sy))
                bug.addLine(to: CGPoint(x: tape.maxX + 2.0, y: sy - 1.2))
                bug.addLine(to: CGPoint(x: tape.maxX + 2.0, y: sy + 1.2))
                bug.closeSubpath()
                context.fill(bug, with: .color(EFIS.cyan))
            }
        }

        // Fixed yellow airspeed reference: a thin bar riding into the tape,
        // flaring into an arrowhead just outboard of it, plus a short stub at
        // the tape's inboard edge.
        let barHalf: CGFloat = 0.23, headHalf: CGFloat = 0.95
        let barStart = tape.maxX - 3.2, flare = tape.maxX + 0.9, tip = tape.maxX + 2.9
        var pointer = Path()
        pointer.move(to: CGPoint(x: barStart, y: centerY - barHalf))
        pointer.addLine(to: CGPoint(x: barStart, y: centerY + barHalf))
        pointer.addLine(to: CGPoint(x: flare, y: centerY + barHalf))
        pointer.addLine(to: CGPoint(x: tip, y: centerY + headHalf))
        pointer.addLine(to: CGPoint(x: tip, y: centerY - headHalf))
        pointer.addLine(to: CGPoint(x: flare, y: centerY - barHalf))
        pointer.closeSubpath()
        pointer.addRect(CGRect(x: 0.06, y: centerY - barHalf, width: tape.minX + 0.07, height: 2 * barHalf))

        context.fill(pointer, with: .color(EFIS.yellow))
        context.stroke(pointer, with: .color(EFIS.background), lineWidth: 0.16)
    }

    /// A barber pole: filled blocks at the pole's pitch, the first block's
    /// edge on `anchorY` and the column running toward `endY`. A hairline
    /// along the outboard edge joins the blocks. Blocks that cannot reach the `visible` span are
    /// skipped rather than drawn and clipped: an off-scale limit would
    /// otherwise mean hundreds of them.
    private func drawBarberPole(_ context: GraphicsContext, _ pole: PFD.BarberPole,
                                anchorY: CGFloat, endY: CGFloat,
                                visible: ClosedRange<CGFloat>, color: Color) {
        guard anchorY != endY else { return }
        let up = endY < anchorY
        let step = up ? -pole.pitch : pole.pitch

        var edge = anchorY
        let overshoot = up ? anchorY - visible.upperBound : visible.lowerBound - anchorY
        if overshoot > 0 {
            edge += step * (overshoot / pole.pitch).rounded(.down)
        }

        while up ? edge > endY : edge < endY {
            let block = CGRect(x: pole.x, y: up ? edge - pole.blockHeight : edge,
                               width: pole.width, height: pole.blockHeight)
            context.fill(Path(block), with: .color(color))
            edge += step
        }
        context.line(from: CGPoint(x: pole.x + pole.width, y: anchorY),
                     to: CGPoint(x: pole.x + pole.width, y: endY), color, width: 0.07)
    }

    /// Yellow trend arrow riding the tape: a line from the current speed to
    /// where it will be in 10 seconds, tipped with an open chevron. `trend`
    /// is in the tape's display unit.
    private func drawTrendArrow(_ context: GraphicsContext, trend: Double, centerY: CGFloat) {
        let x = PFD.speedTape.maxX - 2.3
        let tip = centerY - CGFloat(trend) * PFD.speedScale
        let back: CGFloat = trend > 0 ? 1.55 : -1.55
        let half: CGFloat = 0.79

        var arrow = Path()
        arrow.move(to: CGPoint(x: x, y: centerY))
        arrow.addLine(to: CGPoint(x: x, y: tip))
        arrow.move(to: CGPoint(x: x - half, y: tip + back))
        arrow.addLine(to: CGPoint(x: x, y: tip))
        arrow.addLine(to: CGPoint(x: x + half, y: tip + back))
        context.stroke(arrow, with: .color(EFIS.yellow), lineWidth: Style.medium)
    }

    // MARK: - Altitude tape

    private func drawAltitudeTape(_ context: GraphicsContext) {
        let tape = PFD.altTape
        let centerY = PFD.horizonCenter.y
        let altitude = flightData.altitudeFt

        context.fill(Path(tape), with: .color(EFIS.tape))

        func y(for feet: Double) -> CGFloat { centerY - CGFloat(feet - altitude) * PFD.altScale }

        var clipped = context
        clipped.clip(to: Path(tape))

        let visible = Double(tape.height / PFD.altScale) / 2
        var value = ((altitude - visible) / 100).rounded(.down) * 100
        while value <= altitude + visible {
            let ty = y(for: value)
            let labelled = value.truncatingRemainder(dividingBy: 500) == 0
            clipped.line(from: CGPoint(x: tape.minX, y: ty),
                         to: CGPoint(x: tape.minX + (labelled ? 1.64 : 1.0), y: ty),
                         .white, width: Style.thin)
            if labelled {
                clipped.digits(String(format: "%03d", Int(value / 100)),
                               at: CGPoint(x: tape.minX + 2.0, y: ty),
                               size: Style.scaleType, .white, anchor: .leading)
            }
            value += 100
        }

        // Cyan FCU altitude bug.
        let bugY = y(for: flightData.selectedAltitudeFt)
        if tape.minY...tape.maxY ~= bugY {
            var bug = Path()
            bug.move(to: CGPoint(x: tape.minX, y: bugY - 1.5))
            bug.addLine(to: CGPoint(x: tape.minX + 2.0, y: bugY - 1.5))
            bug.addLine(to: CGPoint(x: tape.minX + 2.0, y: bugY + 1.5))
            bug.addLine(to: CGPoint(x: tape.minX, y: bugY + 1.5))
            clipped.stroke(bug, with: .color(EFIS.cyan), lineWidth: 0.5)
        }

        // The ground: a red ribbon outboard of the tape, from the terrain
        // elevation down to the tape's foot. Drawn before the readout, so the
        // drum box sits on top of it.
        if let ground = groundElevationFt {
            let ribbon = PFD.groundRibbon
            let top = max(y(for: ground), ribbon.minY)
            if top < ribbon.maxY {
                context.fill(Path(CGRect(x: ribbon.minX, y: top,
                                         width: ribbon.width, height: ribbon.maxY - top)),
                             with: .color(EFIS.red))
            }
        }

        drawAltitudeReadout(context, centerY: centerY, altitude: altitude)
    }

    /// The yellow readout: hundreds of feet in large green digits over the
    /// tape, the last two digits on a rolling drum outboard of it. The stepped
    /// outline is sized for a five-digit altitude — ten-thousands, thousands
    /// and hundreds each have a fixed slot, so a third digit appearing above
    /// 9,975 ft widens nothing.
    private func drawAltitudeReadout(_ context: GraphicsContext, centerY: CGFloat, altitude: Double) {
        // One-row window over the tape for the big digits, a three-row drum
        // window outboard: the drum shows the neighbouring 20 ft values above
        // and below the current one.
        let tape = PFD.altTape
        let digitWindow = CGRect(x: tape.minX, y: centerY - 2.83, width: tape.width, height: 5.66)
        let drumWindow = CGRect(x: tape.maxX, y: centerY - 4.5, width: 5.6, height: 9.0)

        // Black fill behind the whole shape, so tape graduations never print
        // through the digits.
        var background = Path()
        background.addRect(digitWindow)
        background.addRect(drumWindow)
        context.fill(background, with: .color(EFIS.background))

        var outline = Path()
        outline.move(to: CGPoint(x: digitWindow.minX, y: digitWindow.minY))
        outline.addLine(to: CGPoint(x: drumWindow.minX, y: digitWindow.minY))
        outline.addLine(to: CGPoint(x: drumWindow.minX, y: drumWindow.minY))
        outline.addLine(to: CGPoint(x: drumWindow.maxX, y: drumWindow.minY))
        outline.addLine(to: CGPoint(x: drumWindow.maxX, y: drumWindow.maxY))
        outline.addLine(to: CGPoint(x: drumWindow.minX, y: drumWindow.maxY))
        outline.addLine(to: CGPoint(x: drumWindow.minX, y: digitWindow.maxY))
        outline.addLine(to: CGPoint(x: digitWindow.minX, y: digitWindow.maxY))
        context.stroke(outline, with: .color(EFIS.yellow), lineWidth: Style.medium)

        let absoluteAltitude = abs(altitude)
        let hundreds = Int(absoluteAltitude / 100)
        let remainder = absoluteAltitude - Double(hundreds) * 100

        // Fixed digit slots, right to left: hundreds, thousands, ten-thousands.
        let pitch: CGFloat = 2.85
        func slot(_ index: Int) -> CGPoint {
            CGPoint(x: digitWindow.maxX - 0.95 - CGFloat(index) * pitch, y: centerY)
        }
        context.digits("\(hundreds % 10)", at: slot(0), size: Style.readoutType, EFIS.green, weight: .bold)
        if hundreds >= 10 {
            context.digits("\(hundreds / 10 % 10)", at: slot(1),
                           size: Style.readoutType, EFIS.green, weight: .bold)
        }
        if hundreds >= 100 {
            context.digits("\(hundreds / 100 % 10)", at: slot(2),
                           size: Style.readoutType, EFIS.green, weight: .bold)
        }

        // Below sea level the display stacks NEG beside the digits.
        if altitude < 0 {
            for (row, letter) in ["N", "E", "G"].enumerated() {
                context.digits(letter,
                               at: CGPoint(x: digitWindow.minX + 1.0, y: centerY + (CGFloat(row) - 1) * 2.85),
                               size: Style.scaleType, .white, weight: .bold)
            }
        }

        var drum = context
        drum.clip(to: Path(drumWindow.insetBy(dx: 0.3, dy: 0.3)))

        let rowHeight: CGFloat = 2.96
        let position = remainder / 20
        let base = position.rounded(.down)
        // Hold each value steady through most of its 20 ft step, then roll over
        // quickly, so the current value stays lined up with the index.
        let raw = CGFloat(position - base)
        let fraction = raw < 0.7 ? 0 : (raw - 0.7) / 0.3

        for step in -2...2 {
            let index = ((Int(base) + step) % 5 + 5) % 5
            drum.digits(String(format: "%02d", index * 20),
                        at: CGPoint(x: drumWindow.minX + 2.9, y: centerY - (CGFloat(step) - fraction) * rowHeight),
                        size: Style.scaleType, EFIS.green, weight: .bold)
        }
    }

    // MARK: - Vertical speed

    /// The V/S scale: labelled graduations (1, 2, 6 thousand ft/min) are small
    /// filled blocks, the ones between are thin strokes, the labels sit just
    /// inboard of the blocks, the zero reference is a yellow bar, and the
    /// needle is hinged beyond the display's right edge so it sweeps almost
    /// straight up and down.
    private func drawVerticalSpeed(_ context: GraphicsContext) {
        let zeroY = PFD.horizonCenter.y
        let x = PFD.verticalSpeedX

        context.fill(PFD.verticalSpeedOutline, with: .color(EFIS.tape))

        // In m/s the scale keeps its graduations — the 500/1000/2000/6000
        // ft/min marks become 0.5/1/2/6 m/s, so the strip spans a car-sized
        // ±6 m/s instead of ±6000 ft/min. The graduations below are placed in
        // ft/min, so their labels (1, 2, 6) read in either unit.
        let msMode = flightData.verticalSpeedUnit == .ms
        func y(_ fpm: Double) -> CGFloat { zeroY + PFD.verticalSpeedOffset(fpm: fpm) }

        let blockWidth: CGFloat = 1.2
        for sign in [1.0, -1.0] {
            for (fpm, height) in [(1_000.0, 0.92), (2_000.0, 0.92), (6_000.0, 0.76)] {
                let cy = y(sign * fpm)
                context.fill(Path(CGRect(x: x - blockWidth, y: cy - CGFloat(height) / 2,
                                         width: blockWidth, height: CGFloat(height))),
                             with: .color(.white))
                context.digits("\(Int(fpm / 1_000))", at: CGPoint(x: x - blockWidth - 0.9, y: cy),
                               size: Style.vsType, .white)
            }
            // 500 is a touch shorter than the others.
            for (fpm, x1) in [(500.0, x - 0.08), (1_500.0, x), (4_000.0, x)] {
                let cy = y(sign * fpm)
                context.line(from: CGPoint(x: x - blockWidth, y: cy), to: CGPoint(x: x1, y: cy),
                             .white, width: Style.hairline)
            }
        }

        // Zero reference: a yellow bar from just left of the strip to the
        // start of the graduations.
        let zeroLeft = PFD.verticalSpeedLeft - 0.36
        context.fill(Path(CGRect(x: zeroLeft, y: zeroY - 0.475, width: x - zeroLeft, height: 0.95)),
                     with: .color(EFIS.yellow))

        // Needle: a straight line from a hinge off the display's right edge
        // through the commanded point, drawn from just beyond the strip's
        // outboard edge to just inside the graduations. A background-colour
        // casing under the green stroke keeps it clean across the marks.
        let rate = flightData.verticalSpeedFpm * (msMode ? 0.00508 : 1)
        let tipOffset = PFD.verticalSpeedOffset(fpm: msMode ? rate * 1_000 : rate)
        let hingeX = PFD.verticalSpeedRight + 4.3
        let outerX = PFD.verticalSpeedRight + 1.16, tipX = x - 0.65
        let outerShare = (hingeX - outerX) / (hingeX - tipX)
        var needle = Path()
        needle.move(to: CGPoint(x: outerX, y: zeroY + tipOffset * outerShare))
        needle.addLine(to: CGPoint(x: tipX, y: zeroY + tipOffset))
        context.stroke(needle, with: .color(EFIS.background),
                       style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
        context.stroke(needle, with: .color(EFIS.green),
                       style: StrokeStyle(lineWidth: 0.7, lineCap: .round))

        // Digital rate — hundreds of ft/min, or m/s with one decimal — from
        // 200 ft/min, riding just beyond the needle tip on an unframed
        // background-colour patch over the strip's outboard part. The m/s
        // string is a character longer, so its patch grows inboard.
        let showReadout = msMode ? abs(rate) >= 1 : abs(rate) >= 200
        if showReadout {
            let text = msMode
                ? String(format: "%.1f", min(9.9, abs(rate)))
                : String(format: "%02d", min(99, Int((abs(rate) / 100).rounded())))
            let textY = zeroY + tipOffset + (rate < 0 ? 1.5 : -1.5)
            let patchWidth: CGFloat = msMode ? 5.35 : 4.44
            let patch = CGRect(x: PFD.verticalSpeedRight + 1.6 - patchWidth, y: textY - 1.39,
                               width: patchWidth, height: 2.77)
            context.fill(Path(patch), with: .color(EFIS.background))
            context.digits(text, at: CGPoint(x: patch.midX, y: textY + 0.07),
                           size: Style.vsType, EFIS.green, weight: .bold)
        }
    }

    // MARK: - Heading tape

    private func drawHeadingTape(_ context: GraphicsContext) {
        let tape = PFD.headingTape
        let heading = flightData.headingDeg
        let centerX = tape.midX

        context.fill(Path(tape), with: .color(EFIS.tape))

        var clipped = context
        clipped.clip(to: Path(tape))

        func x(for value: Double) -> CGFloat {
            centerX + CGFloat(value - heading) * PFD.headingScale
        }

        let span = Double(tape.width / PFD.headingScale) / 2 + 5
        var deg = ((heading - span) / 5).rounded(.down) * 5
        while deg <= heading + span {
            let value = normalizedHeading(deg)
            let major = Int(value.rounded()) % 10 == 0
            let tx = x(for: deg)
            clipped.line(from: CGPoint(x: tx, y: tape.minY),
                         to: CGPoint(x: tx, y: tape.minY + (major ? 2.14 : 1.26)), .white, width: Style.thin)
            if major {
                clipped.digits(String(format: "%02d", Int(value.rounded()) / 10),
                               at: CGPoint(x: tx, y: tape.minY + 4.28), size: Style.scaleType - 0.1, .white)
            }
            deg += 5
        }

        // Green track diamond.
        let trackX = x(for: heading + angularDifference(flightData.trackDeg, heading))
        var diamond = Path()
        diamond.move(to: CGPoint(x: trackX, y: tape.minY - 2.14))
        diamond.addLine(to: CGPoint(x: trackX + 1.39, y: tape.minY - 0.76))
        diamond.addLine(to: CGPoint(x: trackX, y: tape.minY + 0.63))
        diamond.addLine(to: CGPoint(x: trackX - 1.39, y: tape.minY - 0.76))
        diamond.closeSubpath()
        context.stroke(diamond, with: .color(EFIS.green), lineWidth: 0.38)

        // Magenta course pointer for the active leg.
        if let bearing = guidanceBearing {
            let courseX = x(for: heading + angularDifference(bearing, heading))
            if tape.minX...tape.maxX ~= courseX {
                context.line(from: CGPoint(x: courseX, y: tape.maxY - 0.63),
                             to: CGPoint(x: courseX, y: tape.maxY + 2.52), EFIS.magenta, width: 0.5)
                context.line(from: CGPoint(x: courseX - 1.39, y: tape.maxY + 1.0),
                             to: CGPoint(x: courseX + 1.39, y: tape.maxY + 1.0), EFIS.magenta, width: 0.5)
            }
        }

        // Selected heading: a cyan triangle on the scale, or its value at
        // the side it lies on when off the tape.
        if let selected = autoFlight.selectedHeadingDeg {
            let diff = angularDifference(selected, heading)
            let hx = x(for: heading + diff)
            if tape.minX + 1...tape.maxX - 1 ~= hx {
                var bug = Path()
                bug.move(to: CGPoint(x: hx, y: tape.minY + 0.3))
                bug.addLine(to: CGPoint(x: hx - 1.2, y: tape.minY - 1.9))
                bug.addLine(to: CGPoint(x: hx + 1.2, y: tape.minY - 1.9))
                bug.closeSubpath()
                context.fill(bug, with: .color(EFIS.cyan))
            } else {
                context.digits(String(format: "%03d", Int(selected.rounded()) % 360),
                               at: CGPoint(x: diff > 0 ? tape.maxX - 3 : tape.minX + 3, y: tape.minY - 2.0),
                               size: Style.scaleType - 0.4, EFIS.cyan)
            }
        }

        // Yellow lubber line at the current heading.
        context.line(from: CGPoint(x: centerX, y: tape.minY - 2.9),
                     to: CGPoint(x: centerX, y: tape.minY + 2.14), EFIS.yellow, width: Style.heavy)
    }

    // MARK: - Deviation scales

    /// LOC and G/S scales, on final approach only. There is no ILS receiver
    /// here, so these are driven by the guidance course and a 3° reference
    /// path to the destination — a CDI in ILS clothing, not a real localiser.
    private func drawDeviationScales(_ context: GraphicsContext) {
        guard guidance.showsDeviationScales else { return }
        let center = PFD.horizonCenter

        // Localiser: dots below the attitude window; glideslope: dots to its
        // right. Two dots either side, a full-scale deflection to the outer.
        let spacing: CGFloat = 9.7
        let locY = PFD.windowBottom + 5.6
        let gsX = PFD.windowRight + 2.6
        for n: CGFloat in [-2, -1, 1, 2] {
            drawDot(context, at: CGPoint(x: center.x + n * spacing, y: locY))
            drawDot(context, at: CGPoint(x: gsX, y: center.y + n * spacing))
        }
        let locDeviation = (guidance.localizerError / 10).clamped(to: -1...1)
        drawDiamond(context, at: CGPoint(x: center.x + CGFloat(locDeviation) * 2 * spacing, y: locY))
        if let deviation = glideDeviation {
            drawDiamond(context, at: CGPoint(x: gsX, y: center.y - CGFloat(deviation) * 2 * spacing))
        }
    }

    private func drawDot(_ context: GraphicsContext, at point: CGPoint) {
        let r: CGFloat = 0.7
        context.stroke(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.white), lineWidth: 0.31)
    }

    private func drawDiamond(_ context: GraphicsContext, at point: CGPoint) {
        var diamond = Path()
        diamond.move(to: CGPoint(x: point.x, y: point.y - 1.9))
        diamond.addLine(to: CGPoint(x: point.x + 1.5, y: point.y))
        diamond.addLine(to: CGPoint(x: point.x, y: point.y + 1.9))
        diamond.addLine(to: CGPoint(x: point.x - 1.5, y: point.y))
        diamond.closeSubpath()
        context.stroke(diamond, with: .color(EFIS.magenta), lineWidth: Style.medium)
    }

    // MARK: - Off-tape readouts

    private func drawOfftapeReadouts(_ context: GraphicsContext) {
        let below = PFD.speedTape.maxY + 4.0      // first line under the tapes
        let above = PFD.tapeTop - 3.0              // line over the tapes
        let alt = PFD.altTape

        // Mach, under the speed tape.
        if flightData.machNumber >= 0.15 {
            context.digits(String(format: ".%03d", Int((flightData.machNumber * 1000).rounded())),
                           at: CGPoint(x: PFD.speedTape.midX, y: below), size: Style.annunciationType,
                           EFIS.green, weight: .bold)
        }

        // FCU selected altitude above the tape, baro reference below it.
        context.digits("\(Int(flightData.selectedAltitudeFt))",
                       at: CGPoint(x: alt.midX + 1.9, y: above), size: 4.15,
                       EFIS.cyan, weight: .bold)

        // Height above the ground under the aircraft, in flight.
        if let ground = groundElevationFt {
            let height = max(0, flightData.altitudeFt - ground)
            // Monospaced: each character is about 0.6 of the type size wide.
            let size: CGFloat = 3.6, advance = size * 0.6
            let start = alt.midX + 1 - advance * 4.5          // "HGT 34500" centred
            context.digits("HGT", at: CGPoint(x: start, y: below + 4.4), size: size, .white, anchor: .leading)
            context.digits("\(Int((height / 10).rounded()) * 10)",
                           at: CGPoint(x: start + advance * 4, y: below + 4.4), size: size,
                           height < 2_500 ? EFIS.amber : EFIS.green, weight: .bold, anchor: .leading)
        }

        if flightData.isStandardBaro {
            context.digits("STD", at: CGPoint(x: alt.midX + 1.9, y: below), size: Style.annunciationType,
                           EFIS.cyan, weight: .bold)
        } else {
            context.digits("QNH", at: CGPoint(x: alt.midX - 2.5, y: below), size: 3.8, .white)
            context.digits("1013", at: CGPoint(x: alt.midX + 5, y: below), size: Style.annunciationType,
                           EFIS.cyan, weight: .bold)
        }

        // Destination block, in the slot the ILS identifier occupies.
        if let destination = routePlanner.destination {
            let name = destination.name.uppercased().prefix(8).description
            let x: CGFloat = 1.26, top = below + 4.4
            context.digits(name, at: CGPoint(x: x, y: top), size: 3.8, EFIS.magenta,
                           weight: .bold, anchor: .leading)
            if let distance = routePlanner.distanceToGoNm(from: flightData.location) {
                context.digits(String(format: "%.1f NM", distance),
                               at: CGPoint(x: x, y: top + 4.4), size: 3.8, EFIS.magenta,
                               weight: .bold, anchor: .leading)
            }
        }
    }

    // MARK: - FMA

    private func drawFMA(_ context: GraphicsContext) {
        let box = PFD.fma
        let rowHeight = box.height / 3

        for x in PFD.fmaSeparators {
            context.line(from: CGPoint(x: x, y: box.minY), to: CGPoint(x: x, y: box.maxY),
                         .white, width: 0.25)
        }

        let columns = fmaColumns
        let bounds: [ClosedRange<CGFloat>] = [
            0...PFD.fmaSeparators[0],
            PFD.fmaSeparators[0]...PFD.fmaSeparators[1],
            PFD.fmaSeparators[1]...PFD.fmaSeparators[2],
            PFD.fmaSeparators[2]...PFD.fmaSeparators[3],
            PFD.fmaSeparators[3]...PFD.canvas,
        ]

        for (column, range) in zip(columns, bounds) {
            let midX = (range.lowerBound + range.upperBound) / 2
            for (row, entry) in column.enumerated() where !entry.text.isEmpty {
                context.digits(entry.text,
                               at: CGPoint(x: midX, y: box.minY + rowHeight * (CGFloat(row) + 0.5)),
                               size: Style.fmaType, entry.color, weight: .bold)
            }
        }
    }

    private typealias FMAEntry = (text: String, color: Color)

    /// Five columns of three rows: thrust, vertical, lateral, approach
    /// capability, and engagement status.
    private var fmaColumns: [[FMAEntry]] {
        let error = flightData.selectedAltitudeFt - flightData.altitudeFt
        let vs = flightData.verticalSpeedFpm
        let navEngaged = routePlanner.destination != nil
        let af = autoFlight

        // Thrust: with A/THR off the crew has the levers and the column is
        // empty.
        let thrust: String
        if !af.autothrust { thrust = "" }
        else if vs > 500 && af.selectedVerticalSpeedFpm == nil { thrust = "THR CLB" }
        else if vs < -500 && af.selectedVerticalSpeedFpm == nil { thrust = "THR IDLE" }
        else { thrust = flightData.machNumber >= 0.5 ? "MACH" : "SPEED" }

        var vertical: FMAEntry
        var verticalArmed: FMAEntry = ("", EFIS.cyan)
        if guidance.isGlideslopeCaptured {
            vertical = ("G/S", EFIS.green)
        } else if abs(error) < 250 {
            vertical = (abs(vs) < 200 ? "ALT CRZ" : "ALT*", EFIS.green)
        } else if let target = af.selectedVerticalSpeedFpm {
            vertical = (String(format: "V/S %+d", Int(target)), EFIS.green)
            verticalArmed = ("ALT", EFIS.cyan)
        } else if vs > 200 {
            vertical = ("CLB", EFIS.green)
            verticalArmed = (error > 0 ? "ALT" : "", EFIS.cyan)
        } else if vs < -200 {
            vertical = ("DES", EFIS.green)
            verticalArmed = (error < 0 ? "ALT" : "", EFIS.cyan)
        } else {
            vertical = ("ALT CRZ", EFIS.green)
        }
        if af.approachArmed && !guidance.isGlideslopeCaptured {
            verticalArmed = ("G/S", EFIS.cyan)
        }

        let lateral: FMAEntry
        if guidance.isLocalizerCaptured { lateral = ("LOC", EFIS.green) }
        else if af.selectedHeadingDeg != nil || !navEngaged { lateral = ("HDG", EFIS.green) }
        else { lateral = ("NAV", EFIS.green) }
        let lateralArmed: FMAEntry = af.isLocalizerArmed && !guidance.isLocalizerCaptured
            ? ("LOC", EFIS.cyan) : ("", .white)

        let autopilot: String
        switch (af.autopilot1, af.autopilot2) {
        case (true, true): autopilot = "AP1+2"
        case (true, false): autopilot = "AP1"
        case (false, true): autopilot = "AP2"
        default: autopilot = ""
        }
        let demo: FMAEntry = (flightData.isDemoMode ? "DEMO" : "", EFIS.amber)

        return [
            [(thrust, EFIS.green), ("", .white), ("", .white)],
            [vertical, verticalArmed, ("", .white)],
            [lateral, lateralArmed, ("", .white)],
            af.approachArmed ? [("CAT 1", .white), ("", .white), demo] : [demo, ("", .white), ("", .white)],
            [(autopilot, .white), (af.flightDirector ? "1 FD 2" : "", .white), (af.autothrust ? "A/THR" : "", .white)],
        ]
    }

    // MARK: - Derived guidance

    private var guidance: Guidance { Guidance(flightData: flightData, routePlanner: routePlanner) }
    private var autoFlight: AutoFlight { flightData.autoFlight }
    private var guidanceBearing: Double? { guidance.bearing }
    private var courseError: Double { guidance.courseError }
    private var glideDeviation: Double? { guidance.glideDeviation }
}

#Preview {
    PFDView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
        .environmentObject(SpeedLimitProvider())
        .environmentObject(FlightPackStore())
        .frame(width: 390, height: 390)
        .background(.black)
}
