import SwiftUI
import UIKit

// The parts the glareshield panels are built from: plates, LCD windows
// with segment digits, knobs, pushbuttons, switches and the thumbwheel.
// Our own drawing, matched to photographs of the real units, sized in
// panel units — the panels are laid out at a fixed size and scaled as a
// whole to the screen. All vector: paths, gradients and shadows, with the
// light falling from the top left everywhere, and the knobs seen a little
// from below, as from the seat: the top face of a knob sits a little
// above its base, with the knurled side showing under it.

// MARK: - Colours

enum FCUColors {
    // A320: a slate blue-grey panel, white legends, pale grey knobs in
    // polished bezel rings, black pushbutton caps, and orange-amber LCD
    // digits on near-black glass.
    static let airbusPanelTop = Color(red: 0.300, green: 0.365, blue: 0.410)
    static let airbusPanel = Color(red: 0.265, green: 0.325, blue: 0.370)
    static let airbusPanelBottom = Color(red: 0.230, green: 0.285, blue: 0.325)
    /// The black surround each LCD window sits in.
    static let airbusBezel = Color(white: 0.035)
    static let airbusLegend = Color(white: 0.96)
    /// Legends on the black caps: white, a touch softer than the panel's.
    static let airbusCapLegend = Color(white: 0.90)
    static let airbusDigits = Color(red: 1.0, green: 0.60, blue: 0.17)
    static let airbusGlassTop = Color(red: 0.070, green: 0.058, blue: 0.048)
    static let airbusGlassBottom = Color(red: 0.035, green: 0.029, blue: 0.025)
    /// The knobs' pale grey plastic.
    static let airbusKnob = FCUTone(0.735, 0.740, 0.715)
    /// The three green lines of a lit FCU pushbutton.
    static let airbusLight = Color(red: 0.55, green: 1.0, blue: 0.36)
    static let airbusLightCore = Color(red: 0.88, green: 1.0, blue: 0.80)
    /// The HDG knob's triangle.
    static let airbusHeadingBlue = Color(red: 0.13, green: 0.30, blue: 0.86)

    // 737NG: a medium neutral grey panel, white legends, very pale grey
    // knurled knobs, black-framed switches with dark grey faces whose
    // light bar comes on amber-yellow, and white LCD digits.
    static let boeingPanelTop = Color(red: 0.375, green: 0.385, blue: 0.400)
    static let boeingPanel = Color(red: 0.335, green: 0.345, blue: 0.360)
    static let boeingPanelBottom = Color(red: 0.295, green: 0.305, blue: 0.320)
    static let boeingLegend = Color(white: 0.96)
    static let boeingDigits = Color(red: 0.93, green: 0.95, blue: 0.97)
    static let boeingGlassTop = Color(white: 0.050)
    static let boeingGlassBottom = Color(white: 0.020)
    static let boeingKnob = FCUTone(0.800, 0.800, 0.785)
    /// A switch's face, unlit.
    static let boeingCapFace = Color(red: 0.225, green: 0.230, blue: 0.245)
    /// The light bars and annunciators, lit.
    static let boeingLight = Color(red: 1.0, green: 0.80, blue: 0.16)
    static let boeingLightCore = Color(red: 1.0, green: 0.95, blue: 0.70)
    /// The COURSE knobs' cross.
    static let boeingCourseMark = Color(red: 1.0, green: 0.45, blue: 0.12)

    static let lcd = Color(red: 0.07, green: 0.06, blue: 0.05)
}

/// A colour that can be shaded lighter or darker, for the knobs' plastic.
struct FCUTone {
    let r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    /// Scaled by `k` (above 1 mixes towards white).
    func callAsFunction(_ k: Double = 1) -> Color {
        if k <= 1 { return Color(red: r * k, green: g * k, blue: b * k) }
        let t = min(1, k - 1)
        return Color(red: r + (1 - r) * t, green: g + (1 - g) * t, blue: b + (1 - b) * t)
    }
}

// MARK: - Type

/// The panels' lettering: Airbus prints its panels in a DIN-style
/// grotesque, Boeing in a geometric face of the Futura kind.
enum FCUTypeface {
    case airbus, boeing, boeingCondensed

    func font(_ size: CGFloat) -> Font {
        switch self {
        case .airbus: return .custom("DINAlternate-Bold", size: size)
        case .boeing: return .custom("Futura-Medium", size: size)
        case .boeingCondensed: return .custom("Futura-CondensedMedium", size: size)
        }
    }
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
                    shape.fill(RadialGradient(colors: [.white.opacity(0.07), .white.opacity(0.02), .clear],
                                              center: UnitPoint(x: 0.18, y: -0.25), startRadius: 0, endRadius: 520))
                    shape.fill(LinearGradient(colors: [.white.opacity(0.02), .clear, .black.opacity(0.06)],
                                              startPoint: .leading, endPoint: .trailing))
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.75), radius: 5, x: 2, y: 4)
            )
            // The edge bevel: lit along the top and left, shaded along the
            // bottom and right, and the fine line where it meets the face.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0),
                                           .init(color: .white.opacity(0.07), location: 0.35),
                                           .init(color: .black.opacity(0.10), location: 0.65),
                                           .init(color: .black.opacity(0.45), location: 1)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 2.0)
            )
            .overlay(
                shape.inset(by: 2.0).strokeBorder(Color.black.opacity(0.16), lineWidth: 0.6)
            )
            .overlay(shape.strokeBorder(Color.black.opacity(0.85), lineWidth: 0.8))
            .overlay(alignment: .topLeading) { FCUScrew(slotAngle: 35).offset(x: 5.5, y: 5.5) }
            .overlay(alignment: .topTrailing) { FCUScrew(slotAngle: 70).offset(x: -5.5, y: 5.5) }
            .overlay(alignment: .bottomLeading) { FCUScrew(slotAngle: 115).offset(x: 5.5, y: -5.5) }
            .overlay(alignment: .bottomTrailing) { FCUScrew(slotAngle: 20).offset(x: -5.5, y: -5.5) }
    }
}

/// A panel fastener: a small dark slotted head, nearly flush, lit along
/// its top left edge.
struct FCUScrew: View {
    var size: CGFloat = 7
    var slotAngle: Double = 40

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.45)).padding(-0.6)
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.42), Color(white: 0.26), Color(white: 0.16)],
                                     center: UnitPoint(x: 0.35, y: 0.30), startRadius: 0, endRadius: size * 0.55))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.30), .black.opacity(0.5)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
            Capsule().fill(Color(white: 0.06)).frame(width: size * 0.72, height: size * 0.15)
                .rotationEffect(.degrees(slotAngle))
        }
        .frame(width: size, height: size)
    }
}

