import SwiftUI

/// The A320 glareshield, our own drawing after the real units: the
/// captain's EFIS control panel, then the FCU — SPD/MACH, HDG/TRK, the
/// autopilot column, and ALT with V/S/FPA under one long LCD.
///
/// In landscape both units sit in one row as on the aircraft; in portrait
/// the FCU is cut into rows, read left to right: EFIS and SPD, then HDG
/// and the AP column, then ALT and V/S.
struct A320Panel: View, Equatable {
    let readout: FCUReadout
    let landscape: Bool
    let controls: FCUControls

    nonisolated static func == (a: A320Panel, b: A320Panel) -> Bool {
        a.readout == b.readout && a.landscape == b.landscape
    }

    // Section sizes, in panel units.
    private static let height: CGFloat = 200
    private static let efisWidth: CGFloat = 240
    private static let speedWidth: CGFloat = 170
    private static let headingWidth: CGFloat = 190
    private static let centerWidth: CGFloat = 150
    private static let verticalWidth: CGFloat = 430
    private static let unitGap: CGFloat = 14
    private static let rowGap: CGFloat = 10
    private static let margin: CGFloat = 4

    static func size(landscape: Bool) -> CGSize {
        if landscape {
            let fcu = speedWidth + headingWidth + centerWidth + verticalWidth
            return CGSize(width: efisWidth + unitGap + fcu + 2 * margin, height: height + 2 * margin)
        }
        return CGSize(width: verticalWidth + 2 * margin, height: 3 * height + 2 * rowGap + 2 * margin)
    }

    private var af: AutoFlight { readout.af }
    private var c: FCUControls { controls }

    /// A knob turned while its target is managed shows the preset value
    /// for a while — 10 s for SPD, 45 s for HDG, as on the real unit — then
    /// the dashes come back unless the knob is pulled.
    @State private var speedPresetUntil: Date?
    @State private var headingPresetUntil: Date?
    @State private var presetClock = Date()

    private var speedPresetShown: Bool { (speedPresetUntil ?? .distantPast) > presetClock }
    private var headingPresetShown: Bool { (headingPresetUntil ?? .distantPast) > presetClock }

    private func showSpeedPreset() {
        let until = Date().addingTimeInterval(10)
        speedPresetUntil = until
        refreshPresets(at: until)
    }

    private func showHeadingPreset() {
        let until = Date().addingTimeInterval(45)
        headingPresetUntil = until
        refreshPresets(at: until)
    }

