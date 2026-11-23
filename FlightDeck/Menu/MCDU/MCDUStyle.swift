import SwiftUI

// MARK: - Screen content

/// The colour code of the MCDU screen. What each colour means follows the
/// real units: cyan for crew entries, green for system data, amber for
/// required entries and cautions, magenta for constraints, white for
/// labels, prompts and the scratchpad.
enum MCDUColor {
    case white, cyan, green, amber, magenta, grey
}

/// A stretch of text in one colour and size.
struct MCDURun {
    var text: String
    var color: MCDUColor = .white
    var small = false
}

/// One of the screen's 24-column lines: text set from the left edge, from
/// the right edge, and centred.
struct MCDULine {
    var left: [MCDURun] = []
    var center: [MCDURun] = []
    var right: [MCDURun] = []

    static let empty = MCDULine()
}

/// One page as shown: the title line, then six label/data line pairs (the
/// data lines sit beside the line-select keys), and the page number.
struct MCDUScreen {
    var title: [MCDURun]
    var pageNumber: String?
    /// Twelve lines: label 1, data 1, … label 6, data 6.
    var rows: [MCDULine]
}

/// The pages the MCDU can show.
enum MCDUPage: Equatable {
    case menu, route, destSearch, flightPlan, progress, settings, flights, credits
    /// Runway and departure / approach selection, and the Boeing index.
    case departure, arrival, depArr
}

/// Everything a key on the unit can do.
enum MCDUKey: Hashable {
    /// Line-select key: left or right, 0…5 from the top.
    case lsk(left: Bool, index: Int)
    /// A page key; nil for keys with no page here (NOT ALLOWED).
    case page(MCDUPage?)
    case character(Character)
    case space, clear, delete, plusMinus
    case previousPage, nextPage
    case exec
}

// MARK: - Style

/// Look and naming of the unit, after the flight deck in use: an Airbus
/// MCDU beside the A320 displays, a Boeing CDU beside the 737's. Both are
/// our own drawing; the layout is parametric like the displays'.
struct MCDUStyle {
    let deck: DisplayStyle

    init(_ deck: DisplayStyle) { self.deck = deck }

    var isBoeing: Bool { deck == .boeing }

    // MARK: Colours

    func color(_ c: MCDUColor) -> Color {
        switch (deck, c) {
        case (_, .grey): return Color(white: 0.55)
        case (.airbus, .white): return .white
        case (.airbus, .cyan): return EFIS.cyan
        case (.airbus, .green): return EFIS.green
        case (.airbus, .amber): return EFIS.amber
        case (.airbus, .magenta): return EFIS.magenta
        case (.boeing, .white): return Boeing.white
        case (.boeing, .cyan): return Boeing.cyan
        case (.boeing, .green): return Boeing.green
        case (.boeing, .amber): return Boeing.amber
        case (.boeing, .magenta): return Boeing.magenta
        }
    }

    /// The front panel: the Airbus unit's blue-grey, the Boeing unit's
    /// neutral grey.
    var bezel: Color {
        isBoeing ? Color(red: 0.384, green: 0.392, blue: 0.400) : Color(red: 0.349, green: 0.396, blue: 0.435)
    }
    var bezelEdge: Color { Color.white.opacity(0.12) }
    /// The darker plate under the Boeing unit's function keys.
    var plate: Color { Color(red: 0.33, green: 0.34, blue: 0.35) }
    var screenBackground: Color { isBoeing ? .black : Color(red: 0.016, green: 0.016, blue: 0.02) }
    var screenFrame: Color { Color(red: 0.12, green: 0.13, blue: 0.14) }
    /// Key caps: near-black on both units.
    var keyFace: Color {
        isBoeing ? Color(red: 0.16, green: 0.165, blue: 0.17) : Color(red: 0.14, green: 0.155, blue: 0.165)
    }
    /// Legends: the Airbus keys' backlighting is a warm white, the Boeing
    /// keys' a plain white.
    var keyLabel: Color { isBoeing ? Color(white: 0.95) : Color(red: 0.98, green: 0.90, blue: 0.74) }
    var annunciatorOff: Color { Color.white.opacity(0.16) }
    var annunciatorOn: Color { isBoeing ? Color(white: 0.95) : Color(red: 0.95, green: 0.6, blue: 0.1) }
    var slot: Color { Color(red: 0.09, green: 0.1, blue: 0.11) }