/// A legend printed on the panel, white, in the maker's typeface.
struct FCULegend: View {
    let text: String
    var size: CGFloat = 9
    var color: Color = FCUColors.airbusLegend
    var face: FCUTypeface = .airbus

    init(_ text: String, size: CGFloat = 9, color: Color = FCUColors.airbusLegend, face: FCUTypeface = .airbus) {
        self.text = text
        self.size = size
        self.color = color
        self.face = face
    }

    var body: some View {
        Text(text)
            .font(face.font(size))
            .tracking(size * 0.02)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineSpacing(-size * 0.22)
            .fixedSize()
    }
}

// MARK: - Segment digits

/// Seven-segment LCD characters, drawn rather than set in a font: digits,
/// '-', '+', ' ', the small raised 'o' of the Airbus V/S window, and the
/// few letters "Std" needs. The text is right-aligned in `cells` places.
/// `ghost` draws every segment of every cell faintly underneath, as the
/// unlit segments of a real LCD show against its glass. `point` lights
/// the decimal point after that cell (counted from the left), as the
/// baro window's 29.92.
struct SegmentText: View {
    let text: String
    var cells: Int
    var height: CGFloat
    var color: Color
    var ghost: Double = 0
    var point: Int? = nil

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
                if let point {
                    let side = height * 0.12
                    let x = CGFloat(point + 1) * (cellWidth + gap) - gap / 2
                    ctx.fill(Path(CGRect(x: x - side / 2, y: height - side, width: side, height: side)),
                             with: .color(color))
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

/// An LCD window: near-black glass in a black surround, flush with the
/// panel. The surround lies outside `width` × `height`, so the layout is
/// the glass.
struct LCDWindow<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    var boeing: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        let glass = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        ZStack(alignment: .topLeading) {
            glass.fill(LinearGradient(colors: boeing ? [FCUColors.boeingGlassTop, FCUColors.boeingGlassBottom]
                                                     : [FCUColors.airbusGlassTop, FCUColors.airbusGlassBottom],
                                      startPoint: .top, endPoint: .bottom))
            content
            // The glass: a faint reflection from the top left.
            glass.fill(LinearGradient(stops: [.init(color: .white.opacity(0.05), location: 0),
                                              .init(color: .white.opacity(0.015), location: 0.45),
                                              .init(color: .clear, location: 0.7)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
            glass.strokeBorder(Color.black.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipShape(glass)
        .background(frame)
    }

    @ViewBuilder private var frame: some View {
        let pad: CGFloat = boeing ? 3.5 : 3
        let outer = RoundedRectangle(cornerRadius: 1.5 + pad, style: .continuous)
        ZStack {
            outer.fill(LinearGradient(colors: [Color(white: 0.02), Color(white: 0.07)],
                                      startPoint: .top, endPoint: .bottom))
            outer.strokeBorder(LinearGradient(colors: [.black.opacity(0.7), .white.opacity(0.16)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
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
            .font(FCUTypeface.airbus.font(size))
            .tracking(size * 0.06)
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

// MARK: - Knob drawing

/// The shapes and shading the knobs are drawn with, in a Canvas.
enum KnobDraw {
    /// The outline of a knob's top face.
    enum Edge {
        case plain
        /// Fine teeth round the rim, `depth` deep (a fraction of the radius).
        case teeth(Int, depth: CGFloat)
        /// Rounded lobes with sharp valleys between, as a scalloped knob.
        case lobes(Int, depth: CGFloat)
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    /// An annulus, filled even-odd.
    static func ring(_ c: CGPoint, _ outer: CGFloat, _ inner: CGFloat) -> Path {
        var p = circle(c, outer)
        p.addPath(circle(c, inner))
        return p
    }

    static func face(_ c: CGPoint, _ r: CGFloat, _ edge: Edge, rotation: Double) -> Path {
        switch edge {
        case .plain:
            return circle(c, r)
        case let .teeth(n, depth), let .lobes(n, depth):
            let lobed: Bool = { if case .lobes = edge { return true } else { return false } }()
            let steps = n * (lobed ? 12 : 6)
            return Path { p in
                for i in 0..<steps {
                    let t = Double(i) / Double(steps) * 2 * .pi
                    let k: Double = lobed
                        ? 1 - abs(cos(Double(n) * t / 2))       // V valleys, rounded lobes
                        : 0.5 + 0.5 * cos(Double(n) * t)        // even teeth
                    let rr = r * (1 - depth * CGFloat(k))
                    let a = t + rotation
                    let pt = CGPoint(x: c.x + rr * CGFloat(sin(a)), y: c.y - rr * CGFloat(cos(a)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
            }
        }
    }

    /// A cylinder standing on the panel at `base`, its top face lifted `lift`
    /// above it: the shadow it casts, the side (knurled with `ridges` when
    /// there are any), and the top face, shaded from the top left.
    static func cylinder(_ ctx: GraphicsContext, base c: CGPoint, radius r: CGFloat, lift h: CGFloat,
                         tone: FCUTone, edge: Edge = .plain, ridges: Int = 0, rotation: Double = 0,
                         shadow: Double = 0.55, faceShade: Bool = true) {
        let top = CGPoint(x: c.x, y: c.y - h)
        if shadow > 0 {
            var s = ctx
            s.addFilter(.blur(radius: max(0.6, r * 0.14)))
            s.fill(face(CGPoint(x: c.x + r * 0.10, y: c.y + r * 0.14), r * 1.02, edge, rotation: rotation),
                   with: .color(.black.opacity(shadow)))
        }
        // The side: the face swept from the base up to the top.
        let layers = max(2, Int(h / 0.6))
        let sideShade = Gradient(stops: [.init(color: tone(0.98), location: 0),
                                         .init(color: tone(0.84), location: 0.35),
                                         .init(color: tone(0.62), location: 0.75),
                                         .init(color: tone(0.48), location: 1)])
        for i in 0...layers {
            let y = c.y - h * CGFloat(i) / CGFloat(layers)
            ctx.fill(face(CGPoint(x: c.x, y: y), r, edge, rotation: rotation),
                     with: .linearGradient(sideShade, startPoint: CGPoint(x: c.x - r, y: y),
                                           endPoint: CGPoint(x: c.x + r, y: y)))
        }
        // Darker towards the panel, where less light reaches.
        ctx.fill(face(c, r, edge, rotation: rotation),
                 with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.22)]),
                                       startPoint: CGPoint(x: c.x, y: c.y), endPoint: CGPoint(x: c.x, y: c.y + r)))
        // The knurl: fine vertical ridges on the side that shows, each a
        // dark groove with a lit crest beside it, foreshortened towards
        // the edges.
        if ridges > 0, h > 0.5 {
            let pitch = 2 * .pi * r / CGFloat(ridges)
            for i in 0..<ridges {
                let t = Double(i) / Double(ridges) * 2 * .pi + rotation
                let s = sin(t)
                guard s > 0.08 else { continue }       // the half facing us
                let x = c.x + r * CGFloat(cos(t)) * 0.985
                let yBase = c.y + r * CGFloat(s) * 0.985
                let w = pitch * CGFloat(s)
                var groove = Path()
                groove.move(to: CGPoint(x: x, y: yBase - h))
                groove.addLine(to: CGPoint(x: x, y: yBase))
                ctx.stroke(groove, with: .color(.black.opacity(0.30)), lineWidth: max(0.25, w * 0.40))
                let lit = 0.5 - 0.5 * cos(t)           // the left side faces the light
                var crest = Path()
                crest.move(to: CGPoint(x: x - w * 0.45, y: yBase - h))
                crest.addLine(to: CGPoint(x: x - w * 0.45, y: yBase))
                ctx.stroke(crest, with: .color(.white.opacity(0.08 + 0.30 * lit)), lineWidth: max(0.2, w * 0.25))
            }
        }
        // The top face, lit from the top left, its edge a fine chamfer.
        let f = face(top, r, edge, rotation: rotation)
        ctx.fill(f, with: .linearGradient(Gradient(colors: [tone(1.10), tone(1.0), tone(0.86)]),
                                          startPoint: CGPoint(x: top.x - r, y: top.y - r),
                                          endPoint: CGPoint(x: top.x + r, y: top.y + r)))
        if faceShade {
            ctx.fill(f, with: .radialGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0.0)]),
                                              center: CGPoint(x: top.x - r * 0.35, y: top.y - r * 0.40),
                                              startRadius: 0, endRadius: r * 0.9))
        }
        ctx.stroke(f, with: .linearGradient(Gradient(colors: [.white.opacity(0.65), .white.opacity(0.1), .black.opacity(0.30)]),
                                            startPoint: CGPoint(x: top.x - r, y: top.y - r),
                                            endPoint: CGPoint(x: top.x + r, y: top.y + r)),
                   lineWidth: max(0.4, r * 0.045))
    }

    /// A polished metal bezel ring set in the panel, the reflections round
    /// it bright at the top left and bottom right, with the hairline
    /// shadow where it meets the panel.
    static func chromeRing(_ ctx: GraphicsContext, center c: CGPoint, outer: CGFloat, width: CGFloat) {
        ctx.fill(circle(c, outer + width * 0.35), with: .color(.black.opacity(0.35)))
        let chrome = Gradient(stops: [.init(color: Color(white: 0.96), location: 0.00),
                                      .init(color: Color(white: 0.58), location: 0.10),
                                      .init(color: Color(white: 0.30), location: 0.22),
                                      .init(color: Color(red: 0.62, green: 0.56, blue: 0.50), location: 0.34),
                                      .init(color: Color(white: 0.95), location: 0.47),
                                      .init(color: Color(white: 0.62), location: 0.58),
                                      .init(color: Color(white: 0.36), location: 0.72),
                                      .init(color: Color(white: 0.80), location: 0.86),
                                      .init(color: Color(white: 0.96), location: 1.00)])
        ctx.fill(ring(c, outer, outer - width), with: .conicGradient(chrome, center: c, angle: .degrees(-135)),
                 style: FillStyle(eoFill: true))
        ctx.stroke(circle(c, outer - width * 0.5), with: .color(.white.opacity(0.18)), lineWidth: width * 0.25)
        ctx.stroke(circle(c, outer - width), with: .color(.black.opacity(0.55)), lineWidth: 0.5)
    }
}

// MARK: - Airbus knobs

/// The A320 FCU and EFIS knobs: a pale grey knob in a polished bezel ring.
/// SPD and V/S stand on a wide pale skirt and have a toothed rim with a
/// white ring round the face; HDG is scalloped with a blue triangle; ALT
/// and the baro knob are plain cylinders in a black selector ring — ALT's
/// for 100 / 1000, the baro knob's for inHg / hPa — whose white dot is at
/// `selectorAngle`. The knob's teeth, lobes and markings turn with it; the
/// light stays where it is.
struct AirbusKnob: View {
    enum Kind { case speed, heading, altitude, verticalSpeed, baro }

    let kind: Kind
    /// The bezel ring's outer diameter.
    var diameter: CGFloat = 64
    var turns: Int = 0
    /// Degrees clockwise from the top.
    var selectorAngle: Double = 0
    /// Degrees per detent.
    var detent: Double = 9

    var body: some View {
        let d = diameter
        let rotation = Double(turns) * detent * .pi / 180
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = d / 2
                let bezel = d * 0.045
                KnobDraw.chromeRing(ctx, center: c, outer: outer, width: bezel)
                let inner = outer - bezel
                // The dark gap between bezel and knob.
                ctx.fill(KnobDraw.circle(c, inner), with: .color(Color(white: 0.04)))
                switch kind {
                case .speed, .heading, .verticalSpeed:
                    skirt(ctx, c, inner - d * 0.012)
                case .altitude, .baro:
                    selector(ctx, c, inner - d * 0.006)
                }
                cap(ctx, c, rotation)
            }
            if kind == .baro {
                // PULL STD, printed on the knob's face.
                Text("PULL\nSTD")
                    .font(FCUTypeface.airbus.font(d * 0.11))
                    .lineSpacing(-d * 0.035)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .fixedSize()
                    .rotationEffect(.radians(rotation))
                    .offset(y: -capLift)
            }
        }
        .frame(width: d, height: d)
    }

    private var capRadius: CGFloat {
        switch kind {
        case .speed: return diameter * 0.300
        case .verticalSpeed: return diameter * 0.315
        case .heading: return diameter * 0.320
        case .altitude: return diameter * 0.300
        case .baro: return diameter * 0.285
        }
    }

    private var capLift: CGFloat {
        switch kind {
        case .speed, .verticalSpeed: return diameter * 0.10
        case .heading: return diameter * 0.075
        case .altitude, .baro: return diameter * 0.11
        }
    }

    /// The wide pale skirt the SPD, HDG and V/S knobs stand on, in shadow
    /// under the bezel's top lip.
    private func skirt(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        let tone = FCUColors.airbusKnob
        let disc = KnobDraw.circle(c, r)
        ctx.fill(disc, with: .radialGradient(Gradient(colors: [tone(1.04), tone(0.92), tone(0.70)]),
                                             center: CGPoint(x: c.x - r * 0.30, y: c.y - r * 0.35),
                                             startRadius: 0, endRadius: r * 1.45))
        ctx.stroke(KnobDraw.circle(c, r * 0.93),
                   with: .linearGradient(Gradient(colors: [.black.opacity(0.35), .clear, .white.opacity(0.25)]),
                                         startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)),
                   lineWidth: r * 0.14)
    }

    /// The black selector ring the ALT and baro knobs stand in, with its
    /// white index dot.
    private func selector(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        let disc = KnobDraw.circle(c, r)
        ctx.fill(disc, with: .linearGradient(Gradient(colors: [Color(white: 0.17), Color(white: 0.07), Color(white: 0.03)]),
                                             startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)))
        ctx.stroke(KnobDraw.circle(c, r * 0.97),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .clear, .white.opacity(0.10)]),
                                         startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)),
                   lineWidth: r * 0.06)
        let a = selectorAngle * .pi / 180
        let dr = r * 0.88
        let dot = CGPoint(x: c.x + dr * CGFloat(sin(a)), y: c.y - dr * CGFloat(cos(a)))
        ctx.fill(KnobDraw.circle(dot, diameter * 0.025), with: .color(Color(white: 0.92)))
    }

    private func cap(_ ctx: GraphicsContext, _ c: CGPoint, _ rotation: Double) {
        let r = capRadius, h = capLift
        let tone = FCUColors.airbusKnob
        switch kind {
        case .speed, .verticalSpeed:
            KnobDraw.cylinder(ctx, base: c, radius: r, lift: h, tone: tone,
                              edge: .teeth(28, depth: 0.10), ridges: 28, rotation: rotation, shadow: 0.45)
            // The white ring round the face, and the face inside it.
            let top = CGPoint(x: c.x, y: c.y - h)
            ctx.stroke(KnobDraw.circle(top, r * 0.79), with: .color(Color(white: 0.97)), lineWidth: r * 0.12)
            ctx.fill(KnobDraw.circle(top, r * 0.73),
                     with: .linearGradient(Gradient(colors: [tone(1.02), tone(0.93), tone(0.88)]),
                                           startPoint: CGPoint(x: top.x - r, y: top.y - r), endPoint: CGPoint(x: top.x + r, y: top.y + r)))
            ctx.stroke(KnobDraw.circle(top, r * 0.73),
                       with: .linearGradient(Gradient(colors: [.black.opacity(0.25), .clear]),
                                             startPoint: CGPoint(x: top.x, y: top.y - r), endPoint: CGPoint(x: top.x, y: top.y + r)),
                       lineWidth: r * 0.05)
        case .heading:
            KnobDraw.cylinder(ctx, base: c, radius: r, lift: h, tone: tone,
                              edge: .lobes(10, depth: 0.15), rotation: rotation, shadow: 0.45)
            // The blue triangle, its apex at the knob's index.
            let top = CGPoint(x: c.x, y: c.y - h)
            let tr = r * 0.50
            let tri = Path { p in
                for k in 0..<3 {
                    let a = rotation + Double(k) * 2 * .pi / 3
                    let pt = CGPoint(x: top.x + tr * CGFloat(sin(a)), y: top.y + r * 0.08 - tr * CGFloat(cos(a)))
                    if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
            }
            ctx.stroke(tri, with: .color(FCUColors.airbusHeadingBlue),
                       style: StrokeStyle(lineWidth: r * 0.085, lineJoin: .round))
        case .altitude, .baro:
            KnobDraw.cylinder(ctx, base: c, radius: r, lift: h, tone: tone,
                              edge: .plain, ridges: 40, rotation: rotation, shadow: 0.6)
        }
    }
}

