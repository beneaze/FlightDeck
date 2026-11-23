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

    private var efis: some View {
        PanelBlock(width: Self.efisWidth, height: Self.height) {
            // Baro reference: the window, the knob (pull for STD, push for
            // QNH) and its inHg / hPa ring.
            LCDWindow(width: 90, height: 34) {
                PanelBlock(width: 90, height: 34) {
                    LCDLabel(text: "QNH", lit: !readout.isStandardBaro, size: 7).position(x: 13, y: 8)
                    let text = readout.isStandardBaro ? "Std" : "1013"
                    SegmentText(text: text, cells: text.count, height: 20, color: FCUColors.airbusDigits, ghost: Self.ghost)
                        .position(x: 52, y: 19)
                }
            }
            .position(x: 60, y: 32)
            FCULegend("inHg", size: 7).position(x: 26, y: 68)
            FCULegend("hPa", size: 7).position(x: 94, y: 68)
            FCUTurnable(onTurn: { _ in }, onPush: { c.setStandardBaro(false) }, onPull: { c.setStandardBaro(true) }) { t in
                ZStack {
                    // The inHg / hPa ring, at hPa as the window reads.
                    SelectorRing(outer: 58, band: 6, tabAngle: 52, tabLength: 10, recessInside: true)
                    KnurledKnob(diameter: 42, turns: t, ridges: 30)
                }
            }
            .position(x: 60, y: 94)
            FCULegend("PULL STD", size: 7).position(x: 60, y: 129)

            AirbusPushbutton(legend: "FD", lit: af.flightDirector, width: 46, height: 38, action: c.toggleFlightDirector)
                .position(x: 150, y: 32)
            AirbusPushbutton(legend: "LS", lit: af.landingSystem, width: 46, height: 38, action: c.toggleLandingSystem)
                .position(x: 204, y: 32)
            AirbusPushbutton(legend: "TERR\nON ND", lit: af.terrainOnND, width: 58, height: 44, action: c.toggleTerrain)
                .position(x: 177, y: 92)

            // ND mode and range: the ND has its own range keys, so the
            // range knob carries no pointer; the mode is the ND's arc.
            PointerSelector(labels: ["LS", "VOR", "NAV", "ARC", "PLAN"], angles: fcuArc(5, from: -110, to: 110),
                            selected: 3, diameter: 28, labelRadius: 25)
                .position(x: 60, y: 166)
            PointerSelector(labels: ["10", "20", "40", "80", "160", "320"], angles: fcuArc(6, from: -120, to: 120),
                            selected: nil, diameter: 28, labelRadius: 25)
                .position(x: 177, y: 166)
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
            FCULegend("SPD\nMACH", size: 8).position(x: 36, y: 115)
            AirbusRoundButton(action: nil).position(x: 36, y: 146)
            FCUTurnable(onTurn: { steps in
                            let shown = speedPresetShown
                            c.turnAirbusSpeed(steps, presetShown: shown)
                            if !af.isSpeedSelected { showSpeedPreset() }
                        },
                        onPush: { speedPresetUntil = nil; c.manageSpeed() },
                        onPull: { c.pullAirbusSpeed(presetShown: speedPresetShown); speedPresetUntil = nil }) { t in
                KnurledKnob(diameter: 64, turns: t, index: true)
            }
            .position(x: 108, y: 140)
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
                KnurledKnob(diameter: 64, turns: t, index: true)
            }
            .position(x: 77, y: 140)
            AirbusPushbutton(legend: "LOC", lit: af.localizerArmed, action: c.toggleLocalizer)
                .position(x: 158, y: 154)
        }
    }

    // MARK: - Autopilot column

    private var center: some View {
        PanelBlock(width: Self.centerWidth, height: Self.height) {
            // The HDG-V/S / TRK-FPA switch: the panel's reference stays
            // HDG and V/S, so it is drawn but inert.
            FCULegend("HDG\nV/S", size: 8).position(x: 38, y: 40)
            AirbusRoundButton(action: nil).position(x: 75, y: 40)
            FCULegend("TRK\nFPA", size: 8).position(x: 112, y: 40)

            AirbusPushbutton(legend: "AP1", lit: af.autopilot1, width: 50, action: c.toggleAutopilot1)
                .position(x: 42, y: 104)
            AirbusPushbutton(legend: "AP2", lit: af.autopilot2, width: 50, action: c.toggleAutopilot2)
                .position(x: 108, y: 104)
            AirbusPushbutton(legend: "A/THR", lit: af.autothrust, width: 50, action: c.toggleAutothrust)
                .position(x: 75, y: 160)
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

            altitudeKnob(step100: step100).position(x: 150, y: 142)

            // METRIC ALT and EXPED: no metric display and no expedite mode
            // here, so they are on the panel but inert.
            AirbusPushbutton(legend: "METRIC\nALT", width: 46, height: 38, action: nil)
                .position(x: 244, y: 112)
            AirbusPushbutton(legend: "EXPED", width: 46, height: 38, action: nil)
                .position(x: 244, y: 166)

            FCUTurnable(onTurn: c.turnVerticalSpeed, onPush: c.levelOff, onPull: c.engageVerticalSpeed) { t in
                KnurledKnob(diameter: 62, turns: t, index: true)
            }
            .position(x: 330, y: 142)
            AirbusPushbutton(legend: "APPR", lit: af.approachArmed, action: c.toggleApproach)
                .position(x: 398, y: 158)
        }
    }

    /// The ALT knob inside its 100 / 1000 selector ring: tap a figure to
    /// move the ring's tab to it.
    private func altitudeKnob(step100: Bool) -> some View {
        let tabAngle = step100 ? -56.0 : 56.0
        return ZStack {
            SelectorRing(outer: 90, band: 9, tabAngle: tabAngle, tabLength: 13, recessInside: true)
                .animation(.easeOut(duration: 0.15), value: step100)
            FCUTurnable(onTurn: c.turnAltitude, onPush: c.leaveVerticalSpeed, onPull: c.leaveVerticalSpeed) { t in
                KnurledKnob(diameter: 62, turns: t, index: true)
            }
            stepButton("100", feet: 100, angle: -50)
            stepButton("1000", feet: 1_000, angle: 50)
        }
        .frame(width: 140, height: 120)
    }

    private func stepButton(_ label: String, feet: Double, angle: Double) -> some View {
        let a = angle * .pi / 180, r: CGFloat = 70
        return Button { c.setAltitudeStep(feet) } label: {
            FCULegend(label, size: 9)
                .frame(width: 34, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(sin(a)) * r, y: -CGFloat(cos(a)) * r)
    }

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
