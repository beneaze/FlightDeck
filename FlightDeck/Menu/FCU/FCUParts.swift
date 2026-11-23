import SwiftUI
import UIKit

// The parts the glareshield panels are built from: plates, LCD windows
// with segment digits, knurled knobs, pushbuttons, switches and the
// thumbwheel. Our own drawing after photographs of the real units, sized
// in panel units — the panels are laid out at a fixed size and scaled as
// a whole to the screen. All vector: gradients, strokes and shadows, with
// the light falling from the top left everywhere.

// MARK: - Colours

enum FCUColors {
    // A320: the cockpit's grey-blue in a satin finish, white legends,
    // orange-amber LCD digits on dark grey-green glass.
    static let airbusPanelTop = Color(red: 0.45, green: 0.52, blue: 0.59)
    static let airbusPanel = Color(red: 0.39, green: 0.46, blue: 0.53)
    static let airbusPanelBottom = Color(red: 0.33, green: 0.39, blue: 0.46)
    /// The darker inset frame each LCD window sits in.
    static let airbusBezel = Color(red: 0.19, green: 0.23, blue: 0.27)
    static let airbusLegend = Color(white: 0.96)
    static let airbusDigits = Color(red: 1.0, green: 0.61, blue: 0.19)
    static let airbusGlassTop = Color(red: 0.105, green: 0.125, blue: 0.110)
    static let airbusGlassBottom = Color(red: 0.060, green: 0.074, blue: 0.065)

    // 737NG: a medium neutral grey, black-framed windows, white legends
    // and white LCD digits.
    static let boeingPanelTop = Color(red: 0.46, green: 0.47, blue: 0.48)
    static let boeingPanel = Color(red: 0.40, green: 0.41, blue: 0.42)
    static let boeingPanelBottom = Color(red: 0.34, green: 0.35, blue: 0.36)
    static let boeingLegend = Color(white: 0.97)
    static let boeingDigits = Color(red: 0.93, green: 0.95, blue: 0.92)
    static let boeingGlassTop = Color(white: 0.060)
    static let boeingGlassBottom = Color(white: 0.025)

    static let lcd = Color(red: 0.07, green: 0.06, blue: 0.05)
    static let lightGreen = Color(red: 0.38, green: 1.0, blue: 0.48)
    /// A light bar's core while lit, near white.
    static let lightGreenCore = Color(red: 0.82, green: 1.0, blue: 0.84)
    static let capDark = Color(white: 0.15)
}

// MARK: - Plate

extension View {
    /// The panel plate behind a unit, or behind one row of it in portrait:
    /// a satin painted face lit from the top left, a bevelled edge, and a
    /// recessed fastener in each corner.
    func fcuPlate(boeing: Bool, cornerRadius: CGFloat = 8) -> some View {
        let colors = boeing
            ? [FCUColors.boeingPanelTop, FCUColors.boeingPanel, FCUColors.boeingPanelBottom]
            : [FCUColors.airbusPanelTop, FCUColors.airbusPanel, FCUColors.airbusPanelBottom]
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(
                ZStack {
                    shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    // Satin paint: a broad soft sheen high on the left,
                    // falling away to the right.
                    shape.fill(RadialGradient(colors: [.white.opacity(0.10), .white.opacity(0.03), .clear],
                                              center: UnitPoint(x: 0.18, y: -0.25), startRadius: 0, endRadius: 520))
                    shape.fill(LinearGradient(colors: [.white.opacity(0.03), .clear, .black.opacity(0.07)],
                                              startPoint: .leading, endPoint: .trailing))
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.75), radius: 5, x: 2, y: 4)
            )
            // The edge bevel: lit along the top and left, shaded along the
            // bottom and right, and the fine line where it meets the face.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(stops: [.init(color: .white.opacity(0.42), location: 0),
                                           .init(color: .white.opacity(0.10), location: 0.35),
                                           .init(color: .black.opacity(0.10), location: 0.65),
                                           .init(color: .black.opacity(0.45), location: 1)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 2.2)
            )
            .overlay(
                shape.inset(by: 2.2).strokeBorder(Color.black.opacity(0.16), lineWidth: 0.6)
            )
            .overlay(shape.strokeBorder(Color.black.opacity(0.75), lineWidth: 0.6))
            .overlay(alignment: .topLeading) { FCUScrew(slotAngle: 35).offset(x: 5.5, y: 5.5) }
            .overlay(alignment: .topTrailing) { FCUScrew(slotAngle: 70).offset(x: -5.5, y: 5.5) }
            .overlay(alignment: .bottomLeading) { FCUScrew(slotAngle: 115).offset(x: 5.5, y: -5.5) }
            .overlay(alignment: .bottomTrailing) { FCUScrew(slotAngle: 20).offset(x: -5.5, y: -5.5) }
    }
}