/// The A320 EFIS's ND mode and range selectors: a pale grey knob in a
/// polished bezel, a raised pointer bar across its face, and its
/// positions printed round it, each on a tick of a thin printed arc.
struct AirbusSelector: View {
    let labels: [String]
    let angles: [Double]
    /// Where the pointer points, degrees clockwise from the top.
    var pointer: Double
    var diameter: CGFloat = 30
    var labelRadius: CGFloat = 26
    var labelSize: CGFloat = 7
    /// Tapping a position's label turns the selector to it.
    var onSelect: ((Int) -> Void)? = nil

    var body: some View {
        let d = diameter
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                // The printed arc and its ticks.
                if let first = angles.first, let last = angles.last {
                    let ar = d / 2 + 2.5
                    let arc = Path { p in
                        let n = 40
                        for i in 0...n {
                            let a = (first + (last - first) * Double(i) / Double(n)) * .pi / 180
                            let pt = CGPoint(x: c.x + ar * CGFloat(sin(a)), y: c.y - ar * CGFloat(cos(a)))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    ctx.stroke(arc, with: .color(FCUColors.airbusLegend.opacity(0.9)), lineWidth: 0.7)
                    for deg in angles {
                        let a = deg * .pi / 180
                        var tick = Path()
                        tick.move(to: CGPoint(x: c.x + ar * CGFloat(sin(a)), y: c.y - ar * CGFloat(cos(a))))
                        tick.addLine(to: CGPoint(x: c.x + (ar + 2.6) * CGFloat(sin(a)), y: c.y - (ar + 2.6) * CGFloat(cos(a))))
                        ctx.stroke(tick, with: .color(FCUColors.airbusLegend.opacity(0.9)), lineWidth: 0.8)
                    }
                }
                let outer = d / 2
                KnobDraw.chromeRing(ctx, center: c, outer: outer, width: d * 0.05)
                ctx.fill(KnobDraw.circle(c, outer - d * 0.05), with: .color(Color(white: 0.04)))
                let r = d * 0.40, h = d * 0.07
                let tone = FCUColors.airbusKnob
                KnobDraw.cylinder(ctx, base: c, radius: r, lift: h, tone: tone, shadow: 0.5, faceShade: false)
                // The pointer bar: a raised fin across the face, tapered to
                // a point at the selected position, with its white line.
                let top = CGPoint(x: c.x, y: c.y - h)
                let a = pointer * .pi / 180
                let ux = CGFloat(sin(a)), uy = -CGFloat(cos(a))
                let px = -uy, py = ux
                let w = r * 0.32, tip = r * 0.98, tail = r * 0.80
                func pt(_ along: CGFloat, _ across: CGFloat, lift: CGFloat = 0) -> CGPoint {
                    CGPoint(x: top.x + ux * along + px * across, y: top.y + uy * along + py * across - lift)
                }
                let fin = Path { p in
                    p.move(to: pt(tip, 0))
                    p.addLine(to: pt(tip - w * 1.1, w / 2))
                    p.addLine(to: pt(-tail, w / 2))
                    p.addLine(to: pt(-tail, -w / 2))
                    p.addLine(to: pt(tip - w * 1.1, -w / 2))
                    p.closeSubpath()
                }
                var shadowCtx = ctx
                shadowCtx.addFilter(.blur(radius: 0.8))
                shadowCtx.fill(fin.offsetBy(dx: r * 0.06, dy: r * 0.10), with: .color(.black.opacity(0.45)))
                ctx.fill(fin.offsetBy(dx: 0, dy: -h * 0.4),
                         with: .linearGradient(Gradient(colors: [tone(1.12), tone(0.95), tone(0.72)]),
                                               startPoint: pt(0, -w / 2), endPoint: pt(0, w / 2)))
                ctx.stroke(fin.offsetBy(dx: 0, dy: -h * 0.4), with: .color(.black.opacity(0.25)), lineWidth: 0.4)
                var line = Path()
                line.move(to: pt(tip * 0.92, 0, lift: h * 0.4))
                line.addLine(to: pt(r * 0.1, 0, lift: h * 0.4))
                ctx.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: max(0.8, r * 0.08), lineCap: .round))
            }
            .frame(width: labelRadius * 2 + 30, height: labelRadius * 2 + 20)
            ForEach(labels.indices, id: \.self) { i in
                let a = angles[i] * .pi / 180
                label(i)
                    .offset(x: CGFloat(sin(a)) * labelRadius, y: -CGFloat(cos(a)) * labelRadius)
            }
        }
        .frame(width: labelRadius * 2 + 30, height: labelRadius * 2 + 20)
    }
}