    // MARK: Type

    /// The screen's fixed-width face. Small type is about three quarters
    /// of large, as on the real screens.
    func font(_ size: CGFloat, small: Bool) -> Font {
        .system(size: small ? size * 0.76 : size, weight: isBoeing ? .medium : .semibold, design: .monospaced)
    }

    // MARK: Names

    /// Page titles as each unit names them.
    func title(_ page: MCDUPage) -> String {
        switch (page, isBoeing) {
        case (.menu, false): return "MCDU MENU"
        case (.menu, true): return "MENU"
        case (.route, false): return "INIT"
        case (.route, true): return "RTE"
        case (.destSearch, _): return "DEST SEARCH"
        case (.flightPlan, false): return "F-PLN"
        case (.flightPlan, true): return "ACT RTE LEGS"
        case (.progress, false): return "PROG"
        case (.progress, true): return "PROGRESS"
        case (.settings, false): return "DATA SETTINGS"
        case (.settings, true): return "INIT/REF INDEX"
        case (.flights, false): return "STORED FLIGHTS"
        case (.flights, true): return "FLIGHT PACKS"
        case (.credits, _): return "CREDITS"
        case (.departure, false): return "DEPARTURES FROM"
        case (.departure, true): return "DEPARTURES"
        case (.arrival, false): return "ARRIVAL TO"
        case (.arrival, true): return "ARRIVALS"
        case (.depArr, _): return "DEP/ARR INDEX"
        }
    }

    // MARK: - Panel layout

    /// Width / height of the whole unit, as on the real one.
    var aspect: CGFloat { isBoeing ? 0.686 : 0.604 }

    /// Where things sit on the unit, as fractions of its width (x) and
    /// height (y), measured off the real units' front panels.
    var screenRect: CGRect {
        isBoeing ? CGRect(x: 0.164, y: 0.074, width: 0.678, height: 0.354)
                 : CGRect(x: 0.173, y: 0.081, width: 0.686, height: 0.344)
    }

    /// Left and right line-select key columns: x and width.
    var lskColumns: (left: ClosedRange<CGFloat>, right: ClosedRange<CGFloat>) {
        isBoeing ? (0.025...0.107, 0.904...0.986) : (0.058...0.128, 0.927...0.987)
    }
    var lskHeight: CGFloat { isBoeing ? 0.025 : 0.023 }

    /// The keys on the panel below the screen.
    var panelKeys: [MCDUPanelKey] { isBoeing ? boeingKeys : airbusKeys }

    /// Annunciator strips: frame and the lights in it, top to bottom.
    var annunciatorStrips: [(rect: CGRect, lights: [String])] {
        isBoeing
            ? [(CGRect(x: 0.056, y: 0.719, width: 0.043, height: 0.136), ["CALL", "FAIL"]),
               (CGRect(x: 0.895, y: 0.719, width: 0.046, height: 0.136), ["MSG", "OFST"])]
            : [(CGRect(x: 0.067, y: 0.687, width: 0.038, height: 0.139), ["FAIL", "FM1", "IND"]),
               (CGRect(x: 0.939, y: 0.687, width: 0.039, height: 0.139), ["RDY", "FM2", ""])]
    }

    /// The five slots above the Airbus unit's screen.
    var topSlots: [CGRect] {
        guard !isBoeing else { return [] }
        return [0.278, 0.406, 0.534, 0.661, 0.783].map { CGRect(x: $0 - 0.053, y: 0.023, width: 0.106, height: 0.023) }
    }

    /// The darker plate the Boeing unit's function keys sit on.
    var functionPlate: CGRect? {
        isBoeing ? CGRect(x: 0.105, y: 0.465, width: 0.8, height: 0.262) : nil
    }

    /// The Boeing unit's brightness knob.
    var knob: (center: CGPoint, radius: CGFloat)? {
        isBoeing ? (CGPoint(x: 0.856, y: 0.502), 0.04) : nil
    }