/// A recessed panel fastener: a countersink shaded as a hollow, a domed
/// head lit from the top left, and its slot.
struct FCUScrew: View {
    var size: CGFloat = 8
    var slotAngle: Double = 40

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.15), .white.opacity(0.22)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.74), Color(white: 0.50), Color(white: 0.30)],
                                     center: UnitPoint(x: 0.35, y: 0.30), startRadius: 0, endRadius: size * 0.42))
                .padding(size * 0.14)
                .shadow(color: .black.opacity(0.4), radius: 0.4, x: 0.3, y: 0.4)
            ZStack {
                Capsule().fill(Color(white: 0.14)).frame(width: size * 0.60, height: size * 0.13)
                Capsule().fill(Color.white.opacity(0.30)).frame(width: size * 0.52, height: size * 0.045)
                    .offset(y: size * 0.07)
            }
            .rotationEffect(.degrees(slotAngle))
        }
        .frame(width: size, height: size)
    }
}

/// A legend printed on the panel: white, in a medium-bold grotesque, with
/// the faint edge a printed legend has on satin paint.
struct FCULegend: View {
    let text: String
    var size: CGFloat = 9
    var color: Color = FCUColors.airbusLegend

    init(_ text: String, size: CGFloat = 9, color: Color = FCUColors.airbusLegend) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .tracking(size * 0.025)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineSpacing(-1)
            .fixedSize()
            .shadow(color: .black.opacity(0.30), radius: 0.3, x: 0.3, y: 0.5)
    }
}

// MARK: - Segment digits

/// Seven-segment LCD characters, drawn rather than set in a font: digits,
/// '-', '+', ' ', the small raised 'o' of the Airbus V/S window, and the
/// few letters "Std" needs. The text is right-aligned in `cells` places.
/// `ghost` draws every segment of every cell faintly underneath, as the
/// unlit segments of a real LCD show against its glass.
struct SegmentText: View {
    let text: String
    var cells: Int
    var height: CGFloat
    var color: Color
    var ghost: Double = 0

    private var cellWidth: CGFloat { height * 0.5 }
    private var gap: CGFloat { height * 0.17 }
    var width: CGFloat { CGFloat(cells) * cellWidth + CGFloat(max(0, cells - 1)) * gap }

    var body: some View {
        let chars = Array(text.suffix(cells))
        let pad = cells - chars.count
        ZStack {
            if ghost > 0 {
                Canvas { ctx, _ in
                    for i in 0..<cells {
                        let x = CGFloat(i) * (cellWidth + gap)
                        // The raised 'o' cells (Airbus V/S hundreds) hold
                        // only the upper loop; every other cell a full 8.
                        let shown: Character? = i >= pad ? chars[i - pad] : nil
                        for path in Self.paths(for: shown == "o" ? "o" : "8", x: x, w: cellWidth, h: height) {
                            ctx.fill(path, with: .color(color.opacity(ghost)))
                        }
                    }
                }
            }
            Canvas { ctx, _ in
                for (i, ch) in chars.enumerated() {
                    let x = CGFloat(i + pad) * (cellWidth + gap)
                    for path in Self.paths(for: ch, x: x, w: cellWidth, h: height) {
                        ctx.fill(path, with: .color(color))
                    }
                }
            }
            // The glow: tight around the segments, then a soft bloom.
            .shadow(color: color.opacity(0.75), radius: 0.8)
            .shadow(color: color.opacity(0.35), radius: 3.5)
        }
        .frame(width: width, height: height)
    }

    // Segments: a top, b top right, c bottom right, d bottom, e bottom
    // left, f top left, g middle.
    private static func segments(_ ch: Character) -> String {
        switch ch {
        case "0": return "abcdef"
        case "1": return "bc"
        case "2": return "abged"
        case "3": return "abgcd"
        case "4": return "fgbc"
        case "5", "S": return "afgcd"
        case "6": return "afgedc"
        case "7": return "abc"
        case "8": return "abcdefg"
        case "9": return "abcdfg"
        case "-": return "g"
        case "o": return "abfg"
        case "t": return "fged"
        case "d": return "bcdeg"
        default: return ""
        }
    }