extension AirbusSelector {
    @ViewBuilder fileprivate func label(_ i: Int) -> some View {
        if let onSelect {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                onSelect(i)
            } label: {
                FCULegend(labels[i], size: labelSize)
                    .padding(.horizontal, 3).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            FCULegend(labels[i], size: labelSize)
        }
    }
}

/// Evenly spread angles, in degrees clockwise from the top.
func fcuArc(_ count: Int, from start: Double, to end: Double) -> [Double] {
    guard count > 1 else { return [start] }
    return (0..<count).map { start + (end - start) * Double($0) / Double(count - 1) }
}

// MARK: - Boeing knobs

/// The 737 MCP knobs: tall, very pale grey cylinders with a fine knurl
/// round the side. COURSE carries an orange cross on its face, IAS/MACH is
/// scalloped into eight lobes, HEADING and ALTITUDE are plain.
struct BoeingKnob: View {
    enum Kind { case plain, course, speed }

    var kind: Kind = .plain
    var diameter: CGFloat
    var turns: Int = 0
    var detent: Double = 9

    var body: some View {
        let d = diameter
        let rotation = Double(turns) * detent * .pi / 180
        Canvas { ctx, size in
            let lift = d * 0.20
            let r = d * 0.42
            // Stand the knob so its face is centred in the frame.
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + lift / 2)
            let tone = FCUColors.boeingKnob
            switch kind {
            case .speed:
                KnobDraw.cylinder(ctx, base: c, radius: r, lift: lift, tone: tone,
                                  edge: .lobes(8, depth: 0.17), rotation: rotation, shadow: 0.55)
            case .plain, .course:
                KnobDraw.cylinder(ctx, base: c, radius: r, lift: lift, tone: tone,
                                  ridges: 52, rotation: rotation, shadow: 0.55)
            }
            if kind == .course {
                // The orange cross.
                let top = CGPoint(x: c.x, y: c.y - lift)
                for k in 0..<2 {
                    let a = rotation + .pi / 4 + Double(k) * .pi / 2
                    let ux = CGFloat(sin(a)), uy = -CGFloat(cos(a))
                    var p = Path()
                    p.move(to: CGPoint(x: top.x - ux * r * 0.42, y: top.y - uy * r * 0.42))
                    p.addLine(to: CGPoint(x: top.x + ux * r * 0.42, y: top.y + uy * r * 0.42))
                    ctx.stroke(p, with: .color(FCUColors.boeingCourseMark),
                               style: StrokeStyle(lineWidth: r * 0.115, lineCap: .round))
                }
            }
        }
        .frame(width: d, height: d)
    }
}

