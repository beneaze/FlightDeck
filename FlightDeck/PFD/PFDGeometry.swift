import SwiftUI

/// Layout of the A320-style PFD, on a square canvas 100 units on a side.
///
/// Everything is drawn in these units and the canvas is scaled once to fit,
/// so the instrument keeps its proportions on every screen. The layout is
/// parametric: a handful of design values below — the horizon centre, the
/// attitude window, the tape band, the scale factors — and every element is
/// placed from them, so moving one keeps the rest in step.
enum PFD {

    /// Side of the square display.
    static let canvas: CGFloat = 100

    // MARK: - Attitude

    /// Centre of the horizon — the origin everything attitude-related hangs
    /// off, and the height the tapes' reference lines sit at.
    static let horizonCenter = CGPoint(x: 43.5, y: 51)

    /// The attitude window is the A320's "stadium": straight sides, with an
    /// elliptical cap above and below that meets the sides at a shoulder.
    static let windowHalfWidth: CGFloat = 23.2
    /// Half the length of the straight sides.
    static let windowSideHalfHeight: CGFloat = 12.9
    /// Height of each elliptical cap beyond the straight sides.
    static let windowCapHeight: CGFloat = 13.6
    /// Each cap is an arc of a larger ellipse whose centre lies this far
    /// inside the straight section, so the cap leaves the side at an angle
    /// (about 65°) instead of rising vertically out of it.
    static let windowCapCentreInset: CGFloat = 8.2

    static var windowLeft: CGFloat { horizonCenter.x - windowHalfWidth }
    static var windowRight: CGFloat { horizonCenter.x + windowHalfWidth }
    static var windowTop: CGFloat { horizonCenter.y - windowSideHalfHeight - windowCapHeight }
    static var windowBottom: CGFloat { horizonCenter.y + windowSideHalfHeight + windowCapHeight }

    static var attitudeWindow: Path {
        let c = horizonCenter
        var p = Path()
        p.move(to: CGPoint(x: windowLeft, y: c.y - windowSideHalfHeight))
        // addLines would start a new subpath; the outline must stay one.
        for point in capPoints(centerY: c.y + windowSideHalfHeight, lower: true)
            + capPoints(centerY: c.y - windowSideHalfHeight, lower: false) {
            p.addLine(to: point)
        }
        p.closeSubpath()
        return p
    }

    /// Points along one cap of the window — left to right for the lower cap,
    /// right to left for the upper — so the outline runs round in one go.
    private static func capPoints(centerY: CGFloat, lower: Bool) -> [CGPoint] {
        let w = Double(windowHalfWidth), d = Double(windowCapCentreInset)
        let b = Double(windowCapHeight) + d                 // vertical semi-axis
        let a = w / (1 - d * d / (b * b)).squareRoot()      // through the side tops
        let direction: CGFloat = lower ? 1 : -1             // away from the horizon
        let steps = 48
        return (0...steps).map { i in
            let x = w * (2 * Double(i) / Double(steps) - 1) * Double(direction)
            let rise = b * (1 - x * x / (a * a)).squareRoot() - d
            return CGPoint(x: horizonCenter.x + CGFloat(x),
                           y: centerY + direction * CGFloat(rise))
        }
    }

    /// Display units per degree of pitch near the horizon.
    static let pitchScale: CGFloat = 1.15
    /// Where the scale starts to compress, so large attitudes stay inside
    /// the window: 20° either side of the horizon. Inside it the graduations
    /// are evenly spaced above and below, as on the real display.
    static let pitchKneeUpDeg = 20.0
    static let pitchKneeDownDeg = 20.0
    /// Beyond the knee the scale eases, over about this many degrees, from
    /// full slope to `pitchFarSlope` of it.
    static let pitchSoftDeg = 5.0
    static let pitchFarSlope = 0.55

    /// Vertical offset of a pitch angle from the horizon, in display units
    /// (positive = up). Linear inside the knee; beyond it the slope eases
    /// smoothly (a tanh blend, so it joins with the same slope) toward a
    /// reduced one.
    static func horizonOffset(pitch: Double) -> CGFloat {
        let magnitude = abs(pitch)
        let knee = pitch >= 0 ? pitchKneeUpDeg : pitchKneeDownDeg
        var scaled = magnitude
        if magnitude > knee {
            let beyond = magnitude - knee
            scaled = knee + pitchFarSlope * beyond
                + (1 - pitchFarSlope) * pitchSoftDeg * tanh(beyond / pitchSoftDeg)
        }
        return CGFloat(pitch < 0 ? -scaled : scaled) * pitchScale
    }

