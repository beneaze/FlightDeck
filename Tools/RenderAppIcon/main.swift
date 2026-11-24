// Renders the app icon: a miniature of the PFD — FMA, attitude indicator,
// speed, heading and altitude tapes — in the exact geometry and style the display
// itself is drawn with, given an iOS 26 finish (depth shadow, glass sheen,
// lit rims) on top. Compiled together with the app's PFDGeometry.swift and
// EFIS.swift, so the shapes, colours and stroke widths are the display's own,
// not a redrawing of them.
//
//   swiftc -O -o /tmp/render-app-icon \
//       FlightDeck/PFD/PFDGeometry.swift FlightDeck/Style/EFIS.swift \
//       Tools/RenderAppIcon/main.swift
//   /tmp/render-app-icon FlightDeck/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png
//
// The drawing code mirrors the corresponding PFDView.draw… functions with the
// flight data replaced by the constants below; keep them in step if the
// display changes.

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The moment the icon shows: straight and level at 120, heading 085,
/// 1200 ft with a 1500 ft target set, 150 the limit.
enum Icon {
    static let pitchDeg = 0.0
    static let rollDeg = 0.0
    static let speed = 120.0
    static let speedTrend = 9.0
    static let vmax = 150.0
    static let headingDeg = 85.0
    static let trackDeg = 88.0
    static let altitudeFt = 1_200.0
    static let selectedAltitudeFt = 1_500.0

    /// FMA: thrust, vertical, lateral and approach-capability columns, three
    /// rows each, as PFDView.fmaColumns lays them out. The fifth column — the
    /// AP / FD / A-THR engagement status — is left off the icon so the
    /// altitude tape closes the picture on the right.
    static let fmaColumns: [[(text: String, color: Color)]] = [
        [("SPEED", EFIS.green), ("", .white), ("", .white)],
        [("ALT CRZ", EFIS.green), ("", .white), ("", .white)],
        [("NAV", EFIS.green), ("", .white), ("", .white)],
        [("", .white), ("", .white), ("", .white)],
    ]
}

struct AppIconView: View {
    let side: CGFloat = 1024

    var body: some View {
        Canvas { context, size in
            // iOS 26 ground: a deep slate gradient rather than the display's
            // flat black, so the glass edge the system adds has something to
            // catch.
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(
                            Gradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.24),
                                              Color(red: 0.05, green: 0.06, blue: 0.09)]),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // The instrument's extent in display units: the FMA row at the
            // top down to the heading tape, speed tape to the altitude drum.
            let region = CGRect(x: 0, y: PFD.fma.minY, width: PFD.altTape.maxX + 5.6,
                                height: PFD.headingTape.maxY - PFD.fma.minY)
            let scale = min(size.width * 0.84 / region.width, size.height * 0.84 / region.height)

