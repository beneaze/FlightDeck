import SwiftUI

/// Boeing 737NG-style display house style — the colour code, the type, and
/// the layout of the PFD. Our own drawing of the 737's look: the palette is
/// chosen to read as the real displays do, and the layout is the parametric
/// spec in ``B737PFD``.
enum Boeing {

    // MARK: Colour code

    static let sky        = Color(red: 51 / 255, green: 140 / 255, blue: 218 / 255)   // #338cda
    static let ground     = Color(red: 113 / 255, green: 77 / 255, blue: 39 / 255)    // #714d27
    /// Tape and compass-rose fill.
    static let grey       = Color(red: 59 / 255, green: 58 / 255, blue: 62 / 255)     // #3b3a3e
    static let white      = Color(red: 245 / 255, green: 243 / 255, blue: 241 / 255)  // #f5f3f1
    /// Engaged modes, the baro reference, the speed trend.
    static let green      = Color(red: 0, green: 1, blue: 61 / 255)                   // #00ff3d
    /// MCP targets, the flight director, the flight plan.
    static let magenta    = Color(red: 245 / 255, green: 96 / 255, blue: 247 / 255)   // #f560f7
    static let amber      = Color(red: 1, green: 186 / 255, blue: 5 / 255)            // #ffba05
    /// Map airports and fixes.
    static let cyan       = Color(red: 0, green: 176 / 255, blue: 240 / 255)          // #00b0f0
    static let red        = Color(red: 1, green: 0, blue: 0)
    /// The display face is true black, unlike the Airbus unit's near-black.
    static let background = Color.black

    // MARK: Type

    /// The display face: a condensed sans with fixed-width figures, the
    /// nearest system face to the 737's narrow display font.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit().width(.condensed)
    }
}

extension GraphicsContext {

    /// How many points on screen one canvas unit currently spans.
    private var unitScale: CGFloat {
        let t = transform
        return max(0.001, (t.a * t.a + t.b * t.b).squareRoot())
    }

    /// Draw text in the Boeing display face, anchored at `point`. `size` is in
    /// canvas units, but the face is set at the size it will have on screen
    /// and the context scaled back, so the system font picks the optical cut
    /// for the real size rather than for the canvas unit.
    func boeingText(_ string: String, at point: CGPoint, size: CGFloat,
                    _ color: Color = Boeing.white, weight: Font.Weight = .medium,
                    anchor: UnitPoint = .center) {
        let k = unitScale
        var ctx = self
        ctx.translateBy(x: point.x, y: point.y)
        ctx.scaleBy(x: 1 / k, y: 1 / k)
        ctx.draw(Text(string).font(Boeing.font(size * k, weight)).foregroundStyle(color),
                 at: .zero, anchor: anchor)
    }

    /// Width of `string` in the Boeing face at `size`, in canvas units.
    func boeingTextWidth(_ string: String, size: CGFloat, weight: Font.Weight = .medium) -> CGFloat {
        let k = unitScale
        let resolved = resolve(Text(string).font(Boeing.font(size * k, weight)))
        return resolved.measure(in: CGSize(width: 10_000, height: 10_000)).width / k
    }

    /// Fill and/or stroke a closed polygon through `points`.
    func polygon(_ points: [CGPoint], fill: Color? = nil, stroke: Color? = nil,
                 lineWidth: CGFloat = 2) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        if let fill { self.fill(path, with: .color(fill)) }
        if let stroke {
            self.stroke(path, with: .color(stroke),
                        style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
        }
    }
}

/// Point at `deg` clockwise from straight up, `radius` from `center`.
func polarPoint(_ center: CGPoint, _ deg: Double, _ radius: CGFloat) -> CGPoint {
    let a = deg * .pi / 180
    return CGPoint(x: center.x + radius * CGFloat(sin(a)), y: center.y - radius * CGFloat(cos(a)))
}

/// Layout of the 737-style PFD, on a canvas 100 units wide and 102 tall.
///
/// Everything is drawn in these units and the canvas scaled once, as the
/// A320 PFD is. The layout is parametric: the horizon centre, the attitude
/// frame, the tape band and the scale factors below, and every element is
/// placed from them.
enum B737PFD {
    static let width: CGFloat = 100
    static let height: CGFloat = 102

    // MARK: Attitude

    static let horizonCenter = CGPoint(x: 43, y: 48)
    /// The rounded frame around the attitude sphere, centred on the horizon.
    static let frameHalfWidth: CGFloat = 24.8
    static let frameHalfHeight: CGFloat = 26.6
    static var attitudeFrame: CGRect {
        CGRect(x: horizonCenter.x - frameHalfWidth, y: horizonCenter.y - frameHalfHeight,
               width: 2 * frameHalfWidth, height: 2 * frameHalfHeight)
    }
    static let attitudeCornerRadius: CGFloat = 5
    /// Radius the bank graduations stand on, a little inside the frame top.
    static var bankScaleRadius: CGFloat { frameHalfHeight - 2.3 }
    /// Linear over the whole ±90° range.
    static let pixelsPerDegreePitch: CGFloat = 1.06