    /// Screw heads at the corners and along the sides.
    var screws: [CGPoint] {
        isBoeing
            ? [CGPoint(x: 0.04, y: 0.03), CGPoint(x: 0.96, y: 0.03), CGPoint(x: 0.06, y: 0.5),
               CGPoint(x: 0.94, y: 0.5), CGPoint(x: 0.06, y: 0.97), CGPoint(x: 0.94, y: 0.97)]
            : [CGPoint(x: 0.07, y: 0.025), CGPoint(x: 0.95, y: 0.025), CGPoint(x: 0.07, y: 0.47),
               CGPoint(x: 0.95, y: 0.47), CGPoint(x: 0.07, y: 0.975), CGPoint(x: 0.95, y: 0.975)]
    }

    // MARK: Airbus key layout

    private var airbusKeys: [MCDUPanelKey] {
        var keys: [MCDUPanelKey] = []
        let colX: [CGFloat] = (0..<6).map { 0.163 + CGFloat($0) * 0.1185 }
        let w: CGFloat = 0.105
        func fn(_ label: String, _ page: MCDUPage?, col: Int, y: CGFloat, h: CGFloat) {
            keys.append(MCDUPanelKey(label: label, key: .page(page),
                                     rect: CGRect(x: colX[col], y: y, width: w, height: h)))
        }
        let row1: [(String, MCDUPage?)] = [("DIR", .destSearch), ("PROG", .progress), ("PERF", .settings),
                                           ("INIT", .route), ("DATA", .flights), ("", nil)]
        for (i, k) in row1.enumerated() { fn(k.0, k.1, col: i, y: 0.479, h: 0.036) }
        let row2: [(String, MCDUPage?)] = [("F-PLN", .flightPlan), ("RAD\nNAV", nil), ("FUEL\nPRED", nil),
                                           ("SEC\nF-PLN", nil), ("ATC\nCOMM", nil), ("MCDU\nMENU", .menu)]
        for (i, k) in row2.enumerated() { fn(k.0, k.1, col: i, y: 0.533, h: 0.042) }
        // BRT / DIM: narrow keys beside the rows.
        keys.append(MCDUPanelKey(label: "BRT", key: .page(nil), rect: CGRect(x: 0.886, y: 0.482, width: 0.045, height: 0.03),
                                 small: true))
        keys.append(MCDUPanelKey(label: "DIM", key: .page(nil), rect: CGRect(x: 0.886, y: 0.539, width: 0.045, height: 0.03),
                                 small: true))
        fn("AIR\nPORT", nil, col: 0, y: 0.591, h: 0.044)
        fn("", nil, col: 1, y: 0.591, h: 0.044)
        keys.append(MCDUPanelKey(label: "←", key: .previousPage, rect: CGRect(x: colX[0], y: 0.649, width: w, height: 0.038)))
        keys.append(MCDUPanelKey(label: "↑", key: .previousPage, rect: CGRect(x: colX[1], y: 0.649, width: w, height: 0.038)))
        keys.append(MCDUPanelKey(label: "→", key: .nextPage, rect: CGRect(x: colX[0], y: 0.707, width: w, height: 0.038)))
        keys.append(MCDUPanelKey(label: "↓", key: .nextPage, rect: CGRect(x: colX[1], y: 0.707, width: w, height: 0.038)))

        keys += numberKeys(columns: [0.201, 0.297, 0.393], rows: [0.782, 0.842, 0.898, 0.956], diameter: 0.064)
        keys += letterKeys(columns: [0.495, 0.588, 0.681, 0.773, 0.866], rows: [0.629, 0.691, 0.753, 0.817, 0.873, 0.931],
                           size: CGSize(width: 0.072, height: 0.039),
                           last: [("Z", .character("Z")), ("/", .character("/")), ("SP", .space),
                                  ("OVFY", .page(nil)), ("CLR", .clear)])
        return keys
    }

    // MARK: Boeing key layout

