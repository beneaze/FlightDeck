import SwiftUI

/// Airbus EFIS house style — the colour code shared by the PFD, ND and VD.
///
/// Airbus assigns *meaning* to colour, so these names are semantic rather than
/// descriptive: anything the crew selects is cyan, anything the FMS manages is
/// magenta, engaged modes are green, and fixed aircraft references are yellow.
enum EFIS {

    // MARK: Colour code
    //
    // Exact display values, matching the A320 EFIS definitions used by the
    // FlyByWire A32NX. These are saturated on purpose — an EFIS is a
    // self-luminous instrument, not a document.

    /// Engaged modes, current-state readouts, the flight plan.
    static let green   = Color(red: 0.00, green: 1.00, blue: 0.00)   // #00ff00
    /// Crew-selected targets (FCU altitude, heading bug, range).
    static let cyan    = Color(red: 0.00, green: 1.00, blue: 1.00)   // #00ffff
    /// FMS-managed targets, ILS data, deviation diamonds.
    static let magenta = Color(red: 1.00, green: 0.58, blue: 1.00)   // #ff94ff
    /// Cautions — VLS, low-energy, armed limits.
    static let amber   = Color(red: 0.90, green: 0.50, blue: 0.00)   // #e68000
    /// Fixed aircraft symbol, lubber lines, the altitude readout box.
    static let yellow  = Color(red: 1.00, green: 1.00, blue: 0.00)   // #ffff00
    /// Warnings and VMAX.
    static let red     = Color(red: 1.00, green: 0.00, blue: 0.00)   // #ff0000

    // MARK: Surfaces

    static let sky       = Color(red: 0.024, green: 0.596, blue: 1.00)  // #0698ff
    static let ground    = Color(red: 0.612, green: 0.282, blue: 0.047) // #9c480c
    /// Speed / altitude / heading tape background.
    static let tape      = Color(red: 0.471, green: 0.471, blue: 0.471) // #787878
    /// Display background — not quite black, as on the real unit.
    static let background = Color(red: 0.016, green: 0.016, blue: 0.016) // #040404
    static let separator = Color.white

    // MARK: Type

    /// Numeric readouts — monospaced so rolling digits do not jitter.
    static func digits(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Mode names and annunciations.
    static func label(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Canvas helpers

extension GraphicsContext {

    /// Draw a single line — by far the most common primitive on an EFIS.
    func line(from a: CGPoint, to b: CGPoint, _ color: Color, width: CGFloat = 1.5) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        stroke(p, with: .color(color), lineWidth: width)
    }

    /// Draw text anchored at `point`, using the EFIS monospaced digit face.
    func digits(_ string: String, at point: CGPoint, size: CGFloat,
                _ color: Color, weight: Font.Weight = .semibold,
                anchor: UnitPoint = .center) {
        draw(Text(string).font(EFIS.digits(size, weight)).foregroundStyle(color),
             at: point, anchor: anchor)
    }

    /// Draw a mode label / annunciation.
    func label(_ string: String, at point: CGPoint, size: CGFloat,
               _ color: Color, weight: Font.Weight = .bold,
               anchor: UnitPoint = .center) {
        draw(Text(string).font(EFIS.label(size, weight)).foregroundStyle(color),
             at: point, anchor: anchor)
    }
}

// MARK: - Angle helpers

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Wrap to 0..<360.
func normalizedHeading(_ deg: Double) -> Double {
    let d = deg.truncatingRemainder(dividingBy: 360)
    return d < 0 ? d + 360 : d
}

/// Shortest signed difference `a - b`, in -180...180.
func angularDifference(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