    private static func paths(for ch: Character, x: CGFloat, w: CGFloat, h: CGFloat) -> [Path] {
        let t = h * 0.13, inset = t * 0.22
        let xL = x + t / 2, xR = x + w - t / 2
        let yT = t / 2, yM = h / 2, yB = h - t / 2

        func horizontal(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) -> Path {
            let a = x0 + inset, b = x1 - inset
            return Path { p in
                p.move(to: CGPoint(x: a, y: y))
                p.addLine(to: CGPoint(x: a + t / 2, y: y - t / 2))
                p.addLine(to: CGPoint(x: b - t / 2, y: y - t / 2))
                p.addLine(to: CGPoint(x: b, y: y))
                p.addLine(to: CGPoint(x: b - t / 2, y: y + t / 2))
                p.addLine(to: CGPoint(x: a + t / 2, y: y + t / 2))
                p.closeSubpath()
            }
        }
        func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Path {
            let a = y0 + inset, b = y1 - inset
            return Path { p in
                p.move(to: CGPoint(x: x, y: a))
                p.addLine(to: CGPoint(x: x + t / 2, y: a + t / 2))
                p.addLine(to: CGPoint(x: x + t / 2, y: b - t / 2))
                p.addLine(to: CGPoint(x: x, y: b))
                p.addLine(to: CGPoint(x: x - t / 2, y: b - t / 2))
                p.addLine(to: CGPoint(x: x - t / 2, y: a + t / 2))
                p.closeSubpath()
            }
        }

        if ch == "+" {
            let half = h * 0.27
            return [horizontal(yM, x - t * 0.2, x + w + t * 0.2), vertical(x + w / 2, yM - half, yM + half)]
        }
        return segments(ch).map { s -> Path in
            switch s {
            case "a": return horizontal(yT, xL, xR)
            case "g": return horizontal(yM, xL, xR)
            case "d": return horizontal(yB, xL, xR)
            case "f": return vertical(xL, yT, yM)
            case "b": return vertical(xR, yT, yM)
            case "e": return vertical(xL, yM, yB)
            default: return vertical(xR, yM, yB)
            }
        }
    }
}