            var lifted = context
            lifted.addFilter(.shadow(color: .black.opacity(0.55), radius: 26, x: 0, y: 14))
            lifted.drawLayer { layer in
                var ctx = layer
                ctx.translateBy(x: size.width / 2 - region.midX * scale,
                                y: size.height / 2 - region.midY * scale)
                ctx.scaleBy(x: scale, y: scale)

                drawHorizon(ctx)
                drawAircraftReference(ctx)
                drawBankScale(ctx)
                drawSpeedTape(ctx)
                drawAltitudeTape(ctx)
                drawHeadingTape(ctx)
                drawFMA(ctx)
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: iOS 26 finish

    /// A tape background as on the display, under a glass sheen and a lit
    /// rim.
    private func fillGlassTape(_ context: GraphicsContext, _ rect: CGRect) {
        context.fill(Path(rect), with: .color(EFIS.tape))
        context.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.18), location: 0),
                             .init(color: .white.opacity(0.04), location: 0.5),
                             .init(color: .black.opacity(0.12), location: 1)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        context.stroke(Path(rect), with: .color(.white.opacity(0.28)), lineWidth: 0.22)
    }

    // MARK: PFDView.drawHorizon (without the flight director)

    private func drawHorizon(_ context: GraphicsContext) {
        var ctx = context
        ctx.clip(to: PFD.attitudeWindow)

        let center = PFD.horizonCenter
        var sphere = ctx
        sphere.translateBy(x: center.x, y: center.y)
        sphere.rotate(by: .degrees(-Icon.rollDeg))
        sphere.translateBy(x: 0, y: PFD.horizonOffset(pitch: Icon.pitchDeg))

        let ext: CGFloat = 400
        sphere.fill(Path(CGRect(x: -ext, y: -ext, width: 2 * ext, height: ext)),
                    with: .color(EFIS.sky))
        sphere.fill(Path(CGRect(x: -ext, y: 0, width: 2 * ext, height: ext)),
                    with: .color(EFIS.ground))
        sphere.line(from: CGPoint(x: -ext, y: 0), to: CGPoint(x: ext, y: 0), .white, width: 0.44)

        for rung in PFD.pitchLadder {
            let y = -PFD.horizonOffset(pitch: rung.deg)
            sphere.line(from: CGPoint(x: -rung.halfWidth, y: y),
                        to: CGPoint(x: rung.halfWidth, y: y), .white, width: 0.35)
            if rung.labelled {
                let text = "\(abs(Int(rung.deg)))"
                sphere.digits(text, at: CGPoint(x: -rung.halfWidth - 3.8, y: y), size: 3.5, .white)
                sphere.digits(text, at: CGPoint(x: rung.halfWidth + 3.8, y: y), size: 3.5, .white)
            }
        }

        // Liquid-glass sheen over the upper window, and a lit rim.
        let window = PFD.attitudeWindow.boundingRect
        ctx.fill(PFD.attitudeWindow, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.26), location: 0),
                             .init(color: .white.opacity(0.06), location: 0.42),
                             .init(color: .clear, location: 0.5)]),
            startPoint: CGPoint(x: window.midX, y: window.minY),
            endPoint: CGPoint(x: window.midX, y: window.maxY)))
        context.stroke(PFD.attitudeWindow, with: .color(.white.opacity(0.35)), lineWidth: 0.31)
    }

    // MARK: PFDView.drawAircraftReference

    private func drawAircraftReference(_ context: GraphicsContext) {
        let c = PFD.horizonCenter
        let outer: CGFloat = 21.9, inner: CGFloat = 12.4, bar: CGFloat = 1.6
        let top = c.y - 0.8, legBottom = c.y + 3.3

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
            context.stroke(bracket, with: .color(EFIS.yellow), lineWidth: 0.35)
        }

        let side: CGFloat = 1.9
        let square = Path(CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side))
        context.fill(square, with: .color(EFIS.background))
        context.stroke(square, with: .color(EFIS.yellow), lineWidth: 0.35)
    }

    // MARK: PFDView.drawBankScale

    private func drawBankScale(_ context: GraphicsContext) {
        let center = PFD.horizonCenter
        let radius = PFD.bankScaleRadius

        func point(_ angleDeg: Double, _ r: CGFloat) -> CGPoint {
            let a = angleDeg * .pi / 180
            return CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))
        }

        var arc = Path()
        for step in stride(from: -31.0, through: 31.0, by: 1.0) {
            let p = point(step, radius)
            step == -31 ? arc.move(to: p) : arc.addLine(to: p)
        }
        context.stroke(arc, with: .color(.white), lineWidth: 0.35)

        for angle in [-30.0, -20, -10, 10, 20, 30] {
            let inner = point(angle, radius), outer = point(angle, radius + 1.8)
            let a = angle * .pi / 180
            let across = CGPoint(x: cos(a) * 0.55, y: sin(a) * 0.55)
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
                         .white, width: 0.35)
        }

        context.stroke(triangle(apex: point(0, radius), baseY: center.y - radius - 2.3, halfWidth: 1.6),
                       with: .color(EFIS.yellow), lineWidth: 0.35)

        var rolled = context
        rolled.translateBy(x: center.x, y: center.y)
        rolled.rotate(by: .degrees(-Icon.rollDeg))
        rolled.translateBy(x: -center.x, y: -center.y)

        rolled.stroke(triangle(apex: point(0, radius - 0.7), baseY: center.y - radius + 3.4, halfWidth: 1.8),
                      with: .color(EFIS.yellow), lineWidth: 0.35)

        let slipTop = center.y - radius + 3.75, slipBottom = center.y - radius + 5.1
        var slip = Path()
        slip.move(to: CGPoint(x: center.x - 1.6, y: slipTop))
        slip.addLine(to: CGPoint(x: center.x + 1.6, y: slipTop))
        slip.addLine(to: CGPoint(x: center.x + 1.23, y: slipBottom))
        slip.addLine(to: CGPoint(x: center.x - 1.23, y: slipBottom))
        slip.closeSubpath()
        rolled.stroke(slip, with: .color(EFIS.yellow), lineWidth: 0.35)
    }

    private func triangle(apex: CGPoint, baseY: CGFloat, halfWidth: CGFloat) -> Path {
        var p = Path()
        p.move(to: apex)
        p.addLine(to: CGPoint(x: apex.x - halfWidth, y: baseY))
        p.addLine(to: CGPoint(x: apex.x + halfWidth, y: baseY))
        p.closeSubpath()
        return p
    }

    // MARK: PFDView.drawSpeedTape

    private func drawSpeedTape(_ context: GraphicsContext) {
        let tape = PFD.speedTape
        let centerY = PFD.horizonCenter.y
        let speed = Icon.speed

        fillGlassTape(context, tape)

        func y(for value: Double) -> CGFloat { centerY - CGFloat(value - speed) * PFD.speedScale }

        var clipped = context
        clipped.clip(to: Path(tape.insetBy(dx: -PFD.speedStripWidth, dy: 0)))

        var value = ((speed - 45) / 10).rounded(.down) * 10
        while value <= speed + 45 {
            if value >= 30 {
                let ty = y(for: value)
                let labelled = value.truncatingRemainder(dividingBy: 20) == 0
                clipped.line(from: CGPoint(x: tape.maxX - (labelled ? 2.3 : 1.4), y: ty),
                             to: CGPoint(x: tape.maxX, y: ty), .white, width: 0.35)
                if labelled {
                    clipped.digits("\(Int(value))", at: CGPoint(x: tape.maxX - 3.15, y: ty),
                                   size: 3.9, .white, anchor: .trailing)
                }
            }
            value += 10
        }

        drawBarberPole(clipped, PFD.vmaxPole,
                       anchorY: min(y(for: Icon.vmax), centerY + PFD.vmaxPoleMaxOffset),
                       endY: tape.minY - 1.3, visible: tape.minY...tape.maxY, color: EFIS.red)
        drawTrendArrow(clipped, trend: Icon.speedTrend, centerY: centerY)

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
        context.stroke(arrow, with: .color(EFIS.yellow), lineWidth: 0.44)
    }

    // MARK: PFDView.drawAltitudeTape / drawAltitudeReadout

    private func drawAltitudeTape(_ context: GraphicsContext) {
        let tape = PFD.altTape
        let centerY = PFD.horizonCenter.y
        let altitude = Icon.altitudeFt

        fillGlassTape(context, tape)

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
                         .white, width: 0.35)
            if labelled {
                clipped.digits(String(format: "%03d", Int(value / 100)),
                               at: CGPoint(x: tape.minX + 2.0, y: ty),
                               size: 3.5, .white, anchor: .leading)
            }
            value += 100
        }

        let bugY = y(for: Icon.selectedAltitudeFt)
        if tape.minY...tape.maxY ~= bugY {
            var bug = Path()
            bug.move(to: CGPoint(x: tape.minX, y: bugY - 1.5))
            bug.addLine(to: CGPoint(x: tape.minX + 2.0, y: bugY - 1.5))
            bug.addLine(to: CGPoint(x: tape.minX + 2.0, y: bugY + 1.5))
            bug.addLine(to: CGPoint(x: tape.minX, y: bugY + 1.5))
            clipped.stroke(bug, with: .color(EFIS.cyan), lineWidth: 0.5)
        }

        drawAltitudeReadout(context, centerY: centerY, altitude: altitude)
    }

    private func drawAltitudeReadout(_ context: GraphicsContext, centerY: CGFloat, altitude: Double) {
        let tape = PFD.altTape
        let digitWindow = CGRect(x: tape.minX, y: centerY - 2.83, width: tape.width, height: 5.66)
        let drumWindow = CGRect(x: tape.maxX, y: centerY - 4.5, width: 5.6, height: 9.0)

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
        context.stroke(outline, with: .color(EFIS.yellow), lineWidth: 0.44)

        let hundreds = Int(altitude / 100)
        let remainder = altitude - Double(hundreds) * 100

        func slot(_ index: Int) -> CGPoint {
            CGPoint(x: digitWindow.maxX - 0.95 - CGFloat(index) * 2.85, y: centerY)
        }
        context.digits("\(hundreds % 10)", at: slot(0), size: 5.0, EFIS.green, weight: .bold)
        if hundreds >= 10 {
            context.digits("\(hundreds / 10 % 10)", at: slot(1), size: 5.0, EFIS.green, weight: .bold)
        }
        if hundreds >= 100 {
            context.digits("\(hundreds / 100 % 10)", at: slot(2), size: 5.0, EFIS.green, weight: .bold)
        }

        var drum = context
        drum.clip(to: Path(drumWindow.insetBy(dx: 0.3, dy: 0.3)))

        let rowHeight: CGFloat = 2.96
        let position = remainder / 20
        let base = position.rounded(.down)
        let raw = CGFloat(position - base)
        let fraction = raw < 0.7 ? 0 : (raw - 0.7) / 0.3

        for step in -2...2 {
            let index = ((Int(base) + step) % 5 + 5) % 5
            drum.digits(String(format: "%02d", index * 20),
                        at: CGPoint(x: drumWindow.minX + 2.9, y: centerY - (CGFloat(step) - fraction) * rowHeight),
                        size: 3.5, EFIS.green, weight: .bold)
        }
    }

    // MARK: PFDView.drawFMA

    private func drawFMA(_ context: GraphicsContext) {
        let box = PFD.fma
        let rowHeight = box.height / 3

        // Separators between the four columns drawn; the last one, which
        // would only fence off the omitted engagement column, is left out.
        for x in PFD.fmaSeparators.dropLast() {
            context.line(from: CGPoint(x: x, y: box.minY), to: CGPoint(x: x, y: box.maxY),
                         .white, width: 0.25)
        }

        let bounds: [ClosedRange<CGFloat>] = [
            0...PFD.fmaSeparators[0],
            PFD.fmaSeparators[0]...PFD.fmaSeparators[1],
            PFD.fmaSeparators[1]...PFD.fmaSeparators[2],
            PFD.fmaSeparators[2]...PFD.fmaSeparators[3],
        ]

        for (column, range) in zip(Icon.fmaColumns, bounds) {
            let midX = (range.lowerBound + range.upperBound) / 2
            for (row, entry) in column.enumerated() where !entry.text.isEmpty {
                context.digits(entry.text,
                               at: CGPoint(x: midX, y: box.minY + rowHeight * (CGFloat(row) + 0.5)),
                               size: 3.3, entry.color, weight: .bold)
            }
        }
    }

    // MARK: PFDView.drawHeadingTape

    private func drawHeadingTape(_ context: GraphicsContext) {
        let tape = PFD.headingTape
        let heading = Icon.headingDeg
        let centerX = tape.midX

        fillGlassTape(context, tape)

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
                         to: CGPoint(x: tx, y: tape.minY + (major ? 2.14 : 1.26)), .white, width: 0.35)
            if major {
                clipped.digits(String(format: "%02d", Int(value.rounded()) / 10),
                               at: CGPoint(x: tx, y: tape.minY + 4.28), size: 3.4, .white)
            }
            deg += 5
        }

        let trackX = x(for: heading + angularDifference(Icon.trackDeg, heading))
        var diamond = Path()
        diamond.move(to: CGPoint(x: trackX, y: tape.minY - 2.14))
        diamond.addLine(to: CGPoint(x: trackX + 1.39, y: tape.minY - 0.76))
        diamond.addLine(to: CGPoint(x: trackX, y: tape.minY + 0.63))
        diamond.addLine(to: CGPoint(x: trackX - 1.39, y: tape.minY - 0.76))
        diamond.closeSubpath()
        context.stroke(diamond, with: .color(EFIS.green), lineWidth: 0.38)

        context.line(from: CGPoint(x: centerX, y: tape.minY - 2.9),
                     to: CGPoint(x: centerX, y: tape.minY + 2.14), EFIS.yellow, width: 0.69)
    }
}

// MARK: - Render to an opaque PNG (App Store icons may not carry alpha)

@MainActor
func renderIcon(to output: String) {
    let renderer = ImageRenderer(content: AppIconView())
    renderer.scale = 1
    guard let source = renderer.cgImage else {
        FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
        exit(1)
    }

    let side = 1024
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let flat = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                               bytesPerRow: side * 4, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
    flat.setFillColor(CGColor(red: 0.016, green: 0.016, blue: 0.016, alpha: 1))
    flat.fill(CGRect(x: 0, y: 0, width: side, height: side))
    flat.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let image = flat.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil)
    else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
    print("wrote \(output)")
}

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "FlightDeck/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png"
MainActor.assumeIsolated { renderIcon(to: output) }
