import SwiftUI

/// Geometry of the A320 PFD, in the display's own coordinate system.
///
/// The real PFD is authored as a 158.75 × 158.75 SVG, and every component sits
/// at a fixed position within it. Drawing in those units — then scaling the
/// whole canvas once — keeps every element in the exact relationship the real
/// display has, instead of letting SwiftUI layout drift them apart.
///
/// Coordinates follow the FlyByWire A32NX PFD, which is the reference
/// implementation for this instrument.
enum PFD {

    /// Side of the square display.
    static let canvas: CGFloat = 158.75

    // MARK: Attitude

    /// Centre of the horizon — the origin everything attitude-related hangs off.
    static let horizonCenter = CGPoint(x: 68.906, y: 80.823)

    /// Radius of the fixed bank-angle scale.
    static let bankScaleRadius: CGFloat = 42.14

    /// The attitude window: straight sides with elliptical caps top and bottom.
    /// This is the A320's distinctive "stadium" outline, not a rounded square.
    static var attitudeWindow: Path {
        let left: CGFloat = 32.138, right: CGFloat = 105.674, center: CGFloat = 68.906
        let bottom: CGFloat = 101.25, top: CGFloat = 60.391, cap: CGFloat = 21.652

        var p = Path()
        p.move(to: CGPoint(x: left, y: bottom))
        p.addCurve(to: CGPoint(x: center, y: bottom + cap),
                   control1: CGPoint(x: left + 7.4164, y: bottom + 13.363),
                   control2: CGPoint(x: left + 21.492, y: bottom + cap))
        p.addCurve(to: CGPoint(x: right, y: bottom),
                   control1: CGPoint(x: center + 15.277, y: bottom + cap),
                   control2: CGPoint(x: center + 29.352, y: bottom + cap - 8.2886))
        p.addLine(to: CGPoint(x: right, y: top))
        p.addCurve(to: CGPoint(x: center, y: top - cap),
                   control1: CGPoint(x: right - 7.4164, y: top - 13.363),
                   control2: CGPoint(x: right - 21.492, y: top - cap))
        p.addCurve(to: CGPoint(x: left, y: top),
                   control1: CGPoint(x: center - 15.277, y: top - cap),
                   control2: CGPoint(x: center - 29.352, y: top - cap + 8.2886))
        p.closeSubpath()
        return p
    }

    /// Vertical offset of a pitch angle from the horizon, in display units.
    ///
    /// Linear at 1.8 units per degree through the normal range, then
    /// deliberately compressed beyond ±20° so large attitudes stay on screen.
    static func horizonOffset(pitch: Double) -> CGFloat {
        switch pitch {
        case let p where p > -5 && p <= 20:  return CGFloat(p * 1.8)
        case let p where p > 20 && p <= 30:  return CGFloat(-0.04 * p * p + 3.4 * p - 16)
        case let p where p > 30:             return CGFloat(20 + p)
        case let p where p < -5 && p >= -15: return CGFloat(0.04 * p * p + 2.2 * p + 1)
        default:                             return CGFloat(pitch - 8)
        }
    }

    /// Pitch ladder rungs: angle, half-width, and whether the angle is labelled.
    static let pitchLadder: [(deg: Double, halfWidth: CGFloat, labelled: Bool)] = [
        (2.5, 2.5, false), (5, 4.5, false), (7.5, 2.5, false), (10, 9.5, true),
        (12.5, 2.5, false), (15, 4.5, false), (17.5, 2.5, false), (20, 9.5, true),
        (22.5, 2.5, false), (25, 4.5, false), (27.5, 2.5, false), (30, 13, false),
        (-2.5, 2.5, false), (-5, 4.5, false), (-7.5, 2.5, false), (-10, 9.5, true),
        (-15, 4.5, false), (-20, 9.5, true), (-30, 13, false),
    ]

    // MARK: Speed tape

    static let speedTape = CGRect(x: 1.9058, y: 38.087, width: 17.125, height: 85.473)
    /// Display units per knot.
    static let speedScale: CGFloat = 1.0
    /// Width of the VMAX / VLS strips, drawn just outboard of the tape.
    static let speedStripWidth: CGFloat = 2.92

    // MARK: Altitude tape

    static let altTape = CGRect(x: 117.754, y: 38.087, width: 13.096, height: 85.473)
    /// Display units per foot.
    static let altScale: CGFloat = 0.075

    // MARK: Vertical speed

    /// The V/S strip's stepped outline — narrower at top and bottom.
    static var verticalSpeedOutline: Path {
        var p = Path()
        p.move(to: CGPoint(x: 151.84, y: 131.72))
        p.addLine(to: CGPoint(x: 155.97, y: 116.097))
        p.addLine(to: CGPoint(x: 155.97, y: 45.541))
        p.addLine(to: CGPoint(x: 151.84, y: 29.918))
        p.addLine(to: CGPoint(x: 146.30, y: 29.918))
        p.addLine(to: CGPoint(x: 146.30, y: 131.72))
        p.closeSubpath()
        return p
    }

    /// Inboard edge of the V/S scale, where the graduations start.
    static let verticalSpeedX: CGFloat = 151.84

    /// Vertical offset of a rate of climb from the zero line, in display units.
    /// Compressed above 1000 fpm so ±6000 fits in the same strip.
    static func verticalSpeedOffset(fpm: Double) -> CGFloat {
        let magnitude = abs(fpm)
        let sign = fpm < 0 ? -1.0 : 1.0
        switch magnitude {
        case ..<1_000:  return CGFloat(fpm / 1_000 * -27.22)
        case ..<2_000:  return CGFloat((fpm - sign * 1_000) / 1_000 * -10.1 - sign * 27.22)
        case ..<6_000:  return CGFloat((fpm - sign * 2_000) / 4_000 * -10.1 - sign * 37.32)
        default:        return CGFloat(sign * -47.37)
        }
    }

    // MARK: Heading tape

    static let headingTape = CGRect(x: 32.138, y: 145.34, width: 73.536, height: 10.382)
    /// Display units per degree.
    static let headingScale: CGFloat = 1.5

    // MARK: FMA

    static let fma = CGRect(x: 0, y: 1.5, width: canvas, height: 21.5)
    /// x positions of the four column separators.
    static let fmaSeparators: [CGFloat] = [32.7, 65.4, 102.8, 132.6]
}
