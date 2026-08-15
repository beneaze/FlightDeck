import SwiftUI

/// Vertical Display — the profile strip beneath the ND on A350/A380 flight
/// decks. Shows the aircraft against an altitude scale on the left and a
/// distance scale along the bottom, with the projected flight path running out
/// ahead of it.
///
/// The real display also paints a terrain cross-section and MORA; that needs an
/// elevation model, which this app does not carry, so the profile is drawn
/// without it rather than with invented ground.
struct VerticalDisplayView: View {
    var altitudeFt: Double
    var selectedAltitudeFt: Double
    var flightPathAngleDeg: Double
    var rangeNm: Double
    var destinationName: String?
    var destinationDistanceNm: Double?

    /// Top of the altitude scale — a round number comfortably above whichever
    /// of the current and target altitudes is higher.
    private var scaleTopFt: Double {
        let highest = max(altitudeFt, selectedAltitudeFt, 1_000)
        let step: Double = highest > 20_000 ? 10_000 : (highest > 6_000 ? 5_000 : 2_000)
        return ((highest * 1.25) / step).rounded(.up) * step
    }

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 34, bottom: CGFloat = 13, top: CGFloat = 4
            let plot = CGRect(x: left, y: top,
                              width: size.width - left - 6,
                              height: size.height - top - bottom)

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

            func y(forFeet feet: Double) -> CGFloat {
                plot.maxY - CGFloat(feet / scaleTopFt) * plot.height
            }
            func x(forNm nm: Double) -> CGFloat {
                plot.minX + CGFloat(nm / rangeNm) * plot.width
            }

            drawAltitudeScale(context, plot: plot, y: y)
            drawDistanceScale(context, plot: plot, x: x, size: size)

            // Selected altitude — cyan, as on the altitude tape.
            let targetY = y(forFeet: selectedAltitudeFt)
            if plot.contains(CGPoint(x: plot.midX, y: targetY)) {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: targetY))
                line.addLine(to: CGPoint(x: plot.maxX, y: targetY))
                context.stroke(line, with: .color(EFIS.cyan),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }

            drawProjectedPath(context, plot: plot, x: x, y: y)
            drawDestination(context, plot: plot, x: x)

            // Aircraft symbol just inside the plot, at the current altitude —
            // clear of the altitude labels running down the left edge.
            let aircraftY = y(forFeet: altitudeFt).clampedTo(plot.minY...plot.maxY)
            var symbol = Path()
            symbol.move(to: CGPoint(x: plot.minX + 1, y: aircraftY - 5))
            symbol.addLine(to: CGPoint(x: plot.minX + 14, y: aircraftY))
            symbol.addLine(to: CGPoint(x: plot.minX + 1, y: aircraftY + 5))
            symbol.closeSubpath()
            context.fill(symbol, with: .color(EFIS.yellow))
        }
        .background(Color.black)
    }

    private func drawAltitudeScale(_ context: GraphicsContext, plot: CGRect,
                                   y: (Double) -> CGFloat) {
        let step: Double = scaleTopFt > 20_000 ? 10_000 : (scaleTopFt > 8_000 ? 5_000 : 2_000)
        var feet = 0.0
        while feet <= scaleTopFt {
            let ty = y(feet)
            context.line(from: CGPoint(x: plot.minX, y: ty),
                         to: CGPoint(x: plot.maxX, y: ty),
                         .white.opacity(feet == 0 ? 0.55 : 0.18), width: 1)
            // Labelled as flight levels, the way the real display does.
            context.digits("\(Int(feet / 100))", at: CGPoint(x: plot.minX - 6, y: ty),
                           size: 9, .white, anchor: .trailing)
            feet += step
        }
    }

    private func drawDistanceScale(_ context: GraphicsContext, plot: CGRect,
                                   x: (Double) -> CGFloat, size: CGSize) {
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let nm = rangeNm * fraction
            let tx = x(nm)
            context.line(from: CGPoint(x: tx, y: plot.maxY),
                         to: CGPoint(x: tx, y: plot.maxY + 4), .white.opacity(0.6), width: 1)
            // Whole miles at cruise ranges, decimals at street scale.
            let label = rangeNm >= 4 ? "\(Int(nm))"
                : String(format: rangeNm >= 1 ? "%.1f" : "%.2f", nm)
            context.digits(label, at: CGPoint(x: tx, y: size.height - 5),
                           size: 9, .white.opacity(0.8))
        }
    }

    /// Where the current flight path angle puts the aircraft over the selected
    /// range, levelling off at the FCU altitude.
    private func drawProjectedPath(_ context: GraphicsContext, plot: CGRect,
                                   x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        let climbing = selectedAltitudeFt > altitudeFt
        let feetPerNm = tan(flightPathAngleDeg * .pi / 180) * 6_076.12

        var path = Path()
        path.move(to: CGPoint(x: x(0), y: y(altitudeFt).clampedTo(plot.minY...plot.maxY)))

        // Distance at which the path meets the selected altitude, if it ever does.
        var levelOffNm = rangeNm
        if abs(feetPerNm) > 1 {
            let needed = (selectedAltitudeFt - altitudeFt) / feetPerNm
            if needed > 0 { levelOffNm = min(needed, rangeNm) }
        }
        let capture = climbing == (feetPerNm > 0) && abs(feetPerNm) > 1

        if capture, levelOffNm < rangeNm {
            path.addLine(to: CGPoint(x: x(levelOffNm),
                                     y: y(selectedAltitudeFt).clampedTo(plot.minY...plot.maxY)))
            path.addLine(to: CGPoint(x: x(rangeNm),
                                     y: y(selectedAltitudeFt).clampedTo(plot.minY...plot.maxY)))
        } else {
            let end = altitudeFt + feetPerNm * rangeNm
            path.addLine(to: CGPoint(x: x(rangeNm), y: y(end).clampedTo(plot.minY...plot.maxY)))
        }
        context.stroke(path, with: .color(EFIS.green), lineWidth: 2)
    }

    private func drawDestination(_ context: GraphicsContext, plot: CGRect, x: (Double) -> CGFloat) {
        guard let distance = destinationDistanceNm, distance <= rangeNm,
              let name = destinationName else { return }
        let tx = x(distance)
        context.line(from: CGPoint(x: tx, y: plot.minY), to: CGPoint(x: tx, y: plot.maxY),
                     EFIS.green.opacity(0.7), width: 1)
        context.digits(name.uppercased().prefix(7).description,
                       at: CGPoint(x: tx - 3, y: plot.minY + 7), size: 9, .white, anchor: .trailing)
    }
}

extension CGFloat {
    func clampedTo(_ range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    VerticalDisplayView(altitudeFt: 9_800, selectedAltitudeFt: 12_000,
                        flightPathAngleDeg: 2.2, rangeNm: 40,
                        destinationName: "BOSTON", destinationDistanceNm: 22)
        .frame(height: 92)
        .background(.black)
}