/// An LCD window: the glass behind its frame. On the A320 the frame is a
/// darker grey-blue inset cut into the panel and the glass a dark
/// grey-green; on the 737NG the frame is a black mask and the glass black.
/// The frame lies outside `width` × `height`, so the layout is the glass.
struct LCDWindow<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    var boeing: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        let glass = RoundedRectangle(cornerRadius: 2, style: .continuous)
        ZStack(alignment: .topLeading) {
            glass.fill(LinearGradient(colors: boeing ? [FCUColors.boeingGlassTop, FCUColors.boeingGlassBottom]
                                                     : [FCUColors.airbusGlassTop, FCUColors.airbusGlassBottom],
                                      startPoint: .top, endPoint: .bottom))
            content
            // The glass: a faint reflection from the top left, and the
            // shadow the frame casts on it along the top.
            glass.fill(LinearGradient(stops: [.init(color: .white.opacity(0.07), location: 0),
                                              .init(color: .white.opacity(0.02), location: 0.45),
                                              .init(color: .clear, location: 0.7)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
            glass.strokeBorder(LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.35), .white.opacity(0.06)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1.6)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipShape(glass)
        .background(frame)
    }

    @ViewBuilder private var frame: some View {
        let pad: CGFloat = boeing ? 3.5 : 4
        let outer = RoundedRectangle(cornerRadius: 2 + pad, style: .continuous)
        ZStack {
            if boeing {
                // The black mask, its outer edge catching the light.
                outer.fill(LinearGradient(colors: [Color(white: 0.04), Color(white: 0.10)],
                                          startPoint: .top, endPoint: .bottom))
                outer.strokeBorder(LinearGradient(colors: [.black.opacity(0.8), .white.opacity(0.22)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            } else {
                // The inset cut into the panel: in shadow under the top and
                // left lips, lit on the far walls.
                outer.fill(FCUColors.airbusBezel)
                outer.fill(LinearGradient(colors: [.black.opacity(0.45), .clear, .white.opacity(0.12)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                outer.strokeBorder(LinearGradient(colors: [.black.opacity(0.65), .white.opacity(0.28)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9)
            }
        }
        .padding(-pad)
    }
}

/// An LCD annunciation: lit in the digits' colour, or a faint ghost of
/// itself, as an LCD's unlit legend shows against the glass.
struct LCDLabel: View {
    let text: String
    var lit: Bool = true
    var size: CGFloat = 9
    var color: Color = FCUColors.airbusDigits

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.03)
            .foregroundStyle(color.opacity(lit ? 1 : 0.08))
            .fixedSize()
            .shadow(color: lit ? color.opacity(0.55) : .clear, radius: 1.2)
    }
}

// MARK: - Turning

/// Drag up or down to turn, about one detent per 9 screen points however
/// the panel is scaled; tap to push, hold to pull (when the knob does).
struct FCUTurnable<Content: View>: View {
    var stepPoints: CGFloat = 9
    var onTurn: (Int) -> Void
    var onPush: (() -> Void)? = nil
    var onPull: (() -> Void)? = nil
    @ViewBuilder var content: (_ turns: Int) -> Content

    @State private var turns = 0
    @State private var applied = 0
    private let haptics = UISelectionFeedbackGenerator()

    var body: some View {
        content(turns)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        let steps = Int((-value.translation.height / stepPoints).rounded(.towardZero))
                        let delta = steps - applied
                        guard delta != 0 else { return }
                        applied = steps
                        turns += delta
                        haptics.selectionChanged()
                        onTurn(delta)
                    }
                    .onEnded { _ in applied = 0 }
            )
            .onTapGesture {
                guard let onPush else { return }
                haptics.selectionChanged()
                onPush()
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                guard let onPull else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onPull()
            }
    }
}

// MARK: - Knobs

/// How much a surface whose outward direction is `angle` (degrees
/// clockwise from the top) faces the light at the top left: 0...1.
private func fcuFacing(_ degrees: Double) -> Double {
    let a = degrees * .pi / 180
    // Outward (sin a, -cos a) against the light's direction (-0.707, -0.707).
    return max(0, (-sin(a) + cos(a)) * 0.7071)
}

/// A round knob as on the real units: a metallic-black cylinder with a
/// finely knurled skirt, a flat top with a chamfered edge, and the shadow
/// it casts down and to the right. The knurling (and the index line, when
/// there is one) turns with the knob; the light stays where it is.
struct KnurledKnob: View {
    var diameter: CGFloat
    var turns: Int
    var ridges: Int = 40
    /// Degrees per detent.
    var detent: Double = 4.5
    var skirt: Color = Color(white: 0.10)
    var cap: [Color] = [Color(white: 0.30), Color(white: 0.09)]
    /// A white index line on the cap, for knobs that have one.
    var index = false

    var body: some View {
        let angle = Double(turns) * detent
        let d = diameter
        let top = d * 0.74
        ZStack {
            // Cast shadow.
            Circle().fill(Color.black.opacity(0.65))
                .frame(width: d * 1.02, height: d * 1.02)
                .offset(x: d * 0.035, y: d * 0.065)
                .blur(radius: d * 0.035)
            // The skirt's body: dark metal, lit from the top left.
            Circle().fill(LinearGradient(colors: [skirt.opacity(1), skirt, .black],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.4)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            knurl(angle: angle)
            // The skirt's rim catching the light.
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04), .black.opacity(0.6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: max(0.6, d * 0.014))
            // The groove under the top, then the flat top: satin black,
            // a chamfer lit top left and shaded bottom right.
            Circle().fill(Color.black.opacity(0.75)).frame(width: top + d * 0.035, height: top + d * 0.035)
            Circle()
                .fill(LinearGradient(colors: cap, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: top, height: top)
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.13), .white.opacity(0.03), .clear],
                                     center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: top * 0.6))
                .frame(width: top, height: top)
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .black.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: max(0.8, d * 0.025))
                .frame(width: top, height: top)
            if index {
                ZStack {
                    Capsule().fill(Color.black.opacity(0.5))
                        .frame(width: max(1.6, d * 0.042), height: d * 0.25)
                        .offset(x: 0.4, y: 0.6)
                    Capsule().fill(Color.white)
                        .frame(width: max(1.5, d * 0.038), height: d * 0.25)
                }
                .offset(y: -d * 0.215)
                .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: d, height: d)
    }

    /// The knurl: fine ridges round the skirt, each lit by how much it
    /// faces the light, with the groove beside it in shadow.
    private func knurl(angle: Double) -> some View {
        let count = max(ridges, Int(diameter * 1.3))
        return Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = size.width / 2
            let pitch = 2 * .pi * r * 0.9 / CGFloat(count)
            for i in 0..<count {
                let deg = Double(i) / Double(count) * 360 + angle
                let a = deg * .pi / 180
                let dx = CGFloat(sin(a)), dy = CGFloat(-cos(a))
                var ridge = Path()
                ridge.move(to: CGPoint(x: c.x + dx * r * 0.78, y: c.y + dy * r * 0.78))
                ridge.addLine(to: CGPoint(x: c.x + dx * r * 0.975, y: c.y + dy * r * 0.975))
                let light = fcuFacing(deg)
                ctx.stroke(ridge, with: .color(.white.opacity(0.07 + 0.38 * light * light)),
                           lineWidth: max(0.5, pitch * 0.42))
                let g = (deg + 180 / Double(count)) * .pi / 180
                let gx = CGFloat(sin(g)), gy = CGFloat(-cos(g))
                var groove = Path()
                groove.move(to: CGPoint(x: c.x + gx * r * 0.78, y: c.y + gy * r * 0.78))
                groove.addLine(to: CGPoint(x: c.x + gx * r * 0.975, y: c.y + gy * r * 0.975))
                ctx.stroke(groove, with: .color(.black.opacity(0.55)), lineWidth: max(0.4, pitch * 0.3))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The flat selector ring round a knob (the A320 ALT knob's 100 / 1000
/// ring and baro ring, the 737's bank-angle selector): satin black, lit
/// from the top left, with a raised tab (`tabLength`) or, nil, a white
/// index line on the band, at `tabAngle`.
struct SelectorRing: View {
    var outer: CGFloat
    var band: CGFloat
    var tabAngle: Double
    var tabLength: CGFloat? = 12
    /// Shade the space inside the ring as the recess the knob stands in.
    var recessInside = false

    var body: some View {
        let inner = outer - 2 * band
        ZStack {
            if recessInside {
                Circle().fill(LinearGradient(colors: [Color(white: 0.02), Color(white: 0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: inner, height: inner)
            }
            Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: band + 1)
                .frame(width: outer + 2, height: outer + 2)
                .offset(x: 1.2, y: 2)
                .blur(radius: 1.5)
            Circle().strokeBorder(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14), Color(white: 0.06)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: band)
                .frame(width: outer, height: outer)
            // The band's top face: a soft sheen across its upper left.
            Circle().strokeBorder(RadialGradient(colors: [.white.opacity(0.10), .clear],
                                                 center: UnitPoint(x: 0.25, y: 0.2), startRadius: 0, endRadius: outer * 0.7),
                                  lineWidth: band)
                .frame(width: outer, height: outer)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .black.opacity(0.6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                .frame(width: outer, height: outer)
            Circle().strokeBorder(LinearGradient(colors: [.black.opacity(0.7), .white.opacity(0.2)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                .frame(width: inner + 1.6, height: inner + 1.6)
            if let tabLength {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.16), Color(white: 0.09)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .black.opacity(0.6)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.7))
                    .overlay(Capsule().fill(Color.white).frame(width: 1.8, height: tabLength * 0.55))
                    .frame(width: band + 2.5, height: tabLength)
                    .shadow(color: .black.opacity(0.55), radius: 1, x: 0.8, y: 1.2)
                    .offset(y: -outer / 2 + tabLength / 2 - 3)
                    .rotationEffect(.degrees(tabAngle))
            } else {
                Capsule().fill(Color.white)
                    .frame(width: 2.2, height: band * 0.8)
                    .offset(y: -(outer - band) / 2)
                    .rotationEffect(.degrees(tabAngle))
            }
        }
        .frame(width: outer, height: outer)
    }
}

/// A rotary selector with a pointer line and its positions printed round
/// it, each with a tick. `selected` nil draws a plain knob — for a
/// selector whose setting lives elsewhere (the ND range, set on the ND
/// itself).
struct PointerSelector: View {
    let labels: [String]
    let angles: [Double]
    let selected: Int?
    var diameter: CGFloat = 30
    var labelRadius: CGFloat = 27
    var legend: Color = FCUColors.airbusLegend
    var labelSize: CGFloat = 7
    /// A legend on the knob's centre (the 737's CTR and TFC buttons).
    var center: String? = nil

    var body: some View {
        ZStack {
            ForEach(labels.indices, id: \.self) { i in
                let a = angles[i] * .pi / 180
                Text(labels[i])
                    .font(.system(size: labelSize, weight: .semibold))
                    .tracking(labelSize * 0.03)
                    .foregroundStyle(legend.opacity(selected == nil ? 0.6 : 1))
                    .fixedSize()
                    .shadow(color: .black.opacity(0.3), radius: 0.3, x: 0.3, y: 0.5)
                    .offset(x: CGFloat(sin(a)) * labelRadius, y: -CGFloat(cos(a)) * labelRadius)
            }
            KnurledKnob(diameter: diameter, turns: 0, ridges: 36, cap: [Color(white: 0.27), Color(white: 0.08)])
            if let selected {
                ZStack {
                    Capsule().fill(Color.black.opacity(0.5)).frame(width: 2.4, height: diameter * 0.44)
                        .offset(x: 0.4, y: 0.6)
                    Capsule().fill(Color.white).frame(width: 2.2, height: diameter * 0.44)
                }
                .offset(y: -diameter * 0.26)
                .rotationEffect(.degrees(angles[selected]))
            }
            if let center {
                Text(center)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(legend.opacity(0.95))
                    .frame(width: diameter * 0.62, height: diameter * 0.62)
                    .background(
                        Circle().fill(RadialGradient(colors: [Color(white: 0.26), Color(white: 0.10)],
                                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0,
                                                     endRadius: diameter * 0.4))
                    )
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [.black.opacity(0.9), .white.opacity(0.25)],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                                   lineWidth: 1))
            }
        }
        .frame(width: labelRadius * 2 + 24, height: labelRadius * 2 + 14)
    }
}

/// Evenly spread angles, in degrees clockwise from the top.
func fcuArc(_ count: Int, from start: Double, to end: Double) -> [Double] {
    guard count > 1 else { return [start] }
    return (0..<count).map { start + (end - start) * Double($0) / Double(count - 1) }
}

// MARK: - Pushbutton caps

/// A pushbutton cap standing in its recess: dark grey plastic with a
/// slight gloss over the upper half, a lit top-left edge, and the shadow
/// it casts into the recess.
struct FCUCap: View {
    var cornerRadius: CGFloat = 3
    /// The recess round the cap, in panel units.
    var recess: CGFloat = 2.5

    var body: some View {
        let cap = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius + recess, style: .continuous)
                .fill(LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.55), Color(white: 0.22).opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(-recess)
            cap.fill(LinearGradient(colors: [Color(white: 0.27), Color(white: 0.19), Color(white: 0.14)],
                                    startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.7), radius: 1.2, x: 0.6, y: 1.3)
            cap.fill(LinearGradient(stops: [.init(color: .white.opacity(0.13), location: 0),
                                            .init(color: .white.opacity(0.04), location: 0.42),
                                            .init(color: .clear, location: 0.6)],
                                    startPoint: .top, endPoint: .bottom))
            cap.strokeBorder(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.05), .black.opacity(0.6)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9)
        }
    }
}

/// A light bar behind a cap's lens: green with a near-white core and a
/// glow when lit; dark, the lens just catching the light, when off.
struct FCULightBar: View {
    var lit: Bool
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if lit {
                shape.fill(LinearGradient(colors: [FCUColors.lightGreenCore, FCUColors.lightGreen,
                                                   Color(red: 0.20, green: 0.80, blue: 0.32)],
                                          startPoint: .top, endPoint: .bottom))
                    .shadow(color: FCUColors.lightGreen.opacity(0.9), radius: 1.4)
                    .shadow(color: FCUColors.lightGreen.opacity(0.45), radius: 4.5)
            } else {
                shape.fill(LinearGradient(colors: [Color(red: 0.11, green: 0.13, blue: 0.12),
                                                   Color(red: 0.20, green: 0.23, blue: 0.21)],
                                          startPoint: .top, endPoint: .bottom))
                shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center))
            }
            shape.strokeBorder(Color.black.opacity(lit ? 0.25 : 0.6), lineWidth: 0.5)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Airbus pushbuttons

/// The A320 FCU pushbutton: a dark square cap, its legend on top and the
/// three green segments under it that light when the function is engaged.
/// `action` nil leaves it on the panel but inert.
struct AirbusPushbutton: View {
    let legend: String
    var lit: Bool = false
    var width: CGFloat = 48
    var height: CGFloat = 40
    var action: (() -> Void)?

    var body: some View {
        let cap = VStack(spacing: height * 0.09) {
            Text(legend)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(FCUColors.airbusLegend.opacity(action == nil ? 0.8 : 1))
                .multilineTextAlignment(.center)
                .lineSpacing(-2)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 0.3, y: 0.6)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    FCULightBar(lit: lit, width: width * 0.19, height: 3.6, cornerRadius: 0.8)
                }
            }
        }
        .frame(width: width, height: height)
        .background(FCUCap(cornerRadius: 3, recess: 2.5))

        if let action {
            Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() }) { cap }
                .buttonStyle(FCUPressStyle())
        } else {
            cap
        }
    }
}

