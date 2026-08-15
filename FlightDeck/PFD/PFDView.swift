import SwiftUI

/// A320 Primary Flight Display.
///
/// The whole instrument is drawn into one canvas using the display's native
/// 158.75-unit coordinate system (see ``PFD``), then scaled to fit. That keeps
/// every element in the exact geometric relationship the real PFD has.
struct PFDView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner

    var profile: AircraftProfile = .a320

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
        sphere.line(from: CGPoint(x: -ext, y: 0), to: CGPoint(x: ext, y: 0), .white, width: 0.7)

        // Pitch ladder. Each rung sits at its own angle's horizon offset, so the
        // rungs compress at high attitudes exactly as the horizon does.
        for rung in PFD.pitchLadder {
            let y = -PFD.horizonOffset(pitch: rung.deg)
            sphere.line(from: CGPoint(x: -rung.halfWidth, y: y),
                        to: CGPoint(x: rung.halfWidth, y: y), .white, width: 0.55)
            if rung.labelled {
                let text = "\(abs(Int(rung.deg)))"
                sphere.digits(text, at: CGPoint(x: -rung.halfWidth - 6, y: y), size: 5.6, .white)
                sphere.digits(text, at: CGPoint(x: rung.halfWidth + 6, y: y), size: 5.6, .white)
            }
        }

        drawFlightDirector(ctx)
    }

    /// Flight director cross bars — green, centred on the commanded attitude.
    /// With no autopilot to follow, they command the flight path back to the
    /// selected altitude and the direct-to course.
    private func drawFlightDirector(_ context: GraphicsContext) {
        let center = PFD.horizonCenter
        let pitchCommand = (flightData.selectedAltitudeFt - flightData.altitudeFt) / 1_000
        let barY = center.y - PFD.horizonOffset(pitch: pitchCommand.clamped(to: -10...10))
            + PFD.horizonOffset(pitch: flightData.pitchDeg)
        let rollCommand = courseError.clamped(to: -20...20)
        let barX = center.x + CGFloat(rollCommand) * 0.9

        context.line(from: CGPoint(x: center.x - 17, y: barY),
                     to: CGPoint(x: center.x + 17, y: barY), EFIS.green, width: 0.9)
        context.line(from: CGPoint(x: barX, y: center.y - 17),
                     to: CGPoint(x: barX, y: center.y + 17), EFIS.green, width: 0.9)
    }

    /// The fixed yellow aircraft reference — two stepped brackets either side of
    /// a small centre square.
    private func drawAircraftReference(_ context: GraphicsContext) {
        var left = Path()
        left.move(to: CGPoint(x: 34.153, y: 79.563))
        left.addLine(to: CGPoint(x: 49.263, y: 79.563))
        left.addLine(to: CGPoint(x: 49.263, y: 86.114))
        left.addLine(to: CGPoint(x: 46.745, y: 86.114))
        left.addLine(to: CGPoint(x: 46.745, y: 82.083))
        left.addLine(to: CGPoint(x: 34.153, y: 82.083))
        left.closeSubpath()

        var right = Path()
        right.move(to: CGPoint(x: 88.550, y: 86.114))
        right.addLine(to: CGPoint(x: 91.068, y: 86.114))
        right.addLine(to: CGPoint(x: 91.068, y: 82.083))
        right.addLine(to: CGPoint(x: 103.660, y: 82.083))
        right.addLine(to: CGPoint(x: 103.660, y: 79.563))
        right.addLine(to: CGPoint(x: 88.550, y: 79.563))
        right.closeSubpath()

        for path in [left, right] {
            context.fill(path, with: .color(EFIS.background))
            context.stroke(path, with: .color(EFIS.yellow), lineWidth: 0.55)
        }

        let square = Path(CGRect(x: PFD.horizonCenter.x - 1.5, y: PFD.horizonCenter.y - 1.5,
                                 width: 3, height: 3))
        context.fill(square, with: .color(EFIS.background))
        context.stroke(square, with: .color(EFIS.yellow), lineWidth: 0.55)
    }

    // MARK: - Bank scale

    private func drawBankScale(_ context: GraphicsContext) {
        let center = PFD.horizonCenter
        let radius = PFD.bankScaleRadius

        func point(_ angleDeg: Double, _ r: CGFloat) -> CGPoint {
            let a = angleDeg * .pi / 180
            return CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))
        }

        // Arc spanning ±31°, the limit of the graduated section.
        var arc = Path()
        for step in stride(from: -31.4, through: 31.4, by: 1.0) {
            let p = point(step, radius)
            step == -31.4 ? arc.move(to: p) : arc.addLine(to: p)
        }
        context.stroke(arc, with: .color(.white), lineWidth: 0.55)

        // 10/20/30 are small hollow rectangles standing on the arc; 45 is a
        // plain radial tick beyond the end of the arc.
        for angle in [-30.0, -20, -10, 10, 20, 30] {
            let inner = point(angle, radius), outer = point(angle, radius + 2.9)
            let a = angle * .pi / 180
            let across = CGPoint(x: cos(a) * 0.85, y: sin(a) * 0.85)
            var mark = Path()
            mark.move(to: CGPoint(x: inner.x - across.x, y: inner.y - across.y))
            mark.addLine(to: CGPoint(x: outer.x - across.x, y: outer.y - across.y))
            mark.addLine(to: CGPoint(x: outer.x + across.x, y: outer.y + across.y))
            mark.addLine(to: CGPoint(x: inner.x + across.x, y: inner.y + across.y))
            mark.closeSubpath()
            context.stroke(mark, with: .color(.white), lineWidth: 0.5)
        }
        for angle in [-45.0, 45] {
            context.line(from: point(angle, radius - 0.2), to: point(angle, radius + 4.1),
                         .white, width: 0.55)
        }

        // Fixed zero index, pointing down at the scale.
        var zero = Path()
        zero.move(to: CGPoint(x: 68.906, y: 38.650))
        zero.addLine(to: CGPoint(x: 66.388, y: 34.950))
        zero.addLine(to: CGPoint(x: 71.424, y: 34.950))
        zero.closeSubpath()
        context.stroke(zero, with: .color(EFIS.yellow), lineWidth: 0.55)

        // Roll pointer and sideslip target, rotating with the horizon.
        var rolled = context
        rolled.translateBy(x: center.x, y: center.y)
        rolled.rotate(by: .degrees(-flightData.rollDeg))
        rolled.translateBy(x: -center.x, y: -center.y)

        var pointer = Path()
        pointer.move(to: CGPoint(x: 66.074, y: 43.983))
        pointer.addLine(to: CGPoint(x: 68.934, y: 39.750))
        pointer.addLine(to: CGPoint(x: 71.795, y: 43.983))
        pointer.closeSubpath()
        rolled.stroke(pointer, with: .color(EFIS.yellow), lineWidth: 0.55)

        // No yaw sensor on a phone, so the slip target stays centred under the
        // pointer, as it is in coordinated flight.
        var slip = Path()
        slip.move(to: CGPoint(x: 66.4, y: 44.85))
        slip.addLine(to: CGPoint(x: 71.5, y: 44.85))
        slip.addLine(to: CGPoint(x: 70.9, y: 47.0))
        slip.addLine(to: CGPoint(x: 67.0, y: 47.0))
        slip.closeSubpath()
        rolled.stroke(slip, with: .color(EFIS.yellow), lineWidth: 0.55)
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
                clipped.line(from: CGPoint(x: tape.maxX - (labelled ? 3.6 : 2.2), y: ty),
                             to: CGPoint(x: tape.maxX, y: ty), .white, width: 0.55)
                if labelled {
                    clipped.digits("\(Int(value))", at: CGPoint(x: tape.maxX - 5, y: ty),
                                   size: 6.2, .white, anchor: .trailing)
                }
            }
            value += 10
        }

        // VMAX barber pole and the VLS / alpha-max bars, just outboard of the tape.
        let stripX = tape.maxX
        drawBarberPole(clipped, x: stripX, from: y(for: profile.vmo * unit), to: tape.minY - 2,
                       color: EFIS.red)
        clipped.fill(Path(CGRect(x: stripX, y: y(for: profile.vls * unit),
                                 width: PFD.speedStripWidth,
                                 height: max(0, y(for: profile.vAlphaMax * unit)
                                             - y(for: profile.vls * unit)))),
                     with: .color(EFIS.amber))
        drawBarberPole(clipped, x: stripX, from: tape.maxY + 2, to: y(for: profile.vAlphaMax * unit),
                       color: EFIS.amber)

        // Speed trend arrow — where the speed will be in 10 seconds.
        if flightData.isSpeedTrendShown {
            drawTrendArrow(clipped, trend: flightData.speedTrendKts * unit, centerY: centerY)
        }

        // Fixed yellow airspeed reference: a filled bar riding into the tape,
        // flaring into its arrowhead at the inboard end, plus the small stub
        // at the outboard edge.
        var pointer = Path()
        pointer.move(to: CGPoint(x: 13.994, y: 80.460))
        pointer.addLine(to: CGPoint(x: 13.994, y: 81.186))
        pointer.addLine(to: CGPoint(x: 20.542, y: 81.186))
        pointer.addLine(to: CGPoint(x: 23.664, y: 82.335))
        pointer.addLine(to: CGPoint(x: 23.664, y: 79.311))
        pointer.addLine(to: CGPoint(x: 20.542, y: 80.460))
        pointer.closeSubpath()
        pointer.addRect(CGRect(x: 0.0926, y: 80.459, width: 2.0147, height: 0.7257))

        context.fill(pointer, with: .color(EFIS.yellow))
        context.stroke(pointer, with: .color(EFIS.background), lineWidth: 0.25)
    }

    private func drawBarberPole(_ context: GraphicsContext, x: CGFloat,
                                from: CGFloat, to: CGFloat, color: Color) {
        guard from > to else { return }
        var y = from
        var filled = true
        while y > to {
            let next = max(to, y - 2.2)
            context.fill(Path(CGRect(x: x, y: next, width: PFD.speedStripWidth, height: y - next)),
                         with: .color(filled ? color : EFIS.background))
            filled.toggle()
            y = next
        }
    }

    /// Yellow trend arrow riding the tape: a line from the current speed to
    /// where it will be in 10 seconds, tipped with an open chevron. `trend`
    /// is in the tape's display unit.
    private func drawTrendArrow(_ context: GraphicsContext, trend: Double, centerY: CGFloat) {
        let x: CGFloat = 15.455
        let tip = centerY - CGFloat(trend) * PFD.speedScale
        let back: CGFloat = trend > 0 ? 2.4607 : -2.4607

        var arrow = Path()
        arrow.move(to: CGPoint(x: x, y: centerY))
        arrow.addLine(to: CGPoint(x: x, y: tip))
        arrow.move(to: CGPoint(x: x - 1.2531, y: tip + back))
        arrow.addLine(to: CGPoint(x: x, y: tip))
        arrow.addLine(to: CGPoint(x: x + 1.2531, y: tip + back))
        context.stroke(arrow, with: .color(EFIS.yellow), lineWidth: 0.7)
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
                         to: CGPoint(x: tape.minX + (labelled ? 2.6 : 1.6), y: ty),
                         .white, width: 0.55)
            if labelled {
                clipped.digits(String(format: "%03d", Int(value / 100)),
                               at: CGPoint(x: tape.minX + 3.2, y: ty),
                               size: 5.6, .white, anchor: .leading)
            }
            value += 100
        }

        // Cyan FCU altitude bug.
        let bugY = y(for: flightData.selectedAltitudeFt)
        if tape.minY...tape.maxY ~= bugY {
            var bug = Path()
            bug.move(to: CGPoint(x: tape.minX, y: bugY - 2.4))
            bug.addLine(to: CGPoint(x: tape.minX + 3.2, y: bugY - 2.4))
            bug.addLine(to: CGPoint(x: tape.minX + 3.2, y: bugY + 2.4))
            bug.addLine(to: CGPoint(x: tape.minX, y: bugY + 2.4))
            clipped.stroke(bug, with: .color(EFIS.cyan), lineWidth: 0.8)
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
        // window outboard: the real display shows the neighbouring 20 ft
        // values above and below the current one.
        let digitWindow = CGRect(x: 117.75, y: centerY - 4.4853, width: 13.1, height: 8.9706)
        let drumWindow = CGRect(x: 130.85, y: centerY - 7.1565, width: 8.8647, height: 14.313)

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
        context.stroke(outline, with: .color(EFIS.yellow), lineWidth: 0.7)

        let absoluteAltitude = abs(altitude)
        let hundreds = Int(absoluteAltitude / 100)
        let remainder = absoluteAltitude - Double(hundreds) * 100

        // Fixed digit slots, right to left: hundreds, thousands, ten-thousands.
        context.digits("\(hundreds % 10)", at: CGPoint(x: 129.385, y: centerY),
                       size: 8.0, EFIS.green, weight: .bold)
        if hundreds >= 10 {
            context.digits("\(hundreds / 10 % 10)", at: CGPoint(x: 124.934, y: centerY),
                           size: 8.0, EFIS.green, weight: .bold)
        }
        if hundreds >= 100 {
            context.digits("\(hundreds / 100 % 10)", at: CGPoint(x: 120.252, y: centerY),
                           size: 8.0, EFIS.green, weight: .bold)
        }

        // Below sea level the display stacks NEG beside the digits.
        if altitude < 0 {
            for (row, letter) in ["N", "E", "G"].enumerated() {
                context.digits(letter,
                               at: CGPoint(x: 119.4, y: centerY + (CGFloat(row) - 1) * 4.5),
                               size: 5.6, .white, weight: .bold)
            }
        }

        var drum = context
        drum.clip(to: Path(drumWindow.insetBy(dx: 0.5, dy: 0.5)))

        let rowHeight: CGFloat = 4.7
        let position = remainder / 20
        let base = position.rounded(.down)
        // Hold each value steady through most of its 20 ft step, then roll over
        // quickly, so the current value stays lined up with the index.
        let raw = CGFloat(position - base)
        let fraction = raw < 0.7 ? 0 : (raw - 0.7) / 0.3

        for step in -2...2 {
            let index = ((Int(base) + step) % 5 + 5) % 5
            drum.digits(String(format: "%02d", index * 20),
                        at: CGPoint(x: 135.44, y: centerY - (CGFloat(step) - fraction) * rowHeight),
                        size: 5.6, EFIS.green, weight: .bold)
        }
    }

    // MARK: - Vertical speed

    private func drawVerticalSpeed(_ context: GraphicsContext) {
        let zeroY = PFD.horizonCenter.y
        let x = PFD.verticalSpeedX

        context.fill(PFD.verticalSpeedOutline, with: .color(EFIS.tape))

        // In m/s the scale reuses the reference display's geometry — the
        // 500/1000/2000/6000 ft/min graduations become 0.5/1/2/6 m/s, so the
        // strip spans a car-sized ±6 m/s instead of ±6000 ft/min.
        let msMode = flightData.verticalSpeedUnit == .ms
        func offset(_ value: Double) -> CGFloat {
            PFD.verticalSpeedOffset(fpm: msMode ? value * 1_000 : value)
        }

        let marks: [Double] = msMode ? [0.5, 1, 2, 6] : [500, 1_000, 2_000, 6_000]
        for mark in marks {
            for sign in [1.0, -1.0] {
                let y = zeroY + offset(mark * sign)
                let major = mark >= (msMode ? 1 : 1_000)
                context.line(from: CGPoint(x: x - (major ? 1.9 : 1.2), y: y),
                             to: CGPoint(x: x, y: y), .white, width: 0.5)
                if major {
                    context.digits("\(Int(msMode ? mark : mark / 1_000))",
                                   at: CGPoint(x: x - 3.1, y: y),
                                   size: 5.4, .white, anchor: .trailing)
                }
            }
        }

        // Zero reference.
        context.line(from: CGPoint(x: 145.8, y: zeroY), to: CGPoint(x: x, y: zeroY),
                     .white, width: 0.9)

        // Needle: pivots on the outboard edge, tip rides the inboard edge.
        let rate = flightData.verticalSpeedFpm * (msMode ? 0.00508 : 1)
        let tipY = zeroY + offset(rate)
        context.line(from: CGPoint(x: 155.5, y: zeroY), to: CGPoint(x: 146.4, y: tipY),
                     EFIS.green, width: 0.9)

        // Digital rate — hundreds of ft/min, or m/s with one decimal — boxed
        // at the needle tip and filled so it masks the graduations under it.
        let showReadout = msMode ? abs(rate) >= 1 : abs(rate) >= 200
        if showReadout {
            let text = msMode
                ? String(format: "%.1f", min(9.9, abs(rate)))
                : String(format: "%02d", min(99, Int((abs(rate) / 100).rounded())))
            // Spans the full width of the scale so it masks whichever
            // graduation label the needle happens to be pointing at.
            let box = CGRect(x: 146.3, y: tipY - 3.1, width: 9.2, height: 6.2)
            context.fill(Path(box), with: .color(EFIS.background))
            context.stroke(Path(box), with: .color(EFIS.green), lineWidth: 0.5)
            context.digits(text, at: CGPoint(x: box.midX, y: box.midY),
                           size: msMode ? 4.9 : 5.4, EFIS.green, weight: .bold)
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
                         to: CGPoint(x: tx, y: tape.minY + (major ? 3.4 : 2.0)), .white, width: 0.55)
            if major {
                clipped.digits(String(format: "%02d", Int(value.rounded()) / 10),
                               at: CGPoint(x: tx, y: tape.minY + 6.8), size: 5.4, .white)
            }
            deg += 5
        }

        // Green track diamond.
        let trackX = x(for: heading + angularDifference(flightData.trackDeg, heading))
        var diamond = Path()
        diamond.move(to: CGPoint(x: trackX, y: tape.minY - 3.4))
        diamond.addLine(to: CGPoint(x: trackX + 2.2, y: tape.minY - 1.2))
        diamond.addLine(to: CGPoint(x: trackX, y: tape.minY + 1.0))
        diamond.addLine(to: CGPoint(x: trackX - 2.2, y: tape.minY - 1.2))
        diamond.closeSubpath()
        context.stroke(diamond, with: .color(EFIS.green), lineWidth: 0.6)

        // Magenta course pointer for the active leg.
        if let bearing = guidanceBearing {
            let courseX = x(for: heading + angularDifference(bearing, heading))
            if tape.minX...tape.maxX ~= courseX {
                context.line(from: CGPoint(x: courseX, y: tape.maxY - 1),
                             to: CGPoint(x: courseX, y: tape.maxY + 4), EFIS.magenta, width: 0.8)
                context.line(from: CGPoint(x: courseX - 2.2, y: tape.maxY + 1.6),
                             to: CGPoint(x: courseX + 2.2, y: tape.maxY + 1.6), EFIS.magenta, width: 0.8)
            }
        }

        // Yellow lubber line at the current heading.
        context.line(from: CGPoint(x: centerX, y: tape.minY - 4.6),
                     to: CGPoint(x: centerX, y: tape.minY + 3.4), EFIS.yellow, width: 1.1)
    }

    // MARK: - Deviation scales

    /// LOC and G/S scales. There is no ILS receiver here, so these are driven by
    /// the direct-to course and a 3° reference path to the destination — a CDI
    /// in ILS clothing, not a real localiser.
    private func drawDeviationScales(_ context: GraphicsContext) {
        guard routePlanner.destination != nil else { return }
        let center = PFD.horizonCenter

        // Localiser: dots below the attitude window.
        for offset in [-30.8, -15.4, 15.4, 30.8] {
            let dot = CGPoint(x: center.x + offset, y: 132)
            context.stroke(Path(ellipseIn: CGRect(x: dot.x - 1.1, y: dot.y - 1.1,
                                                  width: 2.2, height: 2.2)),
                           with: .color(.white), lineWidth: 0.5)
        }
        let locDeviation = (courseError / 10).clamped(to: -1...1)
        drawDiamond(context, at: CGPoint(x: center.x + CGFloat(locDeviation) * 30.8, y: 132))

        // Glideslope: dots to the right of the attitude window.
        for offset in [-31.0, -15.5, 15.5, 31.0] {
            let dot = CGPoint(x: 110, y: center.y + offset)
            context.stroke(Path(ellipseIn: CGRect(x: dot.x - 1.1, y: dot.y - 1.1,
                                                  width: 2.2, height: 2.2)),
                           with: .color(.white), lineWidth: 0.5)
        }
        if let deviation = glideDeviation {
            drawDiamond(context, at: CGPoint(x: 110, y: center.y - CGFloat(deviation) * 31.0))
        }
    }

    private func drawDiamond(_ context: GraphicsContext, at point: CGPoint) {
        var diamond = Path()
        diamond.move(to: CGPoint(x: point.x, y: point.y - 3.0))
        diamond.addLine(to: CGPoint(x: point.x + 2.4, y: point.y))
        diamond.addLine(to: CGPoint(x: point.x, y: point.y + 3.0))
        diamond.addLine(to: CGPoint(x: point.x - 2.4, y: point.y))
        diamond.closeSubpath()
        context.stroke(diamond, with: .color(EFIS.magenta), lineWidth: 0.7)
    }

    // MARK: - Off-tape readouts

    private func drawOfftapeReadouts(_ context: GraphicsContext) {
        // Mach, under the speed tape.
        if flightData.machNumber >= 0.15 {
            context.digits(String(format: ".%03d", Int((flightData.machNumber * 1000).rounded())),
                           at: CGPoint(x: PFD.speedTape.midX, y: 130), size: 6.4,
                           EFIS.green, weight: .bold)
        }

        // FCU selected altitude above the tape, baro reference below it.
        context.digits("\(Int(flightData.selectedAltitudeFt))",
                       at: CGPoint(x: PFD.altTape.midX + 3, y: 33.5), size: 6.6,
                       EFIS.cyan, weight: .bold)

        if flightData.isStandardBaro {
            context.digits("STD", at: CGPoint(x: PFD.altTape.midX + 3, y: 130), size: 6.4,
                           EFIS.cyan, weight: .bold)
        } else {
            context.digits("QNH", at: CGPoint(x: PFD.altTape.midX - 4, y: 130), size: 6.0, .white)
            context.digits("1013", at: CGPoint(x: PFD.altTape.midX + 8, y: 130), size: 6.4,
                           EFIS.cyan, weight: .bold)
        }

        // Destination block, in the slot the ILS identifier occupies.
        if let destination = routePlanner.destination {
            let name = destination.name.uppercased().prefix(8).description
            context.digits(name, at: CGPoint(x: 2, y: 137), size: 6.0, EFIS.magenta,
                           weight: .bold, anchor: .leading)
            if let distance = routePlanner.distanceToGoNm(from: flightData.location) {
                context.digits(String(format: "%.1f NM", distance),
                               at: CGPoint(x: 2, y: 144), size: 6.0, EFIS.magenta,
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
                         .white, width: 0.4)
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
                               size: 5.2, entry.color, weight: .bold)
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

        let thrust: String
        if vs > 500 { thrust = "THR CLB" }
        else if vs < -500 { thrust = "THR IDLE" }
        else { thrust = flightData.machNumber >= 0.5 ? "MACH" : "SPEED" }

        let vertical: FMAEntry
        var verticalArmed: FMAEntry = ("", EFIS.cyan)
        if abs(error) < 250 {
            vertical = (abs(vs) < 200 ? "ALT CRZ" : "ALT*", EFIS.green)
        } else if vs > 200 {
            vertical = ("CLB", EFIS.green)
            verticalArmed = (error > 0 ? "ALT" : "", EFIS.cyan)
        } else if vs < -200 {
            vertical = ("DES", EFIS.green)
            verticalArmed = (error < 0 ? "ALT" : "", EFIS.cyan)
        } else {
            vertical = ("ALT CRZ", EFIS.green)
        }

        return [
            [(thrust, EFIS.green), ("", .white), ("", .white)],
            [vertical, verticalArmed, ("", .white)],
            [(navEngaged ? "NAV" : "HDG", EFIS.green), ("", .white), ("", .white)],
            [(flightData.isDemoMode ? "DEMO" : "", EFIS.amber), ("", .white), ("", .white)],
            [("AP1", .white), ("1 FD 2", .white), ("A/THR", .white)],
        ]
    }

    // MARK: - Derived guidance

    /// Bearing the guidance steers toward: a point on the flight plan a few
    /// seconds ahead of the aircraft — the current leg, following the planned
    /// path around its curves — not the final destination. On a direct-to leg
    /// the destination is the path.
    private var guidanceBearing: Double? {
        guard let location = flightData.location else { return nil }
        // Look ahead 5 s at the current speed, at least 150 m, so the command
        // leads each turn without cutting the corner.
        let lookaheadMeters = max(150, flightData.groundSpeedKts * 1852 / 3600 * 5)
        guard let target = routePlanner.guidanceTargetCoordinate(lookaheadMeters: lookaheadMeters)
        else { return nil }
        return NDGeometry(apex: .zero, radius: 1, rangeNm: 1,
                          origin: location.coordinate, headingDeg: 0)
            .vector(to: target).bearingDeg
    }

    /// Signed error between the guidance course and the actual track, in
    /// degrees, positive right.
    private var courseError: Double {
        guard let bearing = guidanceBearing else { return 0 }
        return angularDifference(bearing, flightData.trackDeg)
    }

    /// Deviation from a 3° path to the destination, normalised to ±1 full scale.
    private var glideDeviation: Double? {
        guard let distance = routePlanner.distanceToGoNm(from: flightData.location),
              distance > 0.3 else { return nil }
        let onPathFt = distance * 6_076.12 * tan(3 * .pi / 180)
        return ((flightData.altitudeFt - onPathFt) / 600).clamped(to: -1...1)
    }
}

#Preview {
    PFDView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
        .frame(width: 390, height: 390)
        .background(.black)
}
