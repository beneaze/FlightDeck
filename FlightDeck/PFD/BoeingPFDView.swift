import SwiftUI

/// Boeing 737NG-style Primary Flight Display.
///
/// Drawn into one 100 × 102 canvas (see ``B737PFD``) and scaled to fit, as
/// the A320 PFD is. The data behind it is the same — the car's speed, height,
/// heading and the route — in the 737's dress: a rounded attitude frame with
/// the bank scale over the sphere, grey tapes with odometer readouts, a
/// compass arc at the foot, magenta MCP targets and the three-box flight mode
/// annunciator. Sizes not owned by the layout spec are the ``Style``
/// constants below, in the same units.
struct BoeingPFDView: View {
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

    var profile: AircraftProfile = .b737

    /// Stroke widths and type sizes, in canvas units.
    private enum Style {
        static let thin: CGFloat = 0.3
        static let line: CGFloat = 0.4
        static let medium: CGFloat = 0.5
        static let heavy: CGFloat = 0.6
        static let flightDirector: CGFloat = 0.7
        static let small: CGFloat = 2.65
        static let label: CGFloat = 3.5
        static let scale: CGFloat = 3.7
        static let target: CGFloat = 4.5
        static let readout: CGFloat = 5.3
    }

    private var guidance: Guidance { Guidance(flightData: flightData, routePlanner: routePlanner) }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / B737PFD.width, size.height / B737PFD.height)
            var ctx = context
            ctx.translateBy(x: (size.width - B737PFD.width * scale) / 2,
                            y: (size.height - B737PFD.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.clip(to: Path(CGRect(x: 0, y: 0, width: B737PFD.width, height: B737PFD.height)))

            drawAttitude(ctx)
            drawDeviationScales(ctx)
            drawSpeedTape(ctx)
            drawAltitudeTape(ctx)
            drawVerticalSpeed(ctx)
            drawCompass(ctx)
            drawFMA(ctx)
            drawCornerBlocks(ctx)
        }
        .background(Boeing.background)
    }

    // MARK: - Attitude

    private func drawAttitude(_ context: GraphicsContext) {
        let c = B737PFD.horizonCenter
        let frame = Path(roundedRect: B737PFD.attitudeFrame,
                         cornerRadius: B737PFD.attitudeCornerRadius)

        // The sphere fills the whole frame; the bank scale is drawn over it,
        // so a steep nose-down attitude leaves no sky behind the scale.
        var sphere = context
        sphere.clip(to: frame)

        // Linear all the way to ±90°.
        let pitchOffset = CGFloat(flightData.pitchDeg.clamped(to: -90...90)) * B737PFD.pixelsPerDegreePitch
        sphere.translateBy(x: c.x, y: c.y)
        sphere.rotate(by: .degrees(-flightData.rollDeg))
        sphere.translateBy(x: 0, y: pitchOffset)

        let ext: CGFloat = 250
        sphere.fill(Path(CGRect(x: -ext, y: -ext, width: 2 * ext, height: ext)),
                    with: .color(Boeing.sky))
        sphere.fill(Path(CGRect(x: -ext, y: 0, width: 2 * ext, height: ext)),
                    with: .color(Boeing.ground))
        sphere.line(from: CGPoint(x: -ext, y: 0), to: CGPoint(x: ext, y: 0), Boeing.white, width: Style.line)

        // Pitch ladder to ±90°: long rungs every 10° with the angle at both
        // ends, medium at 5°, short at 2.5°.
        for deg in stride(from: 2.5, through: 90, by: 2.5) {
            let tens = deg.truncatingRemainder(dividingBy: 10) == 0
            let fives = deg.truncatingRemainder(dividingBy: 5) == 0
            let half: CGFloat = tens ? 10.6 : (fives ? 4.9 : 2.45)
            for sign in [1.0, -1.0] {
                let y = -CGFloat(deg * sign) * B737PFD.pixelsPerDegreePitch
                sphere.line(from: CGPoint(x: -half, y: y), to: CGPoint(x: half, y: y),
                            Boeing.white, width: Style.line)
                if tens {
                    let label = "\(Int(deg))"
                    sphere.boeingText(label, at: CGPoint(x: -half - 3.05, y: y), size: Style.label)
                    sphere.boeingText(label, at: CGPoint(x: half + 3.05, y: y), size: Style.label)
                }
            }
        }

        drawBankScale(context)
        drawAircraftSymbol(context)
        // The command bars lie over the aircraft symbol.
        drawFlightDirector(context, pitchOffset: pitchOffset)
    }

    /// Bank graduations over the sphere: 10°, 20°, 30°, 45° and 60° either
    /// side, a filled zero index pointing down from the frame, and the roll
    /// pointer and slip indicator turning with the horizon.
    private func drawBankScale(_ context: GraphicsContext) {
        let c = B737PFD.horizonCenter
        let r = B737PFD.bankScaleRadius

        // 30° is the longest mark, 45° the shortest.
        for (angle, length) in [(10.0, 2.2), (20, 2.2), (30, 3.5), (45, 1.8), (60, 2.45)] {
            for sign in [1.0, -1.0] {
                context.line(from: polarPoint(c, angle * sign, r),
                             to: polarPoint(c, angle * sign, r + CGFloat(length)),
                             Boeing.white, width: Style.medium)
            }
        }
        // Zero index: a filled triangle from the frame's top edge down to the
        // scale.
        let frameTop = c.y - B737PFD.frameHalfHeight
        context.polygon([CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - 3.05, y: frameTop),
                         CGPoint(x: c.x + 3.05, y: frameTop)], fill: Boeing.white)

        var rolled = context
        rolled.translateBy(x: c.x, y: c.y)
        rolled.rotate(by: .degrees(-flightData.rollDeg))
        // Roll pointer just inside the scale, with the slip box under it.
        let pointerTip = -(r - 0.5)
        rolled.polygon([CGPoint(x: 0, y: pointerTip), CGPoint(x: -2.85, y: pointerTip + 2.9),
                        CGPoint(x: 2.85, y: pointerTip + 2.9)],
                       fill: Boeing.background, stroke: Boeing.white, lineWidth: Style.line)
        // No yaw sensor on a phone: the slip indicator stays under the pointer.
        rolled.stroke(Path(CGRect(x: -2.65, y: pointerTip + 3.5, width: 5.3, height: 2.0)),
                      with: .color(Boeing.white), lineWidth: Style.line)
    }

    /// Magenta cross bars. With no autopilot to follow they command the flight
    /// path back to the selected altitude and the guidance course.
    private func drawFlightDirector(_ context: GraphicsContext, pitchOffset: CGFloat) {
        guard flightData.autoFlight.flightDirector else { return }
        let c = B737PFD.horizonCenter
        let pitchCommand = guidance.pitchCommandDeg
        let reach = B737PFD.frameHalfHeight * 0.6
        let barY = c.y + (pitchOffset - CGFloat(pitchCommand) * B737PFD.pixelsPerDegreePitch)
            .clampedTo(-reach...reach)
        let barX = c.x + CGFloat(guidance.courseError.clamped(to: -45...45) * 0.35)
        let half = B737PFD.frameHalfWidth * 0.59

        context.line(from: CGPoint(x: c.x - half, y: barY), to: CGPoint(x: c.x + half, y: barY),
                     Boeing.magenta, width: Style.flightDirector)
        context.line(from: CGPoint(x: barX, y: c.y - half), to: CGPoint(x: barX, y: c.y + half),
                     Boeing.magenta, width: Style.flightDirector)
    }

    /// The fixed aircraft symbol: two white-outlined black brackets, a bar
    /// with a short leg hanging from its inboard end, and a small centre box.
    private func drawAircraftSymbol(_ context: GraphicsContext) {
        let c = B737PFD.horizonCenter
        let outer: CGFloat = 20.5, inner: CGFloat = 9.55, bar: CGFloat = 1.6
        let top = c.y - 0.2, legBottom = c.y + 3.9
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            func p(_ dx: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + s * dx, y: y) }
            context.polygon([
                p(outer, top), p(inner, top), p(inner, legBottom),
                p(inner + bar, legBottom), p(inner + bar, top + bar), p(outer, top + bar),
            ], fill: Boeing.background, stroke: Boeing.white, lineWidth: Style.line)
        }
        let side: CGFloat = 2.0
        let square = Path(CGRect(x: c.x - side / 2, y: top, width: side, height: side))
        context.fill(square, with: .color(Boeing.background))
        context.stroke(square, with: .color(Boeing.white), lineWidth: Style.line)
    }

    // MARK: - Deviation scales

    /// Localiser dots under the attitude frame and glideslope dots beside it,
    /// driven — as on the A320 PFD — by the guidance course and a 3° path to
    /// the destination.
    private func drawDeviationScales(_ context: GraphicsContext) {
        guard guidance.showsDeviationScales else { return }
        let c = B737PFD.horizonCenter
        let frame = B737PFD.attitudeFrame
        let spacing: CGFloat = 7.1

        let locY = frame.maxY + 2.2
        let gsX = frame.maxX + 1.5
        for n: CGFloat in [-2, -1, 1, 2] {
            drawDot(context, at: CGPoint(x: c.x + n * spacing, y: locY))
            drawDot(context, at: CGPoint(x: gsX, y: B737PFD.tapeCenterY + n * spacing))
        }
        context.fill(Path(CGRect(x: c.x - 0.3, y: locY - 1.4, width: 0.6, height: 2.8)),
                     with: .color(Boeing.white))
        context.fill(Path(CGRect(x: gsX - 1.4, y: B737PFD.tapeCenterY - 0.3, width: 2.8, height: 0.6)),
                     with: .color(Boeing.white))

        let loc = (guidance.localizerError / 10).clamped(to: -1...1)
        drawDiamond(context, at: CGPoint(x: c.x + CGFloat(loc) * 2 * spacing, y: locY))
        if let deviation = guidance.glideDeviation {
            drawDiamond(context, at: CGPoint(x: gsX, y: B737PFD.tapeCenterY - CGFloat(deviation) * 2 * spacing))
        }
    }

    private func drawDot(_ context: GraphicsContext, at p: CGPoint) {
        let r: CGFloat = 0.7
        context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(Boeing.white), lineWidth: Style.thin)
    }

    private func drawDiamond(_ context: GraphicsContext, at p: CGPoint) {
        context.polygon([CGPoint(x: p.x, y: p.y - 1.8), CGPoint(x: p.x + 1.2, y: p.y),
                         CGPoint(x: p.x, y: p.y + 1.8), CGPoint(x: p.x - 1.2, y: p.y)],
                        fill: Boeing.magenta)
    }

    // MARK: - Speed tape

    private func drawSpeedTape(_ context: GraphicsContext) {
        let tape = B737PFD.speedTape
        let cy = B737PFD.tapeCenterY
        let unit = flightData.speedUnit.perKnot
        let speed = flightData.groundSpeedKts * unit

        context.fill(Path(tape), with: .color(Boeing.grey))
        func y(_ value: Double) -> CGFloat { cy - CGFloat(value - speed) * B737PFD.pixelsPerKnot }

        var clipped = context
        clipped.clip(to: Path(tape))

        // Graduations every 10 on the inboard edge, the value every 20.
        let visible = Double(tape.height / B737PFD.pixelsPerKnot) / 2 + 10
        var value = ((speed - visible) / 10).rounded(.down) * 10
        while value <= speed + visible {
            if value >= 30 {
                let ty = y(value)
                clipped.line(from: CGPoint(x: tape.maxX - 2.2, y: ty), to: CGPoint(x: tape.maxX, y: ty),
                             Boeing.white, width: Style.line)
                if value.truncatingRemainder(dividingBy: 20) == 0 {
                    clipped.boeingText("\(Int(value))", at: CGPoint(x: tape.maxX - 4.0, y: ty),
                                       size: Style.scale, anchor: .trailing)
                }
            }
            value += 10
        }

        // Maximum speed: the posted limit, or VMO with none known. A red and
        // black barber pole rises from it along the tape's inboard edge.
        // In plane mode the tape shows ground speed, not airspeed, so a
        // maximum airspeed has nothing to mark and no pole is drawn.
        let vmax = (speedLimits.limitKts ?? profile.vmo) * unit
        let poleFoot = y(vmax)
        if routePlanner.transportMode.isRoad, poleFoot > tape.minY {
            let poleWidth: CGFloat = 1.4, block: CGFloat = 1.6
            let x = tape.maxX - poleWidth
            clipped.fill(Path(CGRect(x: x, y: tape.minY, width: poleWidth, height: max(0, poleFoot - tape.minY))),
                         with: .color(Boeing.background))
            var edge = poleFoot
            while edge > tape.minY {
                clipped.fill(Path(CGRect(x: x, y: edge - block, width: poleWidth, height: block)),
                             with: .color(Boeing.red))
                edge -= 2 * block
            }
        }

        // Speed trend: a green arrow to where the speed will be in 10 s.
        if flightData.isSpeedTrendShown {
            let trend = flightData.speedTrendKts * unit
            let x = tape.maxX - 2.0
            let tip = (cy - CGFloat(trend) * B737PFD.pixelsPerKnot)
                .clampedTo(tape.minY + 1.6...tape.maxY - 1.6)
            let back: CGFloat = trend > 0 ? 1.8 : -1.8
            clipped.line(from: CGPoint(x: x, y: cy), to: CGPoint(x: x, y: tip), Boeing.green, width: Style.medium)
            clipped.polygon([CGPoint(x: x, y: tip), CGPoint(x: x - 1.0, y: tip + back),
                             CGPoint(x: x + 1.0, y: tip + back)], fill: Boeing.green)
        }

        // MCP speed bug — the MCP speed when one is selected, else the
        // speed limit when one is known — a magenta pentagon on the inboard
        // edge, parked at the tape's end when off it.
        if let limit = flightData.autoFlight.selectedSpeedKts ?? speedLimits.limitKts {
            let half: CGFloat = 1.8
            let by = y(limit * unit).clampedTo(tape.minY + half...tape.maxY - half)
            let tip = tape.maxX - 0.2
            context.polygon([CGPoint(x: tip, y: by), CGPoint(x: tip + 2.45, y: by - half),
                             CGPoint(x: tip + 4.9, y: by - half), CGPoint(x: tip + 4.9, y: by + half),
                             CGPoint(x: tip + 2.45, y: by + half)],
                            stroke: Boeing.magenta, lineWidth: Style.medium)
            context.boeingText("\(Int((limit * unit).rounded()))",
                               at: CGPoint(x: tape.midX + 1.4, y: B737PFD.tapeTop - 3.6),
                               size: Style.target, Boeing.magenta)
        }

        // The readout: an odometer in a black box whose outline runs out
        // into a pointer onto the scale — one continuous shape, no edge
        // across the pointer's base.
        let box = CGRect(x: 0.4, y: cy - 4.3, width: 10.2, height: 8.6)
        let notch: CGFloat = 1.6
        context.polygon([
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: cy - notch), CGPoint(x: box.maxX + notch, y: cy),
            CGPoint(x: box.maxX, y: cy + notch), CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ], fill: Boeing.background, stroke: Boeing.white, lineWidth: Style.line)
        let pitch: CGFloat = 2.65
        drawOdometer(context, value: speed,
                     columns: (0..<3).map { box.minX + 2.45 + CGFloat($0) * pitch },
                     centerY: cy, rowHeight: 6.9, size: Style.readout,
                     window: box.insetBy(dx: 0.2, dy: 0.4))
    }

    /// Three-wheel odometer: the units wheel turns continuously, each higher
    /// wheel only as the one below it passes from 9 to 0. Leading zeros are
    /// blank. The row pitch exceeds the window, so a neighbouring figure only
    /// shows while a wheel is turning.
    private func drawOdometer(_ context: GraphicsContext, value: Double, columns: [CGFloat],
                              centerY: CGFloat, rowHeight: CGFloat, size: CGFloat, window: CGRect) {
        var ctx = context
        ctx.clip(to: Path(window))
        let v = max(0, value)
        for (place, x) in columns.reversed().enumerated() {
            let p = pow(10.0, Double(place))
            let wheel = v / p
            let base = wheel.rounded(.down)
            let lower = v.truncatingRemainder(dividingBy: p)
            let fraction = place == 0 ? wheel - base : max(0, lower - (p - 1))
            for step in -1...1 {
                let shown = Int(base) + step
                guard shown > 0 || place == 0 else { continue }
                ctx.boeingText("\(((shown % 10) + 10) % 10)",
                               at: CGPoint(x: x, y: centerY - (CGFloat(step) - CGFloat(fraction)) * rowHeight),
                               size: size)
            }
        }
    }

    // MARK: - Altitude tape

    private func drawAltitudeTape(_ context: GraphicsContext) {
        let tape = B737PFD.altitudeTape
        let cy = B737PFD.tapeCenterY
        let altitude = flightData.altitudeFt

        context.fill(Path(tape), with: .color(Boeing.grey))
        func y(_ feet: Double) -> CGFloat { cy - CGFloat(feet - altitude) * B737PFD.pixelsPerFoot }

        // The thousand-foot graduations reach past the tape's edge.
        let overhang: CGFloat = 1.0
        var clipped = context
        clipped.clip(to: Path(CGRect(x: tape.minX - overhang - 0.2, y: tape.minY,
                                     width: tape.width + overhang + 0.2, height: tape.height)))

        let visible = Double(tape.height / B737PFD.pixelsPerFoot) / 2 + 100
        var value = ((altitude - visible) / 100).rounded(.down) * 100
        while value <= altitude + visible {
            let ty = y(value)
            let thousand = value.truncatingRemainder(dividingBy: 1_000) == 0
            clipped.line(from: CGPoint(x: thousand ? tape.minX - overhang : tape.minX, y: ty),
                         to: CGPoint(x: tape.minX + 2.25, y: ty),
                         Boeing.white, width: thousand ? Style.heavy : Style.line)
            if value.truncatingRemainder(dividingBy: 200) == 0 {
                // Thousands in large figures, the hundreds smaller after them,
                // the whole label right-aligned just inside the tape's edge so
                // a fifth digit widens it leftward instead of cutting it off.
                let thousands = Int(abs(value)) / 1_000
                let hundreds = Int(abs(value)) % 1_000
                let right = tape.maxX - 0.4
                let small = String(format: "%03d", hundreds)
                let smallWidth = context.boeingTextWidth(small, size: 2.85)
                clipped.boeingText(small, at: CGPoint(x: right, y: ty + 0.2), size: 2.85, anchor: .trailing)
                if thousands > 0 {
                    clipped.boeingText("\(thousands)", at: CGPoint(x: right - smallWidth - 0.2, y: ty),
                                       size: 4.1, anchor: .trailing)
                }
                if thousand {
                    // The thousand bars frame the label above and below.
                    for dy: CGFloat in [-2.45, 2.45] {
                        clipped.line(from: CGPoint(x: tape.minX + 3.5, y: ty + dy),
                                     to: CGPoint(x: tape.maxX, y: ty + dy),
                                     Boeing.white, width: Style.line)
                    }
                }
            }
            value += 100
        }

        // MCP altitude bug: a magenta bracket on the inboard edge, notched
        // where it points at the scale, parked at the tape's end when the
        // target is off it.
        let half: CGFloat = 4.9, notch: CGFloat = 1.2
        let by = y(flightData.selectedAltitudeFt).clampedTo(tape.minY + half...tape.maxY - half)
        let left = tape.minX - 1.8, right = tape.minX + 5.5
        context.polygon([
            CGPoint(x: left, y: by - half), CGPoint(x: right, y: by - half), CGPoint(x: right, y: by + half),
            CGPoint(x: left, y: by + half), CGPoint(x: left, y: by + notch), CGPoint(x: left + notch, y: by),
            CGPoint(x: left, y: by - notch),
        ], stroke: Boeing.magenta, lineWidth: Style.medium)

        // The ground: an amber band down the tape's inboard edge from the
        // terrain elevation, with a line across the tape at the ground.
        if let ground = groundElevationFt {
            let gy = y(ground)
            if gy < tape.maxY {
                let top = max(gy, tape.minY)
                clipped.fill(Path(CGRect(x: tape.minX, y: top, width: 1.6, height: tape.maxY - top)),
                             with: .color(Boeing.amber))
                clipped.line(from: CGPoint(x: tape.minX, y: gy), to: CGPoint(x: tape.maxX, y: gy),
                             Boeing.amber, width: Style.medium)
            }
        }

        drawAltitudeReadout(context, altitude: altitude)

        // MCP altitude above the tape, baro reference below it.
        context.boeingText("\(Int(flightData.selectedAltitudeFt))",
                           at: CGPoint(x: tape.midX + 3.1, y: B737PFD.tapeTop - 3.6),
                           size: Style.target, Boeing.magenta)
        let baroY = tape.maxY + 5.0
        // Height above the ground under the aircraft, in flight.
        if let ground = groundElevationFt {
            let height = max(0, flightData.altitudeFt - ground)
            context.boeingText("HGT", at: CGPoint(x: tape.minX - 0.6, y: baroY + 4.6), size: Style.small,
                               anchor: .leading)
            context.boeingText("\(Int((height / 10).rounded()) * 10)",
                               at: CGPoint(x: tape.maxX + 1.2, y: baroY + 4.6), size: Style.scale,
                               height < 2_500 ? Boeing.amber : Boeing.white, anchor: .trailing)
        }

        if flightData.isStandardBaro {
            context.boeingText("STD", at: CGPoint(x: tape.midX, y: baroY), size: 4.1, Boeing.green)
        } else {
            context.boeingText("1013", at: CGPoint(x: tape.midX - 0.4, y: baroY), size: 4.1, Boeing.green,
                               anchor: .trailing)
            context.boeingText("HPA", at: CGPoint(x: tape.midX + 0.4, y: baroY + 0.2), size: Style.small,
                               Boeing.green, anchor: .leading)
        }
    }

    /// The altitude readout: thousands and hundreds on odometer wheels, the
    /// last two digits on a 20 ft drum, in a box pointing onto the scale.
    private func drawAltitudeReadout(_ context: GraphicsContext, altitude: Double) {
        let cy = B737PFD.tapeCenterY
        // One continuous outline: the left edge runs out into the pointer
        // and back, with no line across the pointer's base.
        let box = CGRect(x: B737PFD.altitudeTape.minX + 3.9, y: cy - 4.5, width: 13.8, height: 9.0)
        let notch: CGFloat = 1.6
        context.polygon([
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.minX, y: cy + notch), CGPoint(x: box.minX - notch, y: cy),
            CGPoint(x: box.minX, y: cy - notch),
        ], fill: Boeing.background, stroke: Boeing.white, lineWidth: Style.line)

        var ctx = context
        ctx.clip(to: Path(box.insetBy(dx: 0.2, dy: 0.4)))

        let absolute = abs(altitude)
        let hundreds = (absolute / 100).rounded(.down)
        let remainder = absolute - hundreds * 100

        // The drum holds each 20 ft value through most of its step and rolls
        // over in the last part, so the current value stays on the index.
        let position = remainder / 20
        let drumBase = position.rounded(.down)
        let raw = position - drumBase
        let drumFraction = raw < 0.7 ? 0 : (raw - 0.7) / 0.3
        for step in -2...2 {
            let index = ((Int(drumBase) + step) % 5 + 5) % 5
            ctx.boeingText(String(format: "%02d", index * 20),
                           at: CGPoint(x: box.minX + 11, y: cy - (CGFloat(step) - CGFloat(drumFraction)) * 6.1),
                           size: Style.scale)
        }

        // The hundreds wheel turns with the drum's 80 → 00 roll, and each
        // higher wheel only while every lower one shows 9.
        let columns: [CGFloat] = (0..<3).map { box.minX + 2.2 + CGFloat($0) * 2.85 }
        var carry = remainder >= 80 ? drumFraction : 0
        for place in 0..<3 {
            let x = columns[2 - place]
            let p = pow(10.0, Double(place))
            let base = Int(hundreds / p)
            for step in -1...1 {
                let shown = base + step
                guard shown > 0 || (place == 0 && shown == 0) else { continue }
                ctx.boeingText("\(((shown % 10) + 10) % 10)",
                               at: CGPoint(x: x, y: cy - (CGFloat(step) - CGFloat(carry)) * 6.9),
                               size: Style.readout)
            }
            carry = base % 10 == 9 ? carry : 0
        }
    }

    // MARK: - Vertical speed

    private func drawVerticalSpeed(_ context: GraphicsContext) {
        let cy = B737PFD.tapeCenterY
        context.fill(B737PFD.verticalSpeedOutline, with: .color(Boeing.grey))

        // In m/s the 1000/2000/6000 ft/min graduations read 1/2/6 m/s.
        let msMode = flightData.verticalSpeedUnit == .ms
        func offset(_ rate: Double) -> CGFloat {
            B737PFD.verticalSpeedOffset(fpm: msMode ? rate * 1_000 : rate)
        }

        let tickX = B737PFD.verticalSpeedLipX + 0.2
        for (fpm, label) in [(500.0, ""), (1_000, "1"), (1_500, ""), (2_000, "2"), (4_000, ""), (6_000, "6")] {
            for sign in [1.0, -1.0] {
                let ty = cy + B737PFD.verticalSpeedOffset(fpm: fpm * sign)
                context.line(from: CGPoint(x: tickX, y: ty),
                             to: CGPoint(x: tickX + (label.isEmpty ? 1.2 : 2.0), y: ty),
                             Boeing.white, width: Style.line)
                if !label.isEmpty {
                    context.boeingText(label, at: CGPoint(x: B737PFD.verticalSpeedLeft + 1.2, y: ty), size: 3.3)
                }
            }
        }

        // The needle, hinged far off the right edge, its tip on the scale.
        let rate = flightData.verticalSpeedFpm * (msMode ? 0.00508 : 1)
        let tip = CGPoint(x: B737PFD.verticalSpeedLeft + 0.6, y: cy + offset(rate))
        context.line(from: B737PFD.verticalSpeedPivot, to: tip, Boeing.white, width: Style.heavy)

        // Digital rate above the scale climbing, below it descending.
        let showReadout = msMode ? abs(rate) >= 2 : abs(rate) >= 400
        if showReadout {
            let text = msMode
                ? String(format: "%.1f", abs(rate))
                : "\(Int((abs(rate) / 50).rounded()) * 50)"
            let gap = B737PFD.verticalSpeedHalfHeight + 3.7
            context.boeingText(text, at: CGPoint(x: B737PFD.verticalSpeedChamferX - 0.2,
                                                 y: rate > 0 ? cy - gap : cy + gap),
                               size: Style.label)
        }
    }

    // MARK: - Compass

    /// The heading rose: the top of a grey disc centred below the display,
    /// graduated every 5°, with the heading pointer fixed above it, the track
    /// line and the MCP heading bug turning with it.
    private func drawCompass(_ context: GraphicsContext) {
        let c = B737PFD.compassCenter
        let r = B737PFD.compassRadius
        let heading = flightData.headingDeg

        context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(Boeing.grey))

        for deg in stride(from: 0, to: 360, by: 5) {
            let diff = angularDifference(Double(deg), heading)
            guard abs(diff) <= 60 else { continue }
            var tick = context
            tick.translateBy(x: c.x, y: c.y)
            tick.rotate(by: .degrees(diff))
            let tens = deg % 10 == 0
            tick.line(from: CGPoint(x: 0, y: -(r - 0.4)), to: CGPoint(x: 0, y: -(r - (tens ? 1.8 : 1.2))),
                      Boeing.white, width: Style.line)
            if tens {
                let large = deg % 30 == 0
                tick.boeingText("\(deg / 10)", at: CGPoint(x: 0, y: -(r - (large ? 4.5 : 3.7))),
                                size: large ? 4.1 : 2.45)
            }
        }

        // Track line, at the drift angle from the heading.
        var track = context
        track.translateBy(x: c.x, y: c.y)
        track.rotate(by: .degrees(flightData.driftAngleDeg))
        track.line(from: CGPoint(x: 0, y: -(r - 9)), to: CGPoint(x: 0, y: -(r - 0.9)), Boeing.white, width: Style.line)

        // MCP heading bug on the rim: the MCP heading once set, else the
        // guidance course while a route is active, with its value beside
        // the rose.
        let annunciationY = B737PFD.compassTop - 1.2
        if let course = flightData.autoFlight.headingTargetDeg ?? guidance.bearing {
            let diff = angularDifference(course, heading)
            if abs(diff) <= 60 {
                var bug = context
                bug.translateBy(x: c.x, y: c.y)
                bug.rotate(by: .degrees(diff))
                let half: CGFloat = 2.65, inner: CGFloat = 1.4, height: CGFloat = 2.45
                bug.polygon([
                    CGPoint(x: -half, y: -r), CGPoint(x: -half, y: -r - height), CGPoint(x: -inner, y: -r - height),
                    CGPoint(x: 0, y: -r - 0.8), CGPoint(x: inner, y: -r - height), CGPoint(x: half, y: -r - height),
                    CGPoint(x: half, y: -r),
                ], stroke: Boeing.magenta, lineWidth: Style.line)
            }
            let x = c.x - 12.9
            context.boeingText(String(format: "%03d", Int(course.rounded()) % 360),
                               at: CGPoint(x: x, y: annunciationY), size: Style.scale, Boeing.magenta,
                               anchor: .trailing)
            context.boeingText("H", at: CGPoint(x: x + 0.8, y: annunciationY), size: 2.85, Boeing.magenta,
                               anchor: .leading)
        }

        // Heading pointer — a hollow triangle — fixed at the top of the rose,
        // and the MAG reference annunciation level with it, up and to the
        // right where the arc has fallen away beneath.
        context.polygon([CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - 1.6, y: c.y - r - 2.45),
                         CGPoint(x: c.x + 1.6, y: c.y - r - 2.45)],
                        fill: Boeing.background, stroke: Boeing.white, lineWidth: Style.line)
        context.boeingText("MAG", at: CGPoint(x: c.x + 14.1, y: annunciationY), size: 3.05, Boeing.green)
    }

    // MARK: - FMA

    private func drawFMA(_ context: GraphicsContext) {
        let modes = fmaModes
        for (box, mode) in zip(B737PFD.fmaBoxes, modes) {
            context.fill(Path(box), with: .color(Boeing.grey))
            if !mode.active.isEmpty {
                context.boeingText(mode.active, at: CGPoint(x: box.midX, y: box.midY), size: Style.label,
                                   Boeing.green)
            }
            if !mode.armed.isEmpty {
                context.boeingText(mode.armed, at: CGPoint(x: box.midX, y: box.maxY + 2.45), size: Style.small)
            }
        }
        for box in B737PFD.fmaBoxes.dropFirst() {
            context.line(from: CGPoint(x: box.minX, y: box.minY), to: CGPoint(x: box.minX, y: box.maxY),
                         Boeing.white, width: 0.2)
        }

        // AFDS status over the attitude frame: CMD with an autopilot
        // engaged, FD with only the flight director on.
        let af = flightData.autoFlight
        let status = flightData.isDemoMode ? "DEMO"
            : (af.autopilot1 || af.autopilot2) ? "CMD" : af.flightDirector ? "FD" : ""
        if !status.isEmpty {
            context.boeingText(status,
                               at: CGPoint(x: B737PFD.horizonCenter.x, y: B737PFD.attitudeFrame.minY - 2.4),
                               size: Style.label, flightData.isDemoMode ? Boeing.amber : Boeing.green)
        }
    }

    private typealias FMAMode = (active: String, armed: String)

    /// Autothrottle, roll and pitch modes, in the 737's vocabulary.
    private var fmaModes: [FMAMode] {
        let error = flightData.selectedAltitudeFt - flightData.altitudeFt
        let vs = flightData.verticalSpeedFpm
        let routing = routePlanner.destination != nil
        let af = flightData.autoFlight

        let thrust: String
        if !af.autothrust { thrust = "" }
        else if af.selectedSpeedKts != nil { thrust = "MCP SPD" }
        else if vs > 500 { thrust = "N1" }
        else if vs < -500 { thrust = "ARM" }
        else { thrust = speedLimits.limitKts != nil ? "FMC SPD" : "MCP SPD" }

        var pitch: FMAMode
        if guidance.isGlideslopeCaptured {
            pitch = ("G/S", "")
        } else if abs(error) < 250 {
            pitch = (abs(vs) < 200 ? "ALT HOLD" : "ALT ACQ", "")
        } else if af.selectedVerticalSpeedFpm != nil {
            pitch = ("V/S", "")
        } else if abs(vs) > 200 {
            pitch = ("LVL CHG", "")
        } else {
            pitch = ("ALT HOLD", "")
        }
        if af.approachArmed && !guidance.isGlideslopeCaptured { pitch.armed = "G/S" }

        var roll: FMAMode
        if guidance.isLocalizerCaptured { roll = ("VOR/LOC", "") }
        else if af.selectedHeadingDeg != nil || !routing { roll = ("HDG SEL", "") }
        else { roll = ("LNAV", "") }
        if af.isLocalizerArmed && !guidance.isLocalizerCaptured { roll.armed = "VOR/LOC" }

        return [(thrust, ""), roll, pitch]
    }

    // MARK: - Corner blocks

    /// Ground speed under the speed tape — plain text, no frame — and the
    /// destination in the approach-reference slot below it.
    private func drawCornerBlocks(_ context: GraphicsContext) {
        let unit = flightData.speedUnit.perKnot
        let tape = B737PFD.speedTape
        let gsY = tape.maxY + 5.0
        context.boeingText("GS", at: CGPoint(x: 1.2, y: gsY), size: Style.small, anchor: .leading)
        context.boeingText("\(Int((flightData.groundSpeedKts * unit).rounded()))",
                           at: CGPoint(x: tape.maxX - 0.6, y: gsY), size: Style.scale, anchor: .trailing)

        if let destination = routePlanner.destination {
            context.boeingText(destination.name.uppercased().prefix(8).description,
                               at: CGPoint(x: 0.8, y: gsY + 6.3), size: 2.85, anchor: .leading)
            if let distance = routePlanner.distanceToGoNm(from: flightData.location) {
                context.boeingText(String(format: "%.1f NM", distance), at: CGPoint(x: 0.8, y: gsY + 10.0),
                                   size: 2.85, anchor: .leading)
            }
        }
    }
}

#Preview {
    BoeingPFDView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
        .environmentObject(SpeedLimitProvider())
        .environmentObject(FlightPackStore())
        .frame(width: 390, height: 398)
        .background(.black)
}