/// The FCU's small round momentary buttons (SPD MACH, HDG V/S - TRK FPA),
/// legends printed on the panel beside them: a domed black cap in a
/// recessed collar.
struct AirbusRoundButton: View {
    var diameter: CGFloat = 24
    var action: (() -> Void)?

    var body: some View {
        let cap = ZStack {
            Circle().fill(LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.4), .white.opacity(0.18)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: diameter + 5, height: diameter + 5)
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.36), Color(white: 0.15), Color(white: 0.06)],
                                     center: UnitPoint(x: 0.36, y: 0.30), startRadius: 0, endRadius: diameter * 0.62))
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.6), radius: 1, x: 0.5, y: 1)
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: diameter * 0.5, height: diameter * 0.26)
                .offset(x: -diameter * 0.08, y: -diameter * 0.22)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .black.opacity(0.6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                .frame(width: diameter, height: diameter)
        }
        if let action {
            Button(action: action) { cap }.buttonStyle(FCUPressStyle())
        } else {
            cap
        }
    }
}

// MARK: - Boeing pushbuttons

/// The 737 MCP pushbutton: a dark rectangular cap with the light bar above
/// the legend. `lit` nil draws no bar (momentary buttons without one);
/// `action` nil leaves it on the panel but inert.
struct BoeingPushbutton: View {
    let legend: String
    var lit: Bool? = false
    var width: CGFloat = 52
    var height: CGFloat = 38
    var fontSize: CGFloat = 10
    var action: (() -> Void)?