/// The 737's bank-angle selector behind the HEADING knob: a pale grey
/// collar with a pointer tab reaching out to the limit it is set to.
struct BankAngleSelector: View {
    var diameter: CGFloat
    var tabAngle: Double

    var body: some View {
        let d = diameter
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let tone = FCUColors.boeingKnob
            let a = tabAngle * .pi / 180
            let ux = CGFloat(sin(a)), uy = -CGFloat(cos(a))
            let px = -uy, py = ux
            let r = d * 0.36
            // The tab, from under the collar out to the scale.
            let tab = Path { p in
                let w0 = d * 0.17, w1 = d * 0.08, reach = d * 0.49
                p.move(to: CGPoint(x: c.x + px * w0, y: c.y + py * w0))
                p.addLine(to: CGPoint(x: c.x + ux * reach + px * w1, y: c.y + uy * reach + py * w1))
                p.addQuadCurve(to: CGPoint(x: c.x + ux * reach - px * w1, y: c.y + uy * reach - py * w1),
                               control: CGPoint(x: c.x + ux * (reach + w1 * 0.9), y: c.y + uy * (reach + w1 * 0.9)))
                p.addLine(to: CGPoint(x: c.x - px * w0, y: c.y - py * w0))
                p.closeSubpath()
            }
            var s = ctx
            s.addFilter(.blur(radius: 1.2))
            s.fill(tab.offsetBy(dx: 1, dy: 1.6), with: .color(.black.opacity(0.5)))
            ctx.fill(tab, with: .linearGradient(Gradient(colors: [tone(1.05), tone(0.80), tone(0.60)]),
                                                startPoint: CGPoint(x: c.x - d / 2, y: c.y - d / 2),
                                                endPoint: CGPoint(x: c.x + d / 2, y: c.y + d / 2)))
            ctx.stroke(tab, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
            KnobDraw.cylinder(ctx, base: c, radius: r, lift: d * 0.03, tone: FCUTone(0.70, 0.70, 0.69),
                              shadow: 0.5, faceShade: false)
        }
        .frame(width: d, height: d)
    }
}