    /// Pitch ladder rungs: angle, half-width, and whether the angle is
    /// labelled. Every 2.5° above the horizon and every 5° below it out to
    /// 20°, plus a wide rung at ±30°. Tens are long and labelled, fives
    /// medium, the rest short.
    static var pitchLadder: [(deg: Double, halfWidth: CGFloat, labelled: Bool)] {
        var rungs: [(Double, CGFloat, Bool)] = []
        for deg in stride(from: -20.0, through: 27.5, by: 2.5) where deg != 0 {
            if deg < -10, deg.truncatingRemainder(dividingBy: 5) != 0 { continue }
            if deg.truncatingRemainder(dividingBy: 10) == 0 {
                rungs.append((deg, 6.0, true))
            } else if deg.truncatingRemainder(dividingBy: 5) == 0 {
                rungs.append((deg, 2.8, false))
            } else {
                rungs.append((deg, 1.6, false))
            }
        }
        rungs.append((30, 8.2, false))
        rungs.append((-30, 8.2, false))
        return rungs
    }

    /// Radius of the fixed bank-angle scale: its arc runs along the top of
    /// the window.
    static var bankScaleRadius: CGFloat { horizonCenter.y - windowTop }

    /// The yellow bank indices at the top of the scale. The fixed zero-bank
    /// reference stands above the arc; the roll index hangs under it, and
    /// the sideslip index under that continues the roll index's sides.
    struct BankIndex {
        let referenceHeight: CGFloat
        let referenceHalfWidth: CGFloat
        let rollHeight: CGFloat
        let rollHalfWidth: CGFloat
        let slipGap: CGFloat
        let slipHeight: CGFloat
        let lineWidth: CGFloat
    }
    static let bankIndex = BankIndex(referenceHeight: 2.3, referenceHalfWidth: 1.95,
                                     rollHeight: 2.45, rollHalfWidth: 2.0,
                                     slipGap: 0.45, slipHeight: 1.1, lineWidth: 0.4)

    /// The heading marks under the horizon line.
    static let horizonHeadingMarkLength: CGFloat = 0.9

    /// The pitch scale's band. The sky and the ground fill the whole window,
    /// but the graduations show only between two fixed white lines across
    /// it, about 70 % of the way from the horizon centre to the window's top
    /// and bottom — about 16° either side of level. Above the upper line
    /// the roll pointer and slip index have the sky to themselves; below
    /// the lower one is the radio height's own section.
    static let pitchBandHalfHeight: CGFloat = 18.4
    static var pitchBandTop: CGFloat { horizonCenter.y - pitchBandHalfHeight }
    static var pitchBandBottom: CGFloat { horizonCenter.y + pitchBandHalfHeight }
    /// The band's lines stop this far short of the window's edge.
    static let pitchBandLineInset: CGFloat = 1.2

    /// The lower line is also the ground reference: below 570 ft radio
    /// height — the height at which the red ground ribbon appears beside the
    /// altitude scale — it rises toward the horizon line, reaching it on
    /// touchdown, so on the ground nothing of the pitch scale shows below the
    /// horizon. Display units per foot of height, so the line leaves its
    /// resting place at 570 ft in level flight.
    static let groundReferenceCeilingFt = 570.0
    /// Heights up to this count as touchdown for the ground reference: the
    /// height is GPS altitude less the pack's terrain, and on the runway the
    /// two disagree by some feet. Within it the line lies on the horizon
    /// line, and the two read as one.
    static let groundReferenceContactFt = 20.0
    static var groundReferenceScale: CGFloat {
        pitchBandHalfHeight / CGFloat(groundReferenceCeilingFt - groundReferenceContactFt)
    }
    /// Closer to the horizon line than this, the ground reference is not
    /// drawn as a line of its own: the horizon line is the boundary.
    static let groundReferenceMergeOffset: CGFloat = 0.25

    /// Half the window's width at height `y`: the straight sides, or the cap
    /// above or below them.
    static func windowHalfWidth(atY y: CGFloat) -> CGFloat {
        let fromCentre = abs(y - horizonCenter.y)
        guard fromCentre > windowSideHalfHeight else { return windowHalfWidth }
        let w = Double(windowHalfWidth), d = Double(windowCapCentreInset)
        let b = Double(windowCapHeight) + d
        let a = w / (1 - d * d / (b * b)).squareRoot()
        let rise = Double(fromCentre - windowSideHalfHeight) + d
        guard rise < b else { return 0 }
        return CGFloat(a * (1 - rise * rise / (b * b)).squareRoot())
    }

    /// The radio height: fixed, not on the sphere — centred under the
    /// aircraft symbol in the section below the pitch band.
    static var radioHeightCenter: CGPoint {
        CGPoint(x: horizonCenter.x, y: (pitchBandBottom + windowBottom) / 2 + 0.2)
    }
    /// Type size of the radio height, as large as the altitude readout's.
    static let radioHeightType: CGFloat = 5.0

    // MARK: - Tapes

    /// The speed and altitude tapes share one band, centred on the horizon.
    static let tapeHalfHeight: CGFloat = 26.9
    static var tapeTop: CGFloat { horizonCenter.y - tapeHalfHeight }

    // MARK: Speed tape

    static var speedTape: CGRect {
        CGRect(x: 1.2, y: tapeTop, width: 10.8, height: 2 * tapeHalfHeight)
    }
    /// Display units per knot (or per km/h, mph — the tape is unit-agnostic).
    /// The tape shows about ±42 of its unit around the current speed.
    static var speedScale: CGFloat { tapeHalfHeight / 42.5 }