    /// Redraws now, and again once the preset has run out.
    private func refreshPresets(at until: Date) {
        presetClock = Date()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 0.1))
            presetClock = Date()
        }
    }

    var body: some View {
        Group {
            if landscape {
                HStack(spacing: Self.unitGap) {
                    efis.fcuPlate(boeing: false)
                    HStack(spacing: 0) { speed; heading; center; vertical }
                        .fcuPlate(boeing: false)
                }
            } else {
                VStack(spacing: Self.rowGap) {
                    HStack(spacing: Self.rowGap) {
                        efis.fcuPlate(boeing: false)
                        speed.frame(width: Self.verticalWidth - Self.efisWidth - Self.rowGap)
                            .fcuPlate(boeing: false)
                    }
                    HStack(spacing: 30) { heading; center }
                        .frame(width: Self.verticalWidth)
                        .fcuPlate(boeing: false)
                    vertical.fcuPlate(boeing: false)
                }
            }
        }
        .padding(Self.margin)
    }

    // MARK: - EFIS control panel (captain)

    /// Laid out as the real panel: the baro window over the baro knob
    /// (pull for STD, push for QNH, in its inHg / hPa ring) with FD and LS
    /// under it; across the top the map options (here TERR ON ND, the one
    /// that does something), then the ND mode and range selectors over the
    /// ADF / VOR switches. The ND has its own range keys and shows its own
    /// map, so the selectors and switches are drawn but inert.
    private var efis: some View {
        PanelBlock(width: Self.efisWidth, height: Self.height) {
            LCDWindow(width: 72, height: 34) {
                PanelBlock(width: 72, height: 34) {
                    LCDLabel(text: "QNH", lit: !readout.isStandardBaro, size: 7).position(x: 36, y: 7)
                    let text = readout.isStandardBaro ? "Std" : "1013"
                    SegmentText(text: text, cells: text.count, height: 17, color: FCUColors.airbusDigits, ghost: Self.ghost)
                        .position(x: 36, y: 22)
                }
            }
            .position(x: 50, y: 30)
            printedArc(center: CGPoint(x: 50, y: 106), radius: 33, from: -42, to: 42)
            FCULegend("in Hg", size: 7.5).position(x: 18, y: 70)
            FCULegend("hPa", size: 7.5).position(x: 84, y: 70)
            FCUTurnable(onTurn: { _ in }, onPush: { c.setStandardBaro(false) }, onPull: { c.setStandardBaro(true) }) { t in
                // The ring's dot at hPa, as the window reads.
                AirbusKnob(kind: .baro, diameter: 56, turns: t, selectorAngle: 40)
            }
            .position(x: 50, y: 112)
            AirbusPushbutton(legend: "FD", lit: af.flightDirector, width: 40, height: 26, action: c.toggleFlightDirector)
                .position(x: 28, y: 176)
            AirbusPushbutton(legend: "LS", lit: af.landingSystem, width: 40, height: 26, action: c.toggleLandingSystem)
                .position(x: 74, y: 176)
            Rectangle().fill(FCUColors.airbusLegend.opacity(0.9)).frame(width: 1.4, height: 112).position(x: 98, y: 134)

            AirbusPushbutton(legend: "TERR ON ND", lit: af.terrainOnND, width: 92, height: 26, fontSize: 9,
                             action: c.toggleTerrain)
                .position(x: 172, y: 24)

            AirbusSelector(labels: ["LS", "VOR", "NAV", "ARC", "PLAN"], angles: fcuArc(5, from: -95, to: 95),
                           pointer: 47.5, diameter: 36, labelRadius: 28, labelSize: 7.5)
                .position(x: 134, y: 98)
            AirbusSelector(labels: ["10", "20", "40", "80", "160", "320"], angles: fcuArc(6, from: -110, to: 110),
                           pointer: -22, diameter: 36, labelRadius: 28, labelSize: 7.5)
                .position(x: 204, y: 98)
            ForEach([134.0, 204.0], id: \.self) { x in
                FCULegend("ADF", size: 7).position(x: x - 21, y: 166)
                FCULegend("VOR", size: 7).position(x: x + 22, y: 166)
                AirbusBallSwitch(diameter: 20).position(x: x, y: 166)
                FCULegend("OFF", size: 7).position(x: x, y: 184)
            }
        }
    }

    // MARK: - SPD / MACH

    private var speed: some View {
        let unitTag: String? = {
            switch readout.speedUnit {
            case .knots: return nil
            case .kmh: return "KM/H"
            case .mph: return "MPH"
            }
        }()
        // Selected: the target. Managed: dashes, or the preset while one
        // is shown; the managed dot stays lit either way.
        let preset = speedPresetShown ? af.speedTargetKts.map { Int(($0 * readout.speedUnit.perKnot).rounded()) } : nil
        let text = (readout.selectedSpeed ?? preset).map { String(format: "%03d", $0) } ?? "---"
        return PanelBlock(width: Self.speedWidth, height: Self.height) {
            LCDWindow(width: 126, height: 56) {
                PanelBlock(width: 126, height: 56) {
                    LCDLabel(text: "SPD").position(x: 18, y: 10)
                    if let unitTag { LCDLabel(text: unitTag, size: 6.5).position(x: 45, y: 10) }
                    LCDLabel(text: "MACH", lit: false).position(x: 100, y: 10)
                    SegmentText(text: text, cells: 3, height: 26, color: FCUColors.airbusDigits, ghost: Self.ghost)
                        .position(x: 56, y: 35)
                    managedDot(!af.isSpeedSelected).position(x: 108, y: 35)
                }
            }
            .position(x: 85, y: 44)
            FCURoundButton(diameter: 30, action: nil).position(x: 32, y: 108)
            FCULegend("SPD\nMACH", size: 8).position(x: 32, y: 140)
            FCUTurnable(onTurn: { steps in
                            let shown = speedPresetShown
                            c.turnAirbusSpeed(steps, presetShown: shown)
                            if !af.isSpeedSelected { showSpeedPreset() }
                        },
                        onPush: { speedPresetUntil = nil; c.manageSpeed() },
                        onPull: { c.pullAirbusSpeed(presetShown: speedPresetShown); speedPresetUntil = nil }) { t in
                AirbusKnob(kind: .speed, diameter: Self.knob, turns: t)
            }
            .position(x: 102, y: Self.knobY)
        }
    }

    // MARK: - HDG / TRK

    private var heading: some View {
        let preset = headingPresetShown ? af.headingTargetDeg : nil
        let text = (af.selectedHeadingDeg ?? preset).map { String(format: "%03d", Int($0.rounded()) % 360) } ?? "---"
        return PanelBlock(width: Self.headingWidth, height: Self.height) {
            LCDWindow(width: 126, height: 56) {
                PanelBlock(width: 126, height: 56) {
                    LCDLabel(text: "HDG").position(x: 18, y: 10)
                    LCDLabel(text: "TRK", lit: false).position(x: 46, y: 10)
                    LCDLabel(text: "LAT").position(x: 106, y: 10)
                    SegmentText(text: text, cells: 3, height: 26, color: FCUColors.airbusDigits, ghost: Self.ghost)
                        .position(x: 56, y: 35)
                    managedDot(!af.isHeadingSelected).position(x: 108, y: 35)
                }
            }
            .position(x: 77, y: 44)
            FCUTurnable(onTurn: { steps in
                            let shown = headingPresetShown
                            c.turnAirbusHeading(steps, presetShown: shown)
                            if !af.isHeadingSelected { showHeadingPreset() }
                        },
                        onPush: { headingPresetUntil = nil; c.manageHeading() },
                        onPull: { c.pullAirbusHeading(presetShown: headingPresetShown); headingPresetUntil = nil }) { t in
                AirbusKnob(kind: .heading, diameter: Self.knob, turns: t)
            }
            .position(x: 77, y: Self.knobY)
            // LOC sits under the HDG knob, as on the real unit.
            AirbusPushbutton(legend: "LOC", lit: af.localizerArmed, width: Self.smallButton.width,
                             height: Self.smallButton.height, action: c.toggleLocalizer)
                .position(x: 77, y: Self.buttonY)
        }
    }

    // MARK: - Autopilot column

    private var center: some View {
        PanelBlock(width: Self.centerWidth, height: Self.height) {
            // The white lines printed either side of the column.
            Rectangle().fill(FCUColors.airbusLegend.opacity(0.9)).frame(width: 1.4, height: 150).position(x: 4, y: 116)
            Rectangle().fill(FCUColors.airbusLegend.opacity(0.9)).frame(width: 1.4, height: 150).position(x: 146, y: 116)
            // The HDG-V/S / TRK-FPA switch: the panel's reference stays
            // HDG and V/S, so it is drawn but inert.
            FCULegend("HDG\nTRK", size: 8).position(x: 37, y: 50)
            FCURoundButton(diameter: 32, action: nil).position(x: 75, y: 50)
            FCULegend("V/S\nFPA", size: 8).position(x: 113, y: 50)

            AirbusPushbutton(legend: "AP1", lit: af.autopilot1, action: c.toggleAutopilot1)
                .position(x: 47, y: 108)
            AirbusPushbutton(legend: "AP2", lit: af.autopilot2, action: c.toggleAutopilot2)
                .position(x: 103, y: 108)
            AirbusPushbutton(legend: "A/THR", lit: af.autothrust, action: c.toggleAutothrust)
                .position(x: 75, y: 166)
        }
    }

    // MARK: - ALT and V/S / FPA

    private var vertical: some View {
        let altitude = String(format: "%05d", Int(readout.selectedAltitudeFt.rounded()))
        let vs: String = af.selectedVerticalSpeedFpm.map { v in
            v == 0 ? "00oo" : String(format: "%@%02doo", v < 0 ? "-" : "+", Int(abs(v) / 100))
        } ?? "-----"
        let step100 = af.altitudeStepFt == 100
        return PanelBlock(width: Self.verticalWidth, height: Self.height) {
            LCDWindow(width: 402, height: 56) {
                PanelBlock(width: 402, height: 56) {
                    LCDLabel(text: "HDG  V/S", size: 8).position(x: 34, y: 18)
                    LCDLabel(text: "TRK  FPA", lit: false, size: 8).position(x: 34, y: 38)
                    LCDLabel(text: "ALT").position(x: 106, y: 10)
                    SegmentText(text: altitude, cells: 5, height: 26, color: FCUColors.airbusDigits, ghost: Self.ghost)
                        .position(x: 150, y: 35)
                    managedDot(!af.isVerticalSpeedEngaged).position(x: 202, y: 35)
                    // LVL/CH, its bracket spanning the ALT and V/S windows.
                    LCDLabel(text: "LVL/CH").position(x: 262, y: 10)
                    Rectangle().fill(FCUColors.airbusDigits).frame(width: 18, height: 1.5).position(x: 230, y: 10)
                    Rectangle().fill(FCUColors.airbusDigits).frame(width: 18, height: 1.5).position(x: 294, y: 10)
                    LCDLabel(text: "V/S").position(x: 318, y: 10)
                    LCDLabel(text: "FPA", lit: false).position(x: 352, y: 10)
                    SegmentText(text: vs, cells: 5, height: 26, color: FCUColors.airbusDigits, ghost: Self.ghost)
                        .position(x: 340, y: 35)
                }
            }
            .position(x: 215, y: 44)

            altitudeKnob(step100: step100).position(x: 150, y: Self.knobY)
            // EXPED under the ALT knob; no expedite mode here, so inert.
            AirbusPushbutton(legend: "EXPED", width: Self.smallButton.width, height: Self.smallButton.height, action: nil)
                .position(x: 150, y: Self.buttonY)

            // METRIC ALT: a round button between the ALT and V/S knobs. No
            // metric display here, so inert.
            FCURoundButton(diameter: 32, action: nil).position(x: 240, y: 104)
            FCULegend("METRIC\nALT", size: 8).position(x: 240, y: 137)

            // UP / DN round the V/S knob's left side, PUSH TO LEVEL OFF on
            // its right.
            verticalSpeedArrows(center: CGPoint(x: 330, y: Self.knobY))
            FCULegend("UP", size: 8).position(x: 324, y: 80)
            FCULegend("DN", size: 8).position(x: 299, y: 167)
            FCULegend("PUSH\nTO\nLEVEL\nOFF", size: 7.5).position(x: 392, y: Self.knobY)
            FCUTurnable(onTurn: c.turnVerticalSpeed, onPush: c.levelOff, onPull: c.engageVerticalSpeed) { t in
                AirbusKnob(kind: .verticalSpeed, diameter: Self.knob, turns: t)
            }
            .position(x: 330, y: Self.knobY)
            AirbusPushbutton(legend: "APPR", lit: af.approachArmed, width: Self.smallButton.width,
                             height: Self.smallButton.height, action: c.toggleApproach)
                .position(x: 330, y: Self.buttonY)
        }
    }

    /// The ALT knob in its black 100 / 1000 selector ring, the figures and
    /// their ticks printed above: tap a figure to turn the ring's dot to it.
    private func altitudeKnob(step100: Bool) -> some View {
        let dotAngle = step100 ? -38.0 : 38.0
        return ZStack {
            ForEach([-38.0, 38.0], id: \.self) { a in
                Capsule().fill(FCUColors.airbusLegend.opacity(0.95))
                    .frame(width: 1.3, height: 5)
                    .offset(y: -Self.knob / 2 - 4)
                    .rotationEffect(.degrees(a))
            }
            FCUTurnable(onTurn: c.turnAltitude, onPush: c.leaveVerticalSpeed, onPull: c.leaveVerticalSpeed) { t in
                AirbusKnob(kind: .altitude, diameter: Self.knob, turns: t, selectorAngle: dotAngle)
                    .animation(.easeOut(duration: 0.15), value: step100)
            }
            stepButton("100", feet: 100, angle: -36)
            stepButton("1000", feet: 1_000, angle: 36)
        }
        .frame(width: 120, height: 110)
    }

    private func stepButton(_ label: String, feet: Double, angle: Double) -> some View {
        let a = angle * .pi / 180, r: CGFloat = 46
        return Button { c.setAltitudeStep(feet) } label: {
            FCULegend(label, size: 8.5)
                .frame(width: 34, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(sin(a)) * r, y: -CGFloat(cos(a)) * r)
    }

    /// The curved arrows printed round the V/S knob's left: up to UP at
    /// the top, down to DN at the bottom.
    private func verticalSpeedArrows(center: CGPoint) -> some View {
        Canvas { ctx, _ in
            let r = Self.knob / 2 + 7
            for (from, to) in [(-95.0, -28.0), (-112.0, -150.0)] {
                var arc = Path()
                let n = 20
                var last = CGPoint.zero, prev = CGPoint.zero
                for i in 0...n {
                    let a = (from + (to - from) * Double(i) / Double(n)) * .pi / 180
                    let pt = CGPoint(x: center.x + r * CGFloat(sin(a)), y: center.y - r * CGFloat(cos(a)))
                    if i == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
                    prev = last; last = pt
                }
                ctx.stroke(arc, with: .color(FCUColors.airbusLegend.opacity(0.95)), lineWidth: 1.3)
                // The arrowhead along the arc's last direction.
                let dx = last.x - prev.x, dy = last.y - prev.y
                let len = max(0.01, (dx * dx + dy * dy).squareRoot())
                let ux = dx / len, uy = dy / len
                let head = Path { p in
                    p.move(to: CGPoint(x: last.x + ux * 4, y: last.y + uy * 4))
                    p.addLine(to: CGPoint(x: last.x - uy * 2.6, y: last.y + ux * 2.6))
                    p.addLine(to: CGPoint(x: last.x + uy * 2.6, y: last.y - ux * 2.6))
                    p.closeSubpath()
                }
                ctx.fill(head, with: .color(FCUColors.airbusLegend.opacity(0.95)))
            }
        }
        .frame(width: Self.verticalWidth, height: Self.height)
        .position(x: Self.verticalWidth / 2, y: Self.height / 2)
        .allowsHitTesting(false)
    }

    /// A thin printed arc (the baro knob's inHg — hPa), degrees clockwise
    /// from the top.
    private func printedArc(center: CGPoint, radius: CGFloat, from: Double, to: Double) -> some View {
        Path { p in
            let n = 24
            for i in 0...n {
                let a = (from + (to - from) * Double(i) / Double(n)) * .pi / 180
                let pt = CGPoint(x: center.x + radius * CGFloat(sin(a)), y: center.y - radius * CGFloat(cos(a)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
        .stroke(FCUColors.airbusLegend.opacity(0.95), lineWidth: 1.1)
    }

    /// Knob and pushbutton sizes and rows, as on the real unit: the knobs'
    /// bezels all one size, the small pushbuttons under them.
    private static let knob: CGFloat = 64
    private static let knobY: CGFloat = 122
    private static let buttonY: CGFloat = 180
    private static let smallButton = CGSize(width: 42, height: 26)

    /// How strongly the unlit segments show through the LCD glass.
    private static let ghost = 0.08

    /// The managed dot beside a window's digits; a faint ghost when off,
    /// as an unlit LCD segment.
    private func managedDot(_ on: Bool) -> some View {
        Circle().fill(FCUColors.airbusDigits.opacity(on ? 1 : Self.ghost))
            .frame(width: 9, height: 9)
            .shadow(color: on ? FCUColors.airbusDigits.opacity(0.75) : .clear, radius: 1)
            .shadow(color: on ? FCUColors.airbusDigits.opacity(0.35) : .clear, radius: 3.5)
    }
}