    // MARK: Tapes

    /// The tapes share one band, centred on the horizon.
    static var tapeCenterY: CGFloat { horizonCenter.y }
    static let tapeHalfHeight: CGFloat = 36.4
    static var tapeTop: CGFloat { tapeCenterY - tapeHalfHeight }
    static var speedTape: CGRect {
        CGRect(x: 0, y: tapeTop, width: 13, height: 2 * tapeHalfHeight)
    }
    /// The speed tape shows ±60 of its unit around the current speed.
    static var pixelsPerKnot: CGFloat { tapeHalfHeight / 60 }
    static var altitudeTape: CGRect {
        CGRect(x: 75, y: tapeTop, width: 12.6, height: 2 * tapeHalfHeight)
    }
    /// The altitude tape shows ±400 ft.
    static var pixelsPerFoot: CGFloat { tapeHalfHeight / 400 }

    // MARK: Vertical speed

    static let verticalSpeedLeft: CGFloat = 90.9
    /// The inboard lip around the zero line.
    static let verticalSpeedLipX: CGFloat = 93.3
    static let verticalSpeedLipHalfHeight: CGFloat = 8.3
    /// Where the top and bottom edges start to chamfer.
    static let verticalSpeedChamferX: CGFloat = 94.9
    static let verticalSpeedRight: CGFloat = 99.4
    static let verticalSpeedHalfHeight: CGFloat = 25.4
    /// Half-height of the outboard edge, between the chamfers.
    static let verticalSpeedShoulder: CGFloat = 13.8

    /// The V/S scale: a chamfered strip with a lip on its inboard side that
    /// steps back around the zero line.
    static var verticalSpeedOutline: Path {
        let c = tapeCenterY
        let h = verticalSpeedHalfHeight, lip = verticalSpeedLipHalfHeight
        var p = Path()
        p.move(to: CGPoint(x: verticalSpeedLeft, y: c - h))
        p.addLine(to: CGPoint(x: verticalSpeedChamferX, y: c - h))
        p.addLine(to: CGPoint(x: verticalSpeedRight, y: c - verticalSpeedShoulder))
        p.addLine(to: CGPoint(x: verticalSpeedRight, y: c + verticalSpeedShoulder))
        p.addLine(to: CGPoint(x: verticalSpeedChamferX, y: c + h))
        p.addLine(to: CGPoint(x: verticalSpeedLeft, y: c + h))
        p.addLine(to: CGPoint(x: verticalSpeedLeft, y: c + lip))
        p.addLine(to: CGPoint(x: verticalSpeedLipX, y: c + lip))
        p.addLine(to: CGPoint(x: verticalSpeedLipX, y: c - lip))
        p.addLine(to: CGPoint(x: verticalSpeedLeft, y: c - lip))
        p.closeSubpath()
        return p
    }

    /// Where the needle is hinged: well off the right edge of the display.
    static var verticalSpeedPivot: CGPoint { CGPoint(x: verticalSpeedRight + 21.8, y: tapeCenterY) }

    /// Where each graduation sits from the zero line: open up to 1000 ft/min,
    /// compressed beyond, so ±6000 fits.
    static let verticalSpeedBreakpoints: [(fpm: Double, offset: CGFloat)] = [
        (0, 0), (1_000, 10.2), (2_000, 18), (6_000, 23.2),
    ]

    /// Vertical offset of a rate of climb from the zero line (negative = up),
    /// linear between breakpoints and pinned beyond the last.
    static func verticalSpeedOffset(fpm: Double) -> CGFloat {
        let magnitude = abs(fpm)
        var offset = verticalSpeedBreakpoints.last!.offset
        for (a, b) in zip(verticalSpeedBreakpoints, verticalSpeedBreakpoints.dropFirst())
        where magnitude <= b.fpm {
            offset = a.offset + (b.offset - a.offset) * CGFloat((magnitude - a.fpm) / (b.fpm - a.fpm))
            break
        }
        return fpm < 0 ? offset : -offset
    }

    // MARK: Compass

    /// The heading rose is a grey disc centred below the display, under the
    /// horizon centre, whose top arc shows at the foot of the display.
    static var compassCenter: CGPoint { CGPoint(x: horizonCenter.x, y: horizonCenter.y + 73.2) }
    static let compassRadius: CGFloat = 33
    static var compassTop: CGFloat { compassCenter.y - compassRadius }

    // MARK: FMA

    /// Autothrottle, roll and pitch mode boxes, side by side across the top.
    static var fmaBoxes: [CGRect] {
        var x: CGFloat = 15.2
        return [19.5, 18.7, 18.7].map { width in
            defer { x += width }
            return CGRect(x: x, y: 0.4, width: width, height: 6.3)
        }
    }
}