    /// A barber pole outboard of the tape: blocks at a fixed pitch, the
    /// first block's edge on the speed the pole marks.
    struct BarberPole {
        let x: CGFloat
        let width: CGFloat
        let blockHeight: CGFloat
        let pitch: CGFloat
    }

    /// VMAX — red blocks rising from the limit, one every 5 speed units,
    /// each half a pitch tall.
    static var vmaxPole: BarberPole {
        let pitch = 5 * speedScale
        return BarberPole(x: speedTape.maxX, width: 1.9, blockHeight: pitch / 2, pitch: pitch)
    }
    /// Width of the strip just outboard of the tape that the pole occupies.
    static var speedStripWidth: CGFloat { vmaxPole.width }
    /// Above VMAX the pole stops following the speed once it reaches the
    /// bottom of the tape, so the tape stays fully striped rather than the
    /// pole sliding off it.
    static var vmaxPoleMaxOffset: CGFloat { tapeHalfHeight - 0.5 }

    // MARK: Altitude tape

    static var altTape: CGRect {
        CGRect(x: 74.2, y: tapeTop, width: 8.25, height: 2 * tapeHalfHeight)
    }
    /// Display units per foot: the tape shows about ±570 ft.
    static var altScale: CGFloat { tapeHalfHeight / 570 }

    /// The ground reference: a red ribbon in the strip just outboard of the
    /// tape, between it and the V/S scale — the counterpart of the speed
    /// tape's barber pole on the other side. Its top edge marks the ground;
    /// the altitude readout's drum covers it where they cross.
    static var groundRibbon: CGRect {
        CGRect(x: altTape.maxX, y: tapeTop, width: 1.6, height: 2 * tapeHalfHeight)
    }

    // MARK: - Vertical speed

    /// Inboard edge of the V/S strip.
    static let verticalSpeedLeft: CGFloat = 92.2
    /// Where the graduations start — the step in the strip's outline.
    static let verticalSpeedX: CGFloat = 95.6
    /// Outboard edge of the strip.
    static let verticalSpeedRight: CGFloat = 98.2
    /// Half-height of the strip at its inboard edge…
    static let verticalSpeedHalfHeight: CGFloat = 32
    /// …and of its full-width middle section.
    static let verticalSpeedShoulder: CGFloat = 22.2

    /// The V/S strip: full width through the middle, tapering on the
    /// outboard side toward the ends.
    static var verticalSpeedOutline: Path {
        let cy = horizonCenter.y
        var p = Path()
        p.move(to: CGPoint(x: verticalSpeedLeft, y: cy - verticalSpeedHalfHeight))
        p.addLine(to: CGPoint(x: verticalSpeedX, y: cy - verticalSpeedHalfHeight))
        p.addLine(to: CGPoint(x: verticalSpeedRight, y: cy - verticalSpeedShoulder))
        p.addLine(to: CGPoint(x: verticalSpeedRight, y: cy + verticalSpeedShoulder))
        p.addLine(to: CGPoint(x: verticalSpeedX, y: cy + verticalSpeedHalfHeight))
        p.addLine(to: CGPoint(x: verticalSpeedLeft, y: cy + verticalSpeedHalfHeight))
        p.closeSubpath()
        return p
    }

    /// Where each graduation of the V/S scale sits above the zero line: the
    /// scale is open up to 1000 ft/min and progressively compressed beyond,
    /// so ±6000 still fits in the strip.
    static let verticalSpeedBreakpoints: [(fpm: Double, offset: CGFloat)] = [
        (0, 0), (1_000, 17), (2_000, 23.5), (6_000, 30),
    ]

    /// Vertical offset of a rate of climb from the zero line, in display
    /// units (negative = up, as the canvas's y axis runs down). Linear
    /// between breakpoints, pinned beyond the last.
    static func verticalSpeedOffset(fpm: Double) -> CGFloat {
        let magnitude = abs(fpm)
        var offset = verticalSpeedBreakpoints.last!.offset
        for (a, b) in zip(verticalSpeedBreakpoints, verticalSpeedBreakpoints.dropFirst())
        where magnitude <= b.fpm {
            let t = CGFloat((magnitude - a.fpm) / (b.fpm - a.fpm))
            offset = a.offset + (b.offset - a.offset) * t
            break
        }
        return fpm < 0 ? offset : -offset
    }

    // MARK: - Heading tape

    /// Under the attitude window and exactly as wide as it.
    static var headingTape: CGRect {
        CGRect(x: windowLeft, y: 91.5, width: 2 * windowHalfWidth, height: 6.5)
    }
    /// Display units per degree: the tape shows about ±25° of heading.
    static let headingScale: CGFloat = 0.95

    // MARK: - FMA

    static let fma = CGRect(x: 0, y: 1, width: canvas, height: 13.5)
    /// x positions of the four column separators. The columns are thrust,
    /// vertical, lateral, approach and engagement status; lateral is the
    /// widest, as its mode names are the longest.
    static let fmaSeparators: [CGFloat] = [20.6, 41.2, 64.8, 83.5]
}