/// The 737 EFIS's concentric knobs: a pale knurled outer knob with a black
/// centre button carrying its legend (RST, STD, CTR, TFC). `lit` shows the
/// legend in the light colour.
struct BoeingSelector: View {
    var labels: [String] = []
    var angles: [Double] = []
    var diameter: CGFloat = 32
    var labelRadius: CGFloat = 26
    var labelSize: CGFloat = 6.5
    let center: String
    var lit = false
    var turns = 0

    var body: some View {
        let d = diameter
        let lift = d * 0.13
        let innerLift = d * 0.06
        ZStack {
            ForEach(labels.indices, id: \.self) { i in
                let a = angles[i] * .pi / 180
                FCULegend(labels[i], size: labelSize, color: FCUColors.boeingLegend, face: .boeing)
                    .offset(x: CGFloat(sin(a)) * labelRadius, y: -CGFloat(cos(a)) * labelRadius)
            }
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2 + lift / 2)
                let rotation = Double(turns) * 9 * .pi / 180
                KnobDraw.cylinder(ctx, base: c, radius: d * 0.46, lift: lift, tone: FCUColors.boeingKnob,
                                  ridges: 44, rotation: rotation, shadow: 0.55)
                KnobDraw.cylinder(ctx, base: CGPoint(x: c.x, y: c.y - lift), radius: d * 0.33, lift: innerLift,
                                  tone: FCUTone(0.10, 0.10, 0.11), shadow: 0.35)
            }
            .frame(width: d, height: d)
            Text(center)
                .font(FCUTypeface.boeingCondensed.font(d * 0.24))
                .foregroundStyle(lit ? FCUColors.boeingLight : FCUColors.boeingLegend)
                .fixedSize()
                .offset(y: -lift / 2 - innerLift)
        }
        .frame(width: labelRadius * 2 + 24, height: labelRadius * 2 + 14)
    }
}

// MARK: - Round buttons

/// A round momentary button: a black face sunk in a ring — bright and
/// white on the A320 (SPD MACH, HDG V/S - TRK FPA, METRIC ALT), grey on
/// the 737 (C/O, SPD INTV, FPV, MTRS). Legends are printed beside it.
struct FCURoundButton: View {
    var diameter: CGFloat = 30
    var boeing = false
    var action: (() -> Void)?

    var body: some View {
        let d = diameter
        let face = Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = d / 2
            let ringWidth = d * (boeing ? 0.10 : 0.075)
            ctx.fill(KnobDraw.circle(c, r + 0.6), with: .color(.black.opacity(0.35)))
            if boeing {
                ctx.fill(KnobDraw.ring(c, r, r - ringWidth),
                         with: .linearGradient(Gradient(colors: [Color(white: 0.68), Color(white: 0.48), Color(white: 0.36)]),
                                               startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)),
                         style: FillStyle(eoFill: true))
            } else {
                ctx.fill(KnobDraw.ring(c, r, r - ringWidth),
                         with: .linearGradient(Gradient(colors: [Color(white: 0.99), Color(white: 0.90), Color(white: 0.74)]),
                                               startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)),
                         style: FillStyle(eoFill: true))
            }
            // The face: sunk, so in shadow under its upper rim.
            let fr = r - ringWidth
            ctx.fill(KnobDraw.circle(c, fr),
                     with: .linearGradient(Gradient(colors: [Color(white: 0.015), Color(white: 0.05), Color(white: 0.11)]),
                                           startPoint: CGPoint(x: c.x, y: c.y - fr), endPoint: CGPoint(x: c.x, y: c.y + fr)))
            ctx.fill(KnobDraw.circle(CGPoint(x: c.x + fr * 0.08, y: c.y + fr * 0.18), fr * 0.70),
                     with: .radialGradient(Gradient(colors: [Color(white: 0.16).opacity(0.7), .clear]),
                                           center: CGPoint(x: c.x + fr * 0.08, y: c.y + fr * 0.18),
                                           startRadius: 0, endRadius: fr * 0.70))
        }
        .frame(width: d, height: d)

        if let action {
            Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() }) { face }
                .buttonStyle(FCUPressStyle())
        } else {
            face
        }
    }
}

// MARK: - Airbus pushbuttons

/// The A320 FCU and EFIS pushbutton: a black cap with softly rounded
/// corners standing proud of the panel, its legend in white along the
/// lower part, and above it three thin green lines, stacked, that light
/// when the function is engaged and cannot be seen when it is not.
/// `action` nil leaves it on the panel but inert.
struct AirbusPushbutton: View {
    let legend: String
    var lit: Bool = false
    var width: CGFloat = 46
    var height: CGFloat = 44
    var fontSize: CGFloat? = nil
    var action: (() -> Void)?

    var body: some View {
        let w = width, h = height
        let corner = min(w, h) * 0.13
        let cap = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let size = fontSize ?? min(10, h * 0.30)
        let barWidth = min(w * 0.46, 22)
        let line = max(0.8, h * 0.022)
        let face = ZStack {
            // The shadow the cap casts on the panel.
            cap.fill(Color.black.opacity(0.6)).offset(x: 0.8, y: 1.4).blur(radius: 1.2)
            cap.fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.055), Color(white: 0.035)],
                                    startPoint: .top, endPoint: .bottom))
            // The cap's rim catching the light, and the face set in it.
            cap.strokeBorder(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.06), .black.opacity(0.5)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
            RoundedRectangle(cornerRadius: corner * 0.7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.6)
                .padding(2.4)
            // The three green lines.
            if lit {
                VStack(spacing: line * 0.55) {
                    ForEach(0..<3, id: \.self) { i in
                        Rectangle()
                            .fill(i == 1 ? FCUColors.airbusLight : FCUColors.airbusLightCore)
                            .frame(width: barWidth, height: line)
                    }
                }
                .shadow(color: FCUColors.airbusLight.opacity(0.9), radius: 0.6)
                .shadow(color: FCUColors.airbusLight.opacity(0.45), radius: 1.8)
                .position(x: w / 2, y: h * 0.30)
            }
            Text(legend)
                .font(FCUTypeface.airbus.font(size))
                .tracking(size * 0.04)
                .foregroundStyle(FCUColors.airbusCapLegend.opacity(action == nil ? 0.85 : 1))
                .multilineTextAlignment(.center)
                .lineSpacing(-size * 0.25)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .frame(width: w - 4)
                .position(x: w / 2, y: h * 0.70)
        }
        .frame(width: w, height: h)

        if let action {
            Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() }) { face }
                .buttonStyle(FCUPressStyle())
        } else {
            face
        }
    }
}