    var body: some View {
        let cap = VStack(spacing: 3) {
            if let lit {
                FCULightBar(lit: lit, width: width - 14, height: height * 0.2, cornerRadius: 1.2)
            }
            Text(legend)
                .font(.system(size: fontSize, weight: .bold))
                .tracking(0.2)
                .foregroundStyle(FCUColors.boeingLegend.opacity(action == nil ? 0.8 : 1))
                .multilineTextAlignment(.center)
                .lineSpacing(-2)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.5), radius: 0.3, y: 0.6)
        }
        .padding(.horizontal, 3)
        .frame(width: width, height: height)
        .background(FCUCap(cornerRadius: 2.5, recess: 2.5))

        if let action {
            Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() }) { cap }
                .buttonStyle(FCUPressStyle())
        } else {
            cap
        }
    }
}

/// An annunciator light on the 737 MCP (MA over the F/D switch, ARM over
/// the A/T switch): a small lens in a black frame, its legend dark on the
/// lit colour, or faint on the dark lens when off.
struct BoeingLight: View {
    let legend: String
    let lit: Bool
    var color: Color = FCUColors.lightGreen

    var body: some View {
        let lens = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        Text(legend)
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(lit ? Color.black.opacity(0.72) : Color(white: 0.42))
            .frame(width: 28, height: 14)
            .background(
                ZStack {
                    if lit {
                        lens.fill(LinearGradient(colors: [FCUColors.lightGreenCore, color], startPoint: .top, endPoint: .bottom))
                    } else {
                        lens.fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.17)], startPoint: .top, endPoint: .bottom))
                    }
                    lens.fill(LinearGradient(colors: [.white.opacity(lit ? 0.25 : 0.08), .clear], startPoint: .top, endPoint: .center))
                }
            )
            .overlay(lens.strokeBorder(Color.black.opacity(0.7), lineWidth: 0.8))
            .shadow(color: lit ? color.opacity(0.85) : .clear, radius: 1.5)
            .shadow(color: lit ? color.opacity(0.4) : .clear, radius: 5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(white: 0.05))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.black.opacity(0.8), .white.opacity(0.22)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
                    .padding(-2)
            )
    }
}

