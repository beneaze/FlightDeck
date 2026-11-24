import SwiftUI
import UniformTypeIdentifiers

/// The MCDU on screen, laid out like the real unit of the selected flight
/// deck: the Airbus MCDU beside the A320 displays, the Boeing CDU beside the
/// 737's. Every part — screen, line-select keys, function keys, keypads,
/// annunciator strips, slots, knob and screws — sits where it does on the
/// real front panel; positions come from ``MCDUStyle`` as fractions of the
/// unit's width and height, and the unit is scaled once to fit the window.
struct MCDUView: View {
    @ObservedObject var controller: MCDUController
    @ObservedObject private var search: DestinationSearchModel

    // Observed so the pages update live (PROG, download progress…).
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @EnvironmentObject private var packs: FlightPackStore
    @EnvironmentObject private var speedLimits: SpeedLimitProvider

    init(controller: MCDUController) {
        self.controller = controller
        _search = ObservedObject(wrappedValue: controller.search)
    }

    private var style: MCDUStyle { MCDUStyle(flightData.displayStyle) }

    var body: some View {
        GeometryReader { geo in
            let s = style
            let bar: CGFloat = 40
            let availableHeight = geo.size.height - bar - 8
            let availableWidth = geo.size.width - 12
            let height = min(availableHeight, availableWidth / s.aspect)
            let width = height * s.aspect
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 6) {
                    HStack {
                        closeButton
                        Spacer()
                    }
                    .frame(width: max(width, 220), height: bar)
                    unit(s, width: width, height: height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .simultaneousGesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                // A left swipe puts the unit away, as it closed the menu.
                if value.translation.width < -80,
                   abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                    controller.close()
                }
            })
        .fileImporter(isPresented: $controller.isShowingImporter, allowedContentTypes: [.folder]) { result in
            controller.importNavData(result)
        }
        .sheet(isPresented: $controller.isShowingMap) {
            DestinationPickerView { controller.close() }
        }
        .fullScreenCover(isPresented: $controller.isShowingGuide) {
            WelcomeView(isBoeing: controller.style.isBoeing, isReplay: true) { controller.isShowingGuide = false }
        }
    }

    private var closeButton: some View {
        Button {
            controller.close()
        } label: {
            Label("DISPLAYS", systemImage: "chevron.left")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
    }

    // MARK: - The unit

    private func unit(_ s: MCDUStyle, width W: CGFloat, height H: CGFloat) -> some View {
        func frame(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H)
        }
        let screen = frame(s.screenRect)
        let pad = screen.height * 0.035
        let row = (screen.height - 2 * pad) / 14

        return ZStack(alignment: .topLeading) {
            // Front panel.
            RoundedRectangle(cornerRadius: W * 0.025)
                .fill(LinearGradient(colors: [s.bezel.opacity(0.95), s.bezel],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: W * 0.025).stroke(s.bezelEdge, lineWidth: 1))
                .frame(width: W, height: H)

            if let plate = s.functionPlate {
                let r = frame(plate)
                RoundedRectangle(cornerRadius: W * 0.015).fill(s.plate)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }

            ForEach(Array(s.topSlots.enumerated()), id: \.offset) { _, slot in
                let r = frame(slot)
                Capsule().fill(s.slot)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }

            ForEach(Array(s.screws.enumerated()), id: \.offset) { _, p in
                screw(diameter: W * 0.028)
                    .offset(x: p.x * W - W * 0.014, y: p.y * H - W * 0.014)
            }

            ForEach(Array(s.annunciatorStrips.enumerated()), id: \.offset) { _, strip in
                annunciatorStrip(strip.lights, frame: frame(strip.rect), s)
            }

            // Screen in its recessed frame.
            RoundedRectangle(cornerRadius: W * 0.012).fill(s.screenFrame)
                .frame(width: screen.width + W * 0.02, height: screen.height + W * 0.02)
                .offset(x: screen.minX - W * 0.01, y: screen.minY - W * 0.01)
            screenContent(s, pad: pad, row: row, screen: screen)
                .frame(width: screen.width, height: screen.height)
                .background(s.screenBackground)
                .clipShape(RoundedRectangle(cornerRadius: W * 0.008))
                .offset(x: screen.minX, y: screen.minY)

            // Line-select keys, each with its tick mark towards the screen.
            ForEach(0..<6, id: \.self) { i in
                let y = screen.minY + pad + row * (CGFloat(2 * i + 2) + 0.5)
                lsk(left: true, index: i, column: s.lskColumns.left, y: y, s, W: W, H: H, screen: screen)
                lsk(left: false, index: i, column: s.lskColumns.right, y: y, s, W: W, H: H, screen: screen)
            }

            ForEach(s.panelKeys) { key in
                let r = frame(key.rect)
                keyButton(key, size: r.size, s)
                    .offset(x: r.minX, y: r.minY)
            }

            if let knob = s.knob {
                brightnessKnob(radius: knob.radius * W)
                    .offset(x: knob.center.x * W - knob.radius * W, y: knob.center.y * H - knob.radius * W)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    // MARK: Screen

    private func screenContent(_ s: MCDUStyle, pad: CGFloat, row: CGFloat, screen: CGRect) -> some View {
        let content = controller.screen()
        // 24 columns across, at about 0.6 em per character.
        let font = min(screen.width * 0.97 / (24 * 0.6), row * 1.25)
        return VStack(spacing: 0) {
            line(MCDULine(center: content.title,
                          right: content.pageNumber.map { [MCDURun(text: $0, small: true)] } ?? []),
                 s, font: font, row: row)
            ForEach(0..<12, id: \.self) { i in
                line(content.rows.indices.contains(i) ? content.rows[i] : .empty, s, font: font, row: row)
            }
            let scratch = controller.scratchpadText
            line(MCDULine(left: [MCDURun(text: scratch.text, color: scratch.amber ? .amber : .white)]),
                 s, font: font, row: row)
        }
        .padding(.vertical, pad)
        .padding(.horizontal, screen.width * 0.012)
    }

    private func line(_ line: MCDULine, _ s: MCDUStyle, font: CGFloat, row: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 0) {
                text(line.left, s, font: font)
                Spacer(minLength: 0)
            }
            text(line.center, s, font: font)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                text(line.right, s, font: font)
            }
        }
        .lineLimit(1)
        .frame(height: row)
    }

    private func text(_ runs: [MCDURun], _ s: MCDUStyle, font: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            ForEach(runs.indices, id: \.self) { i in
                let run = runs[i]
                let size = run.small ? font * 0.76 : font
                // Spaces set the width the boxes take, cell for cell.
                Text(run.text)
                    .font(s.font(font, small: run.small))
                    .foregroundStyle(s.color(run.color))
                    .overlay {
                        if run.isBoxes {
                            MCDUBoxes(count: run.text.count, color: s.color(run.color), fontSize: size)
                        }
                    }
            }
        }
    }

    // MARK: Line-select keys

    private func lsk(left: Bool, index: Int, column: ClosedRange<CGFloat>, y: CGFloat, _ s: MCDUStyle,
                     W: CGFloat, H: CGFloat, screen: CGRect) -> some View {
        let x0 = column.lowerBound * W, width = (column.upperBound - column.lowerBound) * W
        let height = s.lskHeight * H
        let tickFrom = left ? x0 + width : screen.maxX + W * 0.012
        let tickTo = left ? screen.minX - W * 0.012 : x0
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: min(tickFrom, tickTo) + W * 0.006, y: y))
                p.addLine(to: CGPoint(x: max(tickFrom, tickTo) - W * 0.006, y: y))
            }
            .stroke(Color.white.opacity(0.75), lineWidth: max(1, W * 0.003))

            Button {
                controller.press(.lsk(left: left, index: index))
            } label: {
                ZStack {
                    // The Airbus keys are plain black caps with a white dash;
                    // the Boeing keys have a lighter rim around the cap.
                    if s.isBoeing {
                        RoundedRectangle(cornerRadius: height * 0.2).fill(Color(white: 0.62))
                        RoundedRectangle(cornerRadius: height * 0.15).fill(s.keyFace)
                            .padding(height * 0.14)
                    }
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: width * 0.4, height: max(1.2, height * 0.1))
                }
                .frame(width: width, height: height)
            }
            .buttonStyle(MCDUKeyStyle(style: s, cornerRadius: height * 0.2, drawsFace: !s.isBoeing))
            .offset(x: x0, y: y - height / 2)
        }
    }

    // MARK: Keys

    private func keyButton(_ key: MCDUPanelKey, size: CGSize, _ s: MCDUStyle) -> some View {
        let lines = key.label.split(separator: "\n").count
        let fontSize: CGFloat
        if key.round {
            fontSize = size.height * 0.42
        } else if key.small || lines > 1 {
            fontSize = min(size.height * (lines > 1 ? 0.3 : 0.36), size.width * 0.2)
        } else if key.label.count == 1 {
            fontSize = size.height * 0.55
        } else {
            fontSize = min(size.height * 0.4, size.width * 0.22)
        }
        let isExec = key.key == .exec
        return Button {
            controller.press(key.key)
        } label: {
            ZStack(alignment: .top) {
                ZStack {
                    if key.boxed {
                        RoundedRectangle(cornerRadius: 1.5)
                            .stroke(s.keyLabel.opacity(0.9), lineWidth: 1)
                            .frame(width: size.height * 0.62, height: size.height * 0.62)
                    }
                    Text(key.label)
                        .font(.system(size: fontSize, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineSpacing(-fontSize * 0.15)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(s.keyLabel)
                        .padding(.top, isExec ? size.height * 0.12 : 0)
                }
                .frame(width: size.width, height: size.height)
                if isExec {
                    // The EXEC key's light bar, lit while a flight waits to be
                    // activated.
                    Capsule()
                        .fill(controller.isExecLit ? Color(white: 0.97) : Color.white.opacity(0.12))
                        .frame(width: size.width * 0.55, height: size.height * 0.1)
                        .padding(.top, size.height * 0.1)
                        .shadow(color: controller.isExecLit ? .white : .clear, radius: 3)
                }
            }
        }
        .buttonStyle(MCDUKeyStyle(style: s, cornerRadius: key.round ? size.width / 2 : min(size.width, size.height) * 0.18))
    }

    // MARK: Panel details

    private func annunciatorStrip(_ lights: [String], frame r: CGRect, _ s: MCDUStyle) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(lights.enumerated()), id: \.offset) { _, light in
                let lit = isLit(light, s)
                Text(light)
                    .font(.system(size: max(5, r.width * 0.3), weight: .heavy))
                    .minimumScaleFactor(0.5)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                    .foregroundStyle(lit ? s.annunciatorOn : s.annunciatorOff)
                    .shadow(color: lit ? s.annunciatorOn.opacity(0.8) : .clear, radius: 3)
                    .frame(width: r.width, height: r.height / CGFloat(max(lights.count, 1)))
            }
        }
        .frame(width: r.width, height: r.height)
        .background(RoundedRectangle(cornerRadius: r.width * 0.25).fill(Color(white: 0.06)))
        .offset(x: r.minX, y: r.minY)
    }

    private func isLit(_ light: String, _ s: MCDUStyle) -> Bool {
        switch light {
        case "MSG": return controller.message != nil
        default: return false
        }
    }

    private func screw(diameter d: CGFloat) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Rectangle().fill(Color(white: 0.2)).frame(width: d * 0.6, height: max(1, d * 0.12))
                .rotationEffect(.degrees(35))
        }
        .frame(width: d, height: d)
    }

    private func brightnessKnob(radius r: CGFloat) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.08)],
                                         startPoint: .top, endPoint: .bottom))
            Circle().stroke(Color.black.opacity(0.6), lineWidth: 1)
            Capsule().fill(Color.white.opacity(0.8))
                .frame(width: max(1.5, r * 0.12), height: r * 0.5)
                .offset(y: -r * 0.45)
                .rotationEffect(.degrees(30))
        }
        .frame(width: 2 * r, height: 2 * r)
    }
}