    private var boeingKeys: [MCDUPanelKey] {
        var keys: [MCDUPanelKey] = []
        let colX: [CGFloat] = (0..<6).map { 0.124 + CGFloat($0) * 0.1285 }
        let w: CGFloat = 0.113
        func fn(_ label: String, _ key: MCDUKey, col: Int, y: CGFloat) {
            keys.append(MCDUPanelKey(label: label, key: key, rect: CGRect(x: colX[col], y: y, width: w, height: 0.05)))
        }
        let row1: [(String, MCDUPage?)] = [("INIT\nREF", .settings), ("RTE", .route), ("CLB", nil), ("CRZ", .route),
                                           ("DES", nil)]
        for (i, k) in row1.enumerated() { fn(k.0, .page(k.1), col: i, y: 0.481) }
        let row2: [(String, MCDUKey)] = [("MENU", .page(.menu)), ("LEGS", .page(.flightPlan)), ("DEP\nARR", .page(.depArr)),
                                         ("HOLD", .page(nil)), ("PROG", .page(.progress)), ("EXEC", .exec)]
        for (i, k) in row2.enumerated() { fn(k.0, k.1, col: i, y: 0.543) }
        fn("N1\nLIMIT", .page(nil), col: 0, y: 0.605)
        fn("FIX", .page(.destSearch), col: 1, y: 0.605)
        fn("PREV\nPAGE", .previousPage, col: 0, y: 0.663)
        fn("NEXT\nPAGE", .nextPage, col: 1, y: 0.663)

        keys += numberKeys(columns: [0.158, 0.249, 0.339], rows: [0.764, 0.828, 0.890, 0.952], diameter: 0.062)
        keys += letterKeys(columns: [0.441, 0.540, 0.638, 0.734, 0.828], rows: [0.643, 0.705, 0.767, 0.829, 0.890, 0.952],
                           size: CGSize(width: 0.079, height: 0.05),
                           last: [("Z", .character("Z")), ("SP", .space), ("DEL", .delete),
                                  ("/", .character("/")), ("CLR", .clear)])
        return keys
    }

    // MARK: Shared blocks

    /// The round numeric keys, centred on the given columns and rows.
    private func numberKeys(columns: [CGFloat], rows: [CGFloat], diameter: CGFloat) -> [MCDUPanelKey] {
        let labels = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "+/-"]]
        var keys: [MCDUPanelKey] = []
        let height = diameter * aspect      // a circle, in height fractions
        for (r, row) in labels.enumerated() {
            for (c, label) in row.enumerated() {
                let key: MCDUKey = label == "+/-" ? .plusMinus : .character(Character(label))
                keys.append(MCDUPanelKey(label: label, key: key,
                                         rect: CGRect(x: columns[c] - diameter / 2, y: rows[r] - height / 2,
                                                      width: diameter, height: height),
                                         round: true))
            }
        }
        return keys
    }

    /// The alphabetic block, five keys a row, ending in the unit's own
    /// last row. The compass letters E, N, S and W carry a box, as on the
    /// real keys.
    private func letterKeys(columns: [CGFloat], rows: [CGFloat], size: CGSize,
                            last: [(String, MCDUKey)]) -> [MCDUPanelKey] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXY")
        var keys: [MCDUPanelKey] = []
        for (i, letter) in letters.enumerated() {
            let r = i / 5, c = i % 5
            keys.append(MCDUPanelKey(label: String(letter), key: .character(letter),
                                     rect: CGRect(x: columns[c] - size.width / 2, y: rows[r] - size.height / 2,
                                                  width: size.width, height: size.height),
                                     boxed: "ENSW".contains(letter)))
        }
        for (c, entry) in last.enumerated() {
            keys.append(MCDUPanelKey(label: entry.0, key: entry.1,
                                     rect: CGRect(x: columns[c] - size.width / 2, y: rows[5] - size.height / 2,
                                                  width: size.width, height: size.height),
                                     small: entry.0.count > 2))
        }
        return keys
    }
}

/// One key on the panel: its legend, what it does, and where it sits (as
/// fractions of the unit's width and height).
struct MCDUPanelKey: Identifiable {
    let label: String
    let key: MCDUKey
    let rect: CGRect
    var round = false
    var small = false
    var boxed = false
    var id: String { "\(label)-\(rect.minX)-\(rect.minY)" }
}