/// A toggle's bat-handle lever seen from the front, pointing up: a slim
/// shank from the pivot widening to the rounded paddle at its tip.
private struct BatHandle: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let shank = rect.width * 0.42
        let tip = rect.width
        let r = tip / 2
        var p = Path()
        p.move(to: CGPoint(x: cx - shank / 2, y: rect.maxY))
        p.addLine(to: CGPoint(x: cx - tip / 2, y: rect.minY + r))
        p.addArc(center: CGPoint(x: cx, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: cx + shank / 2, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The 737's bat-handle toggle (F/D, A/T ARM): lever up for on — a
/// polished metal lever on a hex nut, casting its shadow down and right.
struct BoeingToggle: View {
    let onLabel: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(); action() }) {
            VStack(spacing: 2) {
                FCULegend(onLabel, size: 8, color: FCUColors.boeingLegend)
                ZStack {
                    // Guard plate and hex mounting nut.
                    Circle().fill(LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.25), .white.opacity(0.12)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    hexNut.frame(width: 18, height: 18)
                    Circle().fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.22)],
                                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 6))
                        .frame(width: 9, height: 9)
                    // The lever's shadow on the panel, then the lever.
                    lever(shadow: true).offset(x: 2.2, y: isOn ? -8 : 13).blur(radius: 1.1)
                    lever(shadow: false).offset(y: isOn ? -10.5 : 10.5)
                }
                .frame(width: 34, height: 54)
                FCULegend("OFF", size: 8, color: FCUColors.boeingLegend)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var hexNut: some View {
        let hex = Path { p in
            for i in 0..<6 {
                let a = (Double(i) * 60 + 30) * .pi / 180
                let pt = CGPoint(x: 9 + 9 * cos(a), y: 9 + 9 * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
        return ZStack {
            hex.fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55), Color(white: 0.30)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
            hex.stroke(Color.black.opacity(0.55), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.5), radius: 0.8, x: 0.6, y: 1)
    }

    /// The lever, pointing up when on and down when off (flipped, so the
    /// light still comes from the left).
    private func lever(shadow: Bool) -> some View {
        ZStack(alignment: .top) {
            if shadow {
                BatHandle().fill(Color.black.opacity(0.5))
            } else {
                BatHandle().fill(LinearGradient(stops: [.init(color: Color(white: 0.50), location: 0),
                                                        .init(color: Color(white: 0.97), location: 0.32),
                                                        .init(color: Color(white: 0.70), location: 0.6),
                                                        .init(color: Color(white: 0.38), location: 1)],
                                                startPoint: .leading, endPoint: .trailing))
                BatHandle().stroke(Color.black.opacity(0.45), lineWidth: 0.5)
                // The rounded paddle end, catching the light on top.
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 5, height: 3)
                    .offset(x: -0.6, y: 0.8)
            }
        }
        .frame(width: 8, height: 21)
        .scaleEffect(x: 1, y: isOn ? 1 : -1)
    }
}

/// The 737's V/S thumbwheel: a ribbed wheel in a slot, DN at the top and
/// UP at the bottom — rolling the top of the wheel away (a drag upward)
/// is nose down.
struct BoeingThumbwheel: View {
    var onTurn: (Int) -> Void

