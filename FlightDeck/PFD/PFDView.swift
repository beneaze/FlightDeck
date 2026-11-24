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

    /// Height above that terrain while below the radio height's 2500 ft
    /// ceiling; nil above it or with no terrain.
    private var radioHeightFt: Double? {
        RadioAltitude.height(altitudeFt: flightData.altitudeFt, groundFt: groundElevationFt)
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
            drawRadioHeight(ctx)
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
        let pitchOffset = PFD.horizonOffset(pitch: flightData.pitchDeg)
        func onSphere(_ base: GraphicsContext) -> GraphicsContext {
            var sphere = base
            sphere.translateBy(x: center.x, y: center.y)
            sphere.rotate(by: .degrees(-flightData.rollDeg))
            sphere.translateBy(x: 0, y: pitchOffset)
            return sphere
        }

        // Sky and ground fill the whole window.
        let sphere = onSphere(ctx)
        let ext: CGFloat = 400
        sphere.fill(Path(CGRect(x: -ext, y: -ext, width: 2 * ext, height: ext)),
                    with: .color(EFIS.sky))
        sphere.fill(Path(CGRect(x: -ext, y: 0, width: 2 * ext, height: ext)),
                    with: .color(EFIS.ground))
        sphere.line(from: CGPoint(x: -ext, y: 0), to: CGPoint(x: ext, y: 0), .white, width: Style.medium)

        // The horizon line is a heading scale too: a short mark under it at
        // every 10° of heading, where the heading tape has its long marks.
        let heading = flightData.headingDeg
        var mark = ((heading - 40) / 10).rounded(.up) * 10
        while mark <= heading + 40 {
            let x = CGFloat(mark - heading) * PFD.headingScale
            sphere.line(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: PFD.horizonHeadingMarkLength),
                        .white, width: Style.thin)
            mark += 10
        }

        // The pitch scale only between the band's lines. The lower one is
        // the ground reference, rising to the horizon line near the ground.
        let (lower, lowerIsHorizon) = groundReference
        var band = ctx
        band.clip(to: Path(CGRect(x: 0, y: PFD.pitchBandTop, width: PFD.canvas,
                                  height: max(0, lower - PFD.pitchBandTop))))
        let ladder = onSphere(band)

        // Pitch ladder. Each rung sits at its own angle's horizon offset, so the
        // rungs compress at high attitudes exactly as the horizon does.
        for rung in PFD.pitchLadder {
            let y = -PFD.horizonOffset(pitch: rung.deg)
            ladder.line(from: CGPoint(x: -rung.halfWidth, y: y),
                        to: CGPoint(x: rung.halfWidth, y: y), .white, width: Style.thin)
            if rung.labelled {
                let text = "\(abs(Int(rung.deg)))"
                let gap: CGFloat = 3.8
                ladder.digits(text, at: CGPoint(x: -rung.halfWidth - gap, y: y), size: Style.scaleType, .white)
                ladder.digits(text, at: CGPoint(x: rung.halfWidth + gap, y: y), size: Style.scaleType, .white)
            }
        }

        // The band's lines: fixed across the window, level whatever the bank.
        // On the ground the lower one is the horizon line itself.
        for y in lowerIsHorizon ? [PFD.pitchBandTop] : [PFD.pitchBandTop, lower] {
            let half = PFD.windowHalfWidth(atY: y) - PFD.pitchBandLineInset
            ctx.line(from: CGPoint(x: center.x - half, y: y), to: CGPoint(x: center.x + half, y: y),
                     .white, width: Style.medium)
        }

        drawFlightDirector(ctx)
    }

    /// Height of the lower band line: at the band's foot, or — below 570 ft
    /// radio height — that far below the horizon line where it crosses the
    /// centre of the window, so it closes on the horizon line evenly through
    /// the last 570 ft and meets it on touchdown. With it, whether it has
    /// reached the horizon line, which then bounds the scale on its own.
    private var groundReference: (y: CGFloat, isHorizon: Bool) {
        guard let height = radioHeightFt, height < PFD.groundReferenceCeilingFt else {
            return (PFD.pitchBandBottom, false)
        }
        let roll = flightData.rollDeg * .pi / 180
        let horizonY = PFD.horizonCenter.y
            + PFD.horizonOffset(pitch: flightData.pitchDeg) / CGFloat(max(0.3, cos(roll)))
        let offset = CGFloat(max(0, height - PFD.groundReferenceContactFt)) * PFD.groundReferenceScale
        let y = (horizonY + offset).clampedTo(PFD.pitchBandTop + 1...PFD.pitchBandBottom)
        return (y, offset < PFD.groundReferenceMergeOffset && y == horizonY + offset)
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

    /// Radio height below 2500 ft: green digits, no frame, centred under the
    /// aircraft symbol in the window's own section below the pitch band —
    /// 10 ft steps above 50 ft, 5 ft to 10 ft, then single feet. With no decision height entered (there is
    /// none to enter here) it turns amber at and below 400 ft.
    private func drawRadioHeight(_ context: GraphicsContext) {
        guard let height = radioHeightFt else { return }
        let shown = RadioAltitude.airbusDisplayed(height)
        context.digits("\(shown)", at: PFD.radioHeightCenter, size: PFD.radioHeightType,
                       shown <= RadioAltitude.airbusAmberBelowFt ? EFIS.amber : EFIS.green,
                       weight: .bold)
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

        // Fixed zero-bank reference: a triangle above the arc, pointing down,
        // its apex on the arc.
        let i = PFD.bankIndex
        context.stroke(triangle(apex: point(0, radius), baseY: center.y - radius - i.referenceHeight,
                                halfWidth: i.referenceHalfWidth),
                       with: .color(EFIS.yellow), lineWidth: i.lineWidth)

        // Roll index and sideslip index, turning with the horizon: a triangle
        // under the arc pointing up, its apex on the arc — so at wings level
        // the two triangles meet tip to tip — and under it, after a small
        // gap, a trapezoid continuing the triangle's sides, so the two read
        // as one triangle cut across.
        var rolled = context
        rolled.translateBy(x: center.x, y: center.y)
        rolled.rotate(by: .degrees(-flightData.rollDeg))
        rolled.translateBy(x: -center.x, y: -center.y)

        let apexY = center.y - radius
        let slope = i.rollHalfWidth / i.rollHeight
        rolled.stroke(triangle(apex: point(0, radius), baseY: apexY + i.rollHeight, halfWidth: i.rollHalfWidth),
                      with: .color(EFIS.yellow), lineWidth: i.lineWidth)

        // No yaw sensor on a phone, so the sideslip index stays centred under
        // the roll index, as it is in coordinated flight.
        let slipTop = apexY + i.rollHeight + i.slipGap, slipBottom = slipTop + i.slipHeight
        var slip = Path()
        slip.move(to: CGPoint(x: center.x - (slipTop - apexY) * slope, y: slipTop))
        slip.addLine(to: CGPoint(x: center.x + (slipTop - apexY) * slope, y: slipTop))
        slip.addLine(to: CGPoint(x: center.x + (slipBottom - apexY) * slope, y: slipBottom))
        slip.addLine(to: CGPoint(x: center.x - (slipBottom - apexY) * slope, y: slipBottom))
        slip.closeSubpath()
        rolled.stroke(slip, with: .color(EFIS.yellow), lineWidth: i.lineWidth)
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

        // Speed target: an open triangle just outboard of the tape, its apex
        // on the scale at the target — cyan when selected, magenta when
        // managed — or the value in the same colour above or below the tape
        // when the target is off the scale.
        if let target = speedTarget {
            let value = target.value * unit
            let color = target.isManaged ? EFIS.magenta : EFIS.cyan
            let sy = y(for: value)
            if sy < tape.minY {
                context.digits("\(Int(value.rounded()))", at: CGPoint(x: tape.midX, y: tape.minY - 2.0),
                               size: Style.speedType, color, weight: .bold)
            } else if sy > tape.maxY {
                context.digits("\(Int(value.rounded()))", at: CGPoint(x: tape.midX, y: tape.maxY + 1.9),
                               size: Style.speedType, color, weight: .bold)
            } else {
                var bug = Path()
                bug.move(to: CGPoint(x: tape.maxX + 0.15, y: sy))
                bug.addLine(to: CGPoint(x: tape.maxX + 2.7, y: sy - 1.75))
                bug.addLine(to: CGPoint(x: tape.maxX + 2.7, y: sy + 1.75))
                bug.closeSubpath()
                context.stroke(bug, with: .color(color), lineWidth: Style.medium)
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

        // As on the real scale: a graduation every 100 ft on the outboard
        // edge, and every 500 ft the hundreds in three digits, set from the
        // inboard edge. The level-off target writes its own value in its
        // colour, so the white one under it is left out.
        let target = altitudeTarget
        let visible = Double(tape.height / PFD.altScale) / 2
        var value = ((altitude - visible) / 100).rounded(.down) * 100
        while value <= altitude + visible {
            let ty = y(for: value)
            clipped.line(from: CGPoint(x: tape.maxX - PFD.altTickLength, y: ty),
                         to: CGPoint(x: tape.maxX, y: ty),
                         .white, width: Style.thin)
            if value.truncatingRemainder(dividingBy: 500) == 0, abs(value - target.value) >= 50 {
                clipped.digits(String(format: "%03d", Int(value / 100)),
                               at: CGPoint(x: PFD.altLabelX, y: ty),
                               size: Style.scaleType, .white, anchor: .leading)
            }
            value += 100
        }

        drawAltitudeTarget(context, y: y)

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

    /// The level-off target on the scale, as on the real PFD: a tall,
    /// narrow box over the inboard part of the tape, notched on its inboard
    /// edge where it points at the graduation, with the target's hundreds
    /// in the scale's type on a black band — cyan for the FCU
    /// altitude, magenta for a constraint the managed climb or descent will
    /// level at. It is about twice the readout window's height, so level at
    /// the target its top and bottom stand clear above and below the
    /// window, which covers its middle. Off the scale it gives way to the
    /// value above or below the tape (see ``drawOfftapeReadouts``).
    private func drawAltitudeTarget(_ context: GraphicsContext, y: (Double) -> CGFloat) {
        let tape = PFD.altTape
        let target = altitudeTarget
        let ty = y(target.value)
        let half = PFD.altTargetHalfHeight
        guard ty + half > tape.minY, ty - half < tape.maxY else { return }
        let color = target.isManaged ? EFIS.magenta : EFIS.cyan

        var ctx = context
        ctx.clip(to: Path(CGRect(x: tape.minX - 2, y: tape.minY, width: tape.width + 2, height: tape.height)))
        let notch = PFD.altTargetNotch
        let left = tape.minX - PFD.altTargetOverhang
        // The value is right-aligned near the tape's outboard edge; the box
        // ends just short of its thousands digit, so only a ten-thousands
        // digit falls inside it.
        let advance = Style.scaleType * 0.6
        let valueRight = tape.maxX - 0.3
        let right = valueRight - 2 * advance - 0.15
        var box = Path()
        box.move(to: CGPoint(x: left, y: ty - half))
        box.addLine(to: CGPoint(x: right, y: ty - half))
        box.addLine(to: CGPoint(x: right, y: ty + half))
        box.addLine(to: CGPoint(x: left, y: ty + half))
        box.addLine(to: CGPoint(x: left, y: ty + notch))
        box.addLine(to: CGPoint(x: left + notch, y: ty))
        box.addLine(to: CGPoint(x: left, y: ty - notch))
        box.closeSubpath()
        ctx.stroke(box, with: .color(color), lineWidth: Style.medium)
        // The value sits on a black band across the tape, the readout
        // window's height, as the readout's digits do. It lies over the
        // box, so the box's outboard edge breaks off at the band; the
        // notched edge stands proud of the tape and stays whole.
        ctx.fill(Path(CGRect(x: tape.minX, y: ty - PFD.altWindowHalfHeight,
                             width: tape.width, height: 2 * PFD.altWindowHalfHeight)),
                 with: .color(EFIS.background))

        // The value in the scale's own type, hundreds of feet without
        // leading zeros, right-aligned.
        let hundreds = Int((abs(target.value) / 100).rounded())
        ctx.digits("\(hundreds)", at: CGPoint(x: valueRight, y: ty),
                   size: Style.scaleType, color, anchor: .trailing)
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
        let digitWindow = CGRect(x: tape.minX, y: centerY - PFD.altWindowHalfHeight,
                                 width: tape.width, height: 2 * PFD.altWindowHalfHeight)
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
        func slot(_ index: Int) -> CGPoint {
            CGPoint(x: PFD.altDigitSlotX(index), y: centerY)
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
        // The drum rolls continuously with the altitude: each 20 ft mark
        // reaches the index as the altitude passes it.
        let fraction = CGFloat(position - base)

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
            // Lower when the speed target's value sits under the tape.
            let speed = flightData.groundSpeedKts
            let targetBelow = speedTarget.map {
                CGFloat(speed - $0.value) * CGFloat(flightData.speedUnit.perKnot) * PFD.speedScale
                    > PFD.tapeHalfHeight
            } ?? false
            context.digits(String(format: ".%03d", Int((flightData.machNumber * 1000).rounded())),
                           at: CGPoint(x: PFD.speedTape.midX, y: targetBelow ? below + 1.6 : below),
                           size: Style.annunciationType,
                           EFIS.green, weight: .bold)
        }

        // The level-off target, when it is off the scale: its value above
        // the tape when higher, below it when lower — a flight level under
        // STD, feet under QNH — in the target's colour.
        let target = altitudeTarget
        let offset = CGFloat(target.value - flightData.altitudeFt) * PFD.altScale
        if abs(offset) > PFD.tapeHalfHeight {
            let text = flightData.isStandardBaro
                ? "FL" + String(format: "%03d", Int((target.value / 100).rounded()))
                : "\(Int(target.value.rounded()))"
            context.digits(text, at: CGPoint(x: alt.midX + 1.9, y: offset > 0 ? above : alt.maxY + 2.4),
                           size: 4.15, target.isManaged ? EFIS.magenta : EFIS.cyan, weight: .bold)
        }

        // The baro reference, under the place the target takes below the tape.
        let baroY = alt.maxY + 6.6
        if flightData.isStandardBaro {
            context.digits("STD", at: CGPoint(x: alt.midX + 1.9, y: baroY), size: Style.annunciationType,
                           EFIS.cyan, weight: .bold)
        } else {
            context.digits("QNH", at: CGPoint(x: alt.midX - 2.5, y: baroY), size: 3.8, .white)
            context.digits("1013", at: CGPoint(x: alt.midX + 5, y: baroY), size: Style.annunciationType,
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

        // Armed ALT: cyan toward the FCU altitude, magenta toward a constraint.
        let altArmedColor = altitudeTarget.isManaged ? EFIS.magenta : EFIS.cyan
        var vertical: FMAEntry
        var verticalArmed: FMAEntry = ("", EFIS.cyan)
        if guidance.isGlideslopeCaptured {
            vertical = ("G/S", EFIS.green)
        } else if abs(error) < 250 {
            vertical = (abs(vs) < 200 ? "ALT CRZ" : "ALT*", EFIS.green)
        } else if let target = af.selectedVerticalSpeedFpm {
            vertical = (String(format: "V/S %+d", Int(target)), EFIS.green)
            verticalArmed = ("ALT", altArmedColor)
        } else if vs > 200 {
            vertical = ("CLB", EFIS.green)
            verticalArmed = (error > 0 ? "ALT" : "", altArmedColor)
        } else if vs < -200 {
            vertical = ("DES", EFIS.green)
            verticalArmed = (error < 0 ? "ALT" : "", altArmedColor)
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
    private var speedTarget: PFDTarget? {
        PFDTargets.speed(autoFlight: autoFlight, isRoad: routePlanner.transportMode.isRoad,
                         roadLimitKts: speedLimits.limitKts, altitudeFt: flightData.altitudeFt)
    }
    private var altitudeTarget: PFDTarget {
        PFDTargets.levelOff(selectedFt: flightData.selectedAltitudeFt, altitudeFt: flightData.altitudeFt,
                            verticalSpeedFpm: flightData.verticalSpeedFpm, autoFlight: autoFlight,
                            routePlanner: routePlanner)
    }
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