/// The A320 EFIS's ADF / VOR selector switch: a polished ball lever in a
/// ring. Drawn for the panel's look; it has nothing to select here.
struct AirbusBallSwitch: View {
    var diameter: CGFloat = 20

    var body: some View {
        let d = diameter
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = d / 2
            ctx.stroke(KnobDraw.circle(c, r - 0.7), with: .color(FCUColors.airbusLegend.opacity(0.9)), lineWidth: 1.2)
            ctx.fill(KnobDraw.circle(c, r - 1.6), with: .color(Color(white: 0.05)))
            var s = ctx
            s.addFilter(.blur(radius: 0.8))
            s.fill(KnobDraw.circle(CGPoint(x: c.x + 1.2, y: c.y + 1.4), r * 0.42), with: .color(.black.opacity(0.7)))
            ctx.fill(KnobDraw.circle(c, r * 0.42),
                     with: .radialGradient(Gradient(colors: [Color(white: 1), Color(white: 0.70), Color(white: 0.28), Color(white: 0.55)]),
                                           center: CGPoint(x: c.x - r * 0.14, y: c.y - r * 0.16), startRadius: 0, endRadius: r * 0.5))
        }
        .frame(width: d, height: d)
    }
}

// MARK: - Boeing pushbuttons

/// The 737 MCP switch: a black frame round a dark grey face, the legend in
/// white at the top of the face and the light bar under it, which comes
/// on amber-yellow when the mode is engaged. `lit` nil draws no bar
/// (switches without one); `key` draws the EFIS control panel's small
/// black keys, the legend centred. `action` nil leaves it inert.
struct BoeingPushbutton: View {
    let legend: String
    var lit: Bool? = false
    var width: CGFloat = 46
    var height: CGFloat = 38
    var fontSize: CGFloat = 10
    var key = false
    var action: (() -> Void)?

    var body: some View {
        let w = width, h = height
        let frame = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        let inset = key ? 2.0 : max(3, min(w, h) * 0.11)
        let faceShape = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        let face = ZStack {
            frame.fill(Color.black.opacity(0.6)).offset(x: 0.8, y: 1.4).blur(radius: 1.2)
            frame.fill(LinearGradient(colors: [Color(white: 0.08), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
            frame.strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.5)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            if !key {
                faceShape
                    .fill(LinearGradient(colors: [FCUColors.boeingCapFace, Color(white: 0.17)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(faceShape.fill(LinearGradient(colors: [.white.opacity(0.07), .clear],
                                                           startPoint: .top, endPoint: .center)))
                    .overlay(faceShape.strokeBorder(Color.black.opacity(0.7), lineWidth: 0.6))
                    .padding(inset)
            }
            VStack(spacing: h * 0.10) {
                Text(legend)
                    .font(FCUTypeface.boeingCondensed.font(fontSize * (key ? 1 : 0.86)))
                    .tracking(fontSize * 0.06)
                    .foregroundStyle(FCUColors.boeingLegend.opacity(action == nil ? 0.82 : 0.95))
                    .multilineTextAlignment(.center)
                    .lineSpacing(-2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let lit {
                    BoeingLightBar(lit: lit, width: (w - 2 * inset) * 0.70, height: max(2.5, h * 0.15))
                }
            }
            .frame(width: w - 2 * inset, height: h - 2 * inset, alignment: key ? .center : .top)
            .padding(.top, key ? 0 : h * 0.09)
        }
        .frame(width: w, height: h)

        if let action {
            Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); action() }) { face }
                .buttonStyle(FCUPressStyle())
        } else {
            face
        }
    }
}

/// A 737 switch's light bar: amber-yellow when lit, its LED segments
/// showing as fine lines; when off, only a faint outline on the face.
struct BoeingLightBar: View {
    var lit: Bool
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 0.8, style: .continuous)
        ZStack {
            if lit {
                shape.fill(LinearGradient(colors: [FCUColors.boeingLightCore, FCUColors.boeingLight],
                                          startPoint: .top, endPoint: .bottom))
                Canvas { ctx, size in
                    var x: CGFloat = 1.2
                    while x < size.width {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(p, with: .color(Color(red: 0.75, green: 0.50, blue: 0.0).opacity(0.45)), lineWidth: 0.35)
                        x += 1.3
                    }
                }
                .clipShape(shape)
            } else {
                shape.fill(Color.black.opacity(0.05))
            }
        }
        .frame(width: width, height: height)
        .shadow(color: lit ? FCUColors.boeingLight.opacity(0.9) : .clear, radius: 1.2)
        .shadow(color: lit ? FCUColors.boeingLight.opacity(0.45) : .clear, radius: 4)
    }
}

/// An annunciator light on the 737 MCP (MA by the F/D switch, ARM over
/// the A/T switch): a small lens, amber-yellow with its legend dark on it
/// when lit, dark with the legend faint when off.
struct BoeingLight: View {
    let legend: String
    let lit: Bool
    var color: Color = FCUColors.boeingLight

    var body: some View {
        let lens = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        Text(legend)
            .font(FCUTypeface.boeingCondensed.font(7.5))
            .foregroundStyle(lit ? Color.black.opacity(0.70) : Color(white: 0.30))
            .frame(width: 21, height: 11)
            .background(
                ZStack {
                    if lit {
                        lens.fill(LinearGradient(colors: [FCUColors.boeingLightCore, color], startPoint: .top, endPoint: .bottom))
                    } else {
                        lens.fill(LinearGradient(colors: [Color(white: 0.07), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                    }
                    lens.fill(LinearGradient(colors: [.white.opacity(lit ? 0.25 : 0.06), .clear], startPoint: .top, endPoint: .center))
                }
            )
            .overlay(lens.strokeBorder(Color.black.opacity(0.7), lineWidth: 0.7))
            .shadow(color: lit ? color.opacity(0.85) : .clear, radius: 1.5)
            .shadow(color: lit ? color.opacity(0.4) : .clear, radius: 5)
    }
}

/// The 737's F/D and A/T ARM switches: a short black lever in a slot,
/// framed by a white printed outline; lever up for on.
struct BoeingToggle: View {
    let onLabel: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(); action() }) {
            VStack(spacing: 3) {
                FCULegend(onLabel, size: 8, color: FCUColors.boeingLegend, face: .boeing)
                ZStack {
                    // The printed outline, and the slot inside it.
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(FCUColors.boeingLegend.opacity(0.9), lineWidth: 1)
                        .frame(width: 17, height: 36)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.02), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 9, height: 28)
                    // The lever's shadow, then the lever.
                    lever.foregroundStyle(Color.black.opacity(0.6))
                        .offset(x: 1.4, y: (isOn ? -6.5 : 6.5) + 1.8).blur(radius: 0.9)
                    lever.foregroundStyle(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.16), Color(white: 0.06)],
                                                         startPoint: .leading, endPoint: .trailing))
                        .overlay(lever.foregroundStyle(LinearGradient(colors: [.white.opacity(isOn ? 0.35 : 0.08), .clear],
                                                                      startPoint: .top, endPoint: .bottom)))
                        .offset(y: isOn ? -6.5 : 6.5)
                }
                .frame(width: 34, height: 40)
                FCULegend("OFF", size: 8, color: FCUColors.boeingLegend, face: .boeing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var lever: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous).frame(width: 7, height: 14)
    }
}