/// The keys' caps: a slightly raised dark face that sinks when pressed.
private struct MCDUKeyStyle: ButtonStyle {
    let style: MCDUStyle
    var cornerRadius: CGFloat = 4
    var drawsFace = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Group {
                    if drawsFace {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(LinearGradient(
                                colors: [style.keyFace.opacity(configuration.isPressed ? 0.75 : 1.0),
                                         style.keyFace.opacity(configuration.isPressed ? 0.6 : 0.88)],
                                startPoint: .top, endPoint: .bottom))
                            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                                .stroke(Color.black.opacity(0.7), lineWidth: 1))
                            .shadow(color: .black.opacity(configuration.isPressed ? 0.2 : 0.55),
                                    radius: configuration.isPressed ? 0.5 : 1.5, y: configuration.isPressed ? 0 : 1.2)
                    }
                }
            )
            .brightness(configuration.isPressed && !drawsFace ? -0.15 : 0)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

/// The amber boxes of an entry the page needs: one outlined box per
/// character cell, nearly as wide as the cell and as tall as a capital,
/// with a hair of space between neighbours.
struct MCDUBoxes: View {
    let count: Int
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(max(count, 1))
            let line = max(1, fontSize * 0.085)
            let height = fontSize * 0.74
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    Rectangle()
                        .strokeBorder(color, lineWidth: line)
                        .frame(width: cell * 0.84, height: height)
                        .frame(width: cell)
                }
            }
            // Sit on the baseline like the capitals beside them.
            .frame(height: geo.size.height, alignment: .center)
            .offset(y: -fontSize * 0.03)
        }
        .accessibilityHidden(true)
    }
}