    var body: some View {
        VStack(spacing: 3) {
            FCULegend("DN", size: 8, color: FCUColors.boeingLegend)
            FCUTurnable(stepPoints: 7, onTurn: { onTurn(-$0) }) { turns in
                ZStack {
                    // The slot: a hollow, dark under its top lip, its far
                    // edge catching the light.
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.02), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.black.opacity(0.8), .white.opacity(0.28)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                        .frame(width: 30, height: 64)
                    Canvas { ctx, size in
                        // Ribs on a cylinder: closer together towards the
                        // top and bottom edges, as they turn away; each a
                        // lit crest with its shadowed flank under it.
                        let ribs = 16
                        let phase = Double(turns).truncatingRemainder(dividingBy: 2) * 0.5
                        for i in 0..<ribs {
                            let u = (Double(i) + phase) / Double(ribs)      // 0...1 around the half turn
                            let y = size.height / 2 - CGFloat(cos(u * .pi)) * size.height / 2
                            let shade = sin(u * .pi)
                            // Lit from above: crests on the upper half catch more.
                            let lift = 1 - 0.45 * u
                            var crest = Path()
                            crest.move(to: CGPoint(x: 1.5, y: y))
                            crest.addLine(to: CGPoint(x: size.width - 1.5, y: y))
                            ctx.stroke(crest, with: .color(.white.opacity((0.06 + 0.40 * shade) * lift)),
                                       lineWidth: 0.6 + 0.9 * shade)
                            var flank = Path()
                            flank.move(to: CGPoint(x: 1.5, y: y + 1.1 * shade + 0.4))
                            flank.addLine(to: CGPoint(x: size.width - 1.5, y: y + 1.1 * shade + 0.4))
                            ctx.stroke(flank, with: .color(.black.opacity(0.6 * shade)), lineWidth: 0.6 + 0.6 * shade)
                        }
                    }
                    .frame(width: 22, height: 56)
                    .background(LinearGradient(stops: [.init(color: Color(white: 0.02), location: 0),
                                                       .init(color: Color(white: 0.20), location: 0.35),
                                                       .init(color: Color(white: 0.14), location: 0.6),
                                                       .init(color: Color(white: 0.02), location: 1)],
                                               startPoint: .top, endPoint: .bottom))
                    .overlay(LinearGradient(colors: [.white.opacity(0.05), .clear, .black.opacity(0.35)],
                                            startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            FCULegend("UP", size: 8, color: FCUColors.boeingLegend)
        }
    }
}

/// The 737's A/P DISENGAGE bar: a light metal bar in its slot; pulled
/// down, it shows its yellow and black stripes and drops both autopilots.
struct DisengageBar: View {
    var width: CGFloat = 116
    var action: () -> Void
    @State private var down = false

    var body: some View {
        ZStack(alignment: .top) {
            // The slot the bar slides in.
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.03), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.black.opacity(0.8), .white.opacity(0.25)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
                .frame(width: width + 2, height: down ? 25 : 17)
                .offset(y: -1.5)
            // The striped face uncovered when the bar is down.
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.95, green: 0.78, blue: 0.1)))
                var x: CGFloat = -size.height
                while x < size.width {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    p.addLine(to: CGPoint(x: x + size.height + 5, y: 0))
                    p.addLine(to: CGPoint(x: x + 5, y: size.height))
                    ctx.fill(p, with: .color(.black))
                    x += 10
                }
            }
            .frame(width: width - 8, height: 8)
            .offset(y: 1)
            .opacity(down ? 1 : 0)
            // The bar: brushed light metal, bevelled, lit from above.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(stops: [.init(color: Color(white: 0.92), location: 0),
                                             .init(color: Color(white: 0.80), location: 0.45),
                                             .init(color: Color(white: 0.62), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.25), .clear, .black.opacity(0.12)],
                                         startPoint: .leading, endPoint: .trailing)))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .black.opacity(0.55)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.9))
                .shadow(color: .black.opacity(0.55), radius: 1.2, x: 0.6, y: 1.5)
                .frame(width: width, height: 14)
                .offset(y: down ? 9 : 0)
        }
        .frame(width: width, height: 24, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation(.easeOut(duration: 0.12)) { down = true }
            action()
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.easeIn(duration: 0.2)) { down = false }
            }
        }
    }
}

/// Pushbuttons sink a little while held.
struct FCUPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}

/// Text first, then the icon — for the DISPLAYS button at the right edge.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Layout helpers

/// A block of panel of fixed size whose parts are placed by their centres.
struct PanelBlock<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) { content }
            .frame(width: width, height: height)
    }
}

/// Shows a view laid out at `size` scaled uniformly to the space it is
/// given, centred.
struct FittedPanel<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let scale = max(0.1, min(geo.size.width / size.width, geo.size.height / size.height))
            content
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