/// The 737's V/S thumbwheel: a pale ribbed wheel in its slot between two
/// white brackets, DN with its arrow up and UP with its arrow down printed
/// beside it — rolling the top of the wheel away (a drag upward) is nose
/// down.
struct BoeingThumbwheel: View {
    var onTurn: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            FCUTurnable(stepPoints: 7, onTurn: { onTurn(-$0) }) { turns in
                ZStack {
                    brackets
                    // The round recess the wheel turns in, and the slot.
                    Ellipse()
                        .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.30)], startPoint: .top, endPoint: .bottom))
                        .overlay(Ellipse().strokeBorder(LinearGradient(colors: [.black.opacity(0.5), .white.opacity(0.18)],
                                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                        .frame(width: 30, height: 46)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(white: 0.03))
                        .frame(width: 22.5, height: 59)
                    wheel(turns: turns)
                        .frame(width: 21, height: 57.5)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .frame(width: 32, height: 68)
            }
            VStack(spacing: 2) {
                FCULegend("DN", size: 6.5, color: FCUColors.boeingLegend, face: .boeing)
                arrow(up: true)
                Rectangle().fill(FCUColors.boeingLegend.opacity(0.9)).frame(width: 8, height: 1)
                arrow(up: false)
                FCULegend("UP", size: 6.5, color: FCUColors.boeingLegend, face: .boeing)
            }
        }
    }

    /// The white brackets printed above and below the slot.
    private var brackets: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var p = Path()
            p.move(to: CGPoint(x: 3, y: 5)); p.addLine(to: CGPoint(x: 3, y: 1)); p.addLine(to: CGPoint(x: w - 3, y: 1)); p.addLine(to: CGPoint(x: w - 3, y: 5))
            p.move(to: CGPoint(x: 3, y: h - 5)); p.addLine(to: CGPoint(x: 3, y: h - 1)); p.addLine(to: CGPoint(x: w - 3, y: h - 1)); p.addLine(to: CGPoint(x: w - 3, y: h - 5))
            ctx.stroke(p, with: .color(FCUColors.boeingLegend.opacity(0.9)), lineWidth: 1.6)
        }
    }

    private func arrow(up: Bool) -> some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            var p = Path()
            p.move(to: CGPoint(x: cx, y: up ? 0 : size.height))
            p.addLine(to: CGPoint(x: cx - 2.8, y: up ? 4 : size.height - 4))
            p.addLine(to: CGPoint(x: cx + 2.8, y: up ? 4 : size.height - 4))
            p.closeSubpath()
            ctx.fill(p, with: .color(FCUColors.boeingLegend.opacity(0.9)))
            var shaft = Path()
            shaft.move(to: CGPoint(x: cx, y: 3)); shaft.addLine(to: CGPoint(x: cx, y: size.height - 3))
            ctx.stroke(shaft, with: .color(FCUColors.boeingLegend.opacity(0.9)), lineWidth: 1)
        }
        .frame(width: 8, height: 11)
    }

    /// Ribs on a pale cylinder: closer together towards the top and bottom
    /// edges, as they turn away; each a dark groove under a lit crest.
    private func wheel(turns: Int) -> some View {
        let tone = FCUColors.boeingKnob
        return Canvas { ctx, size in
            let ribs = 30
            let phase = Double(turns).truncatingRemainder(dividingBy: 2) * 0.5
            for i in 0..<ribs {
                let u = (Double(i) + phase) / Double(ribs)
                let y = size.height / 2 - CGFloat(cos(u * .pi)) * size.height / 2
                let shade = sin(u * .pi)
                var groove = Path()
                groove.move(to: CGPoint(x: 0, y: y))
                groove.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(groove, with: .color(.black.opacity(0.10 + 0.25 * shade)), lineWidth: 0.4 + 0.5 * shade)
                var crest = Path()
                crest.move(to: CGPoint(x: 0, y: y - 0.7 * shade))
                crest.addLine(to: CGPoint(x: size.width, y: y - 0.7 * shade))
                ctx.stroke(crest, with: .color(.white.opacity(0.25 * shade)), lineWidth: 0.4)
            }
        }
        .background(LinearGradient(stops: [.init(color: tone(0.45), location: 0),
                                           .init(color: tone(1.04), location: 0.28),
                                           .init(color: tone(0.98), location: 0.55),
                                           .init(color: tone(0.42), location: 1)],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(LinearGradient(colors: [.black.opacity(0.10), .white.opacity(0.10), .clear, .black.opacity(0.30)],
                                startPoint: .leading, endPoint: .trailing))
    }
}

/// The 737's A/P DISENGAGE bar: a pale grey bar in its slot inside a white
/// printed bracket; pulled down, it shows its yellow and black stripes and
/// drops both autopilots.
struct DisengageBar: View {
    var width: CGFloat = 116
    var action: () -> Void
    @State private var down = false

    var body: some View {
        ZStack(alignment: .top) {
            // The printed bracket round the bar, open at the top.
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 12, y: 0.5))
                p.addLine(to: CGPoint(x: 0.5, y: 0.5))
                p.addLine(to: CGPoint(x: 0.5, y: size.height - 0.5))
                p.addLine(to: CGPoint(x: size.width - 0.5, y: size.height - 0.5))
                p.addLine(to: CGPoint(x: size.width - 0.5, y: 0.5))
                p.addLine(to: CGPoint(x: size.width - 12, y: 0.5))
                ctx.stroke(p, with: .color(FCUColors.boeingLegend.opacity(0.85)), lineWidth: 1)
            }
            .frame(width: width + 10, height: 23)
            .offset(y: -4)
            // The slot the bar slides in.
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.03), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
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
            // The bar: pale grey, matt, its top edge catching the light.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinearGradient(stops: [.init(color: Color(white: 0.86), location: 0),
                                             .init(color: Color(white: 0.78), location: 0.5),
                                             .init(color: Color(white: 0.66), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .black.opacity(0.45)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
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
