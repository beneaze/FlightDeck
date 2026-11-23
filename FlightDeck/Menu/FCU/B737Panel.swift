import SwiftUI

/// The 737NG glareshield, our own drawing after the real units: the MCP —
/// COURSE, F/D, A/T ARM, N1 and SPEED, IAS/MACH, VNAV and LVL CHG,
/// HEADING with its bank-angle ring, LNAV / VOR LOC / APP, ALTITUDE, the
/// V/S thumbwheel, the A/P engage buttons, F/D and COURSE again — and the
/// captain's EFIS control panel with its TERR button.
///
/// In landscape the MCP is one long strip with the EFIS control panel
/// under its left end; in portrait the MCP is cut into rows, read left to
/// right, with the EFIS control panel last.
struct B737Panel: View, Equatable {
    let readout: FCUReadout
    let landscape: Bool
    let controls: FCUControls

    nonisolated static func == (a: B737Panel, b: B737Panel) -> Bool {
        a.readout == b.readout && a.landscape == b.landscape
    }

    private static let height: CGFloat = 170
    private static let rowWidth: CGFloat = 446
    private static let efisWidth: CGFloat = 290
    private static let gap: CGFloat = 12
    private static let margin: CGFloat = 4

    private static let widths: [CGFloat] = [100, 56, 70, 66, 136, 66, 170, 66, 140, 140, 140, 56, 100]
    private static var mcpWidth: CGFloat { widths.reduce(0, +) }

    static func size(landscape: Bool) -> CGSize {
        if landscape {
            return CGSize(width: mcpWidth + 2 * margin, height: 2 * height + gap + 2 * margin)
        }
        return CGSize(width: rowWidth + 2 * margin, height: 4 * height + 3 * gap + 2 * margin)
    }

    private var af: AutoFlight { readout.af }
    private var c: FCUControls { controls }

    var body: some View {
        Group {
            if landscape {
                VStack(alignment: .leading, spacing: Self.gap) {
                    HStack(spacing: 0) {
                        course(captain: true); flightDirector(captain: true); autothrottle; thrustModes
                        speed; verticalModes; heading; lateralModes
                        altitude; verticalSpeed; autopilot
                        flightDirector(captain: false); course(captain: false)
                    }
                    .fcuPlate(boeing: true)
                    efis.fcuPlate(boeing: true)
                }
            } else {
                VStack(spacing: Self.gap) {
                    row { course(captain: true); flightDirector(captain: true); autothrottle; thrustModes; speed }
                    row { verticalModes; heading; lateralModes; altitude }
                    row { verticalSpeed; autopilot; flightDirector(captain: false); course(captain: false) }
                    efis.fcuPlate(boeing: true)
                }
            }
        }
        .padding(Self.margin)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .frame(width: Self.rowWidth)
            .fcuPlate(boeing: true)
    }

    // MARK: - Parts

    private func legend(_ text: String, size: CGFloat = 9) -> FCULegend {
        FCULegend(text, size: size, color: FCUColors.boeingLegend)
    }

    private func window(_ text: String, cells: Int, width: CGFloat) -> some View {
        LCDWindow(width: width, height: 30, boeing: true) {
            SegmentText(text: text, cells: cells, height: 19, color: FCUColors.boeingDigits, ghost: 0.05)
                .frame(width: width, height: 30)
        }
    }

    // MARK: - MCP sections

    /// COURSE: the window shows the route's course; the course itself is
    /// not set here, so the knob is drawn but inert.
    private func course(captain: Bool) -> some View {
        let text = readout.courseDeg.map { String(format: "%03d", $0) } ?? "---"
        return PanelBlock(width: Self.widths[0], height: Self.height) {
            legend("COURSE").position(x: 50, y: 14)
            window(text, cells: 3, width: 66).position(x: 50, y: 42)
            KnurledKnob(diameter: 40, turns: 0, ridges: 28).position(x: 50, y: 112)
        }
    }

    /// F/D: both switches drive the one flight director; the MA light is
    /// the captain's while it is on.
    private func flightDirector(captain: Bool) -> some View {
        PanelBlock(width: Self.widths[1], height: Self.height) {
            legend("F/D").position(x: 28, y: 14)
            BoeingLight(legend: "MA", lit: captain && af.flightDirector).position(x: 28, y: 34)
            BoeingToggle(onLabel: "ON", isOn: af.flightDirector, action: c.toggleFlightDirector)
                .position(x: 28, y: 106)
        }
    }

    private var autothrottle: some View {
        PanelBlock(width: Self.widths[2], height: Self.height) {
            legend("A/T ARM", size: 8.5).position(x: 35, y: 14)
            BoeingLight(legend: "ARM", lit: af.autothrust).position(x: 35, y: 34)
            BoeingToggle(onLabel: "ARM", isOn: af.autothrust, action: c.toggleAutothrust)
                .position(x: 35, y: 106)
        }
    }

    /// N1 has no thrust mode to command here: drawn but inert.
    private var thrustModes: some View {
        PanelBlock(width: Self.widths[3], height: Self.height) {
            BoeingPushbutton(legend: "N1", lit: false, action: nil).position(x: 33, y: 56)
            BoeingPushbutton(legend: "SPEED", lit: af.isSpeedSelected, action: c.selectSpeed).position(x: 33, y: 120)
        }
    }

    /// IAS/MACH: the window is blank while the FMC has the speed (VNAV);
    /// SPD INTV opens it. C/O (IAS / Mach changeover) is inert.
    private var speed: some View {
        let text = readout.selectedSpeed.map(String.init) ?? ""
        return PanelBlock(width: Self.widths[4], height: Self.height) {
            legend("IAS/MACH").position(x: 68, y: 14)
            window(text, cells: 4, width: 90).position(x: 68, y: 42)
            legend("C/O", size: 7.5).position(x: 21, y: 124)
            BoeingPushbutton(legend: "", lit: nil, width: 26, height: 20, action: nil).position(x: 21, y: 145)
            FCUTurnable(onTurn: c.turnSelectingSpeed) { t in
                KnurledKnob(diameter: 46, turns: t, ridges: 32)
            }
            .position(x: 68, y: 112)
            legend("SPD\nINTV", size: 7).position(x: 115, y: 120)
            BoeingPushbutton(legend: "", lit: nil, width: 26, height: 20, action: c.toggleSpeedIntervention)
                .position(x: 115, y: 145)
        }
    }

    /// VNAV hands speed and path to the FMC. LVL CHG is inert: the panel
    /// has no level-change mode of its own.
    private var verticalModes: some View {
        PanelBlock(width: Self.widths[5], height: Self.height) {
            BoeingPushbutton(legend: "VNAV", lit: !af.isSpeedSelected && !af.isVerticalSpeedEngaged, action: c.vnav)
                .position(x: 33, y: 56)
            BoeingPushbutton(legend: "LVL CHG", lit: false, fontSize: 9, action: nil).position(x: 33, y: 120)
        }
    }

    /// HEADING: the knob moves the bug, HDG SEL engages it. The bank-angle
    /// ring is drawn at 25°, inert.
    private var heading: some View {
        let banks = ["10", "15", "20", "25", "30"]
        let angles = fcuArc(banks.count, from: -60, to: 60)
        return PanelBlock(width: Self.widths[6], height: Self.height) {
            legend("HEADING").position(x: 105, y: 14)
            window(String(format: "%03d", readout.boeingHeadingDeg), cells: 3, width: 66).position(x: 105, y: 42)
            ZStack {
                ForEach(banks.indices, id: \.self) { i in
                    let a = angles[i] * .pi / 180
                    legend(banks[i], size: 7.5)
                        .offset(x: CGFloat(sin(a)) * 48, y: -CGFloat(cos(a)) * 48)
                    Capsule().fill(FCUColors.boeingLegend.opacity(0.85))
                        .frame(width: 1.1, height: 3)
                        .offset(y: -40.5)
                        .rotationEffect(.degrees(angles[i]))
                }
                // The bank-angle selector ring, its index at the limit.
                SelectorRing(outer: 76, band: 14, tabAngle: angles[3], tabLength: nil)
                FCUTurnable(onTurn: c.turnHeading) { t in
                    KnurledKnob(diameter: 48, turns: t, ridges: 34)
                }
            }
            .frame(width: 110, height: 100)
            .position(x: 105, y: 115)
            legend("BANK ANGLE", size: 6.5).position(x: 105, y: 163)
            BoeingPushbutton(legend: "HDG SEL", lit: af.isHeadingSelected, fontSize: 9, action: c.selectHeading)
                .position(x: 33, y: 140)
        }
    }

    private var lateralModes: some View {
        PanelBlock(width: Self.widths[7], height: Self.height) {
            BoeingPushbutton(legend: "LNAV", lit: !af.isHeadingSelected, action: c.manageHeading).position(x: 33, y: 36)
            BoeingPushbutton(legend: "VOR LOC", lit: af.localizerArmed, fontSize: 9, action: c.toggleLocalizer)
                .position(x: 33, y: 86)
            BoeingPushbutton(legend: "APP", lit: af.approachArmed, action: c.toggleApproach).position(x: 33, y: 136)
        }
    }

    private var altitude: some View {
        PanelBlock(width: Self.widths[8], height: Self.height) {
            legend("ALTITUDE").position(x: 70, y: 14)
            window(String(Int(readout.selectedAltitudeFt.rounded())), cells: 5, width: 96).position(x: 70, y: 42)
            FCUTurnable(onTurn: c.turnAltitude) { t in
                KnurledKnob(diameter: 50, turns: t, ridges: 34)
            }
            .position(x: 48, y: 114)
            BoeingPushbutton(legend: "ALT HLD", lit: false, fontSize: 9, action: c.altitudeHold).position(x: 108, y: 140)
        }
    }

    /// VERT SPEED: blank until V/S is engaged; the thumbwheel sets it.
    private var verticalSpeed: some View {
        let text = af.selectedVerticalSpeedFpm.map { v in v == 0 ? "0" : String(format: "%+d", Int(v)) } ?? ""
        return PanelBlock(width: Self.widths[9], height: Self.height) {
            legend("VERT SPEED").position(x: 76, y: 14)
            window(text, cells: 5, width: 96).position(x: 76, y: 42)
            BoeingPushbutton(legend: "V/S", lit: af.isVerticalSpeedEngaged, action: c.toggleVerticalSpeed)
                .position(x: 36, y: 140)
            BoeingThumbwheel(onTurn: c.turnVerticalSpeed).position(x: 104, y: 116)
        }
    }

    /// CMD A / CMD B engage the autopilots, the DISENGAGE bar drops both.
    /// CWS has no meaning without a control column: drawn but inert.
    private var autopilot: some View {
        PanelBlock(width: Self.widths[10], height: Self.height) {
            legend("A/P ENGAGE", size: 8).position(x: 70, y: 12)
            BoeingPushbutton(legend: "CMD A", lit: af.autopilot1, action: c.toggleAutopilot1).position(x: 38, y: 44)
            BoeingPushbutton(legend: "CMD B", lit: af.autopilot2, action: c.toggleAutopilot2).position(x: 102, y: 44)
            BoeingPushbutton(legend: "CWS A", lit: false, action: nil).position(x: 38, y: 91)
            BoeingPushbutton(legend: "CWS B", lit: false, action: nil).position(x: 102, y: 91)
            legend("A/P DISENGAGE", size: 7).position(x: 70, y: 124)
            DisengageBar(width: 116, action: c.disengageAutopilots).position(x: 70, y: 146)
        }
    }

    // MARK: - EFIS control panel (captain)

    /// MINS, BARO (push its centre for STD), the ND mode and range
    /// selectors and the map buttons. TERR is wired; the ND has its own
    /// range keys and shows its map, so the rest are drawn but inert.
    private var efis: some View {
        let keys = ["WXR", "STA", "WPT", "ARPT", "DATA", "POS", "TERR"]
        return PanelBlock(width: Self.efisWidth, height: Self.height) {
            legend("MINS", size: 8).position(x: 45, y: 12)
            legend("RADIO", size: 6.5).position(x: 16, y: 30)
            legend("BARO", size: 6.5).position(x: 74, y: 30)
            ZStack {
                // The RADIO / BARO selector round the MINS knob.
                SelectorRing(outer: 42, band: 5, tabAngle: 53, tabLength: 8)
                PointerSelector(labels: [], angles: [], selected: nil, diameter: 32, labelRadius: 20,
                                legend: FCUColors.boeingLegend, center: "RST")
            }
            .position(x: 45, y: 52)

            legend("FPV", size: 7).position(x: 120, y: 28)
            BoeingPushbutton(legend: "", lit: nil, width: 26, height: 20, action: nil).position(x: 120, y: 48)
            legend("MTRS", size: 7).position(x: 168, y: 28)
            BoeingPushbutton(legend: "", lit: nil, width: 26, height: 20, action: nil).position(x: 168, y: 48)

            legend("BARO", size: 8).position(x: 245, y: 12)
            legend("IN", size: 6.5).position(x: 218, y: 30)
            legend("HPA", size: 6.5).position(x: 274, y: 30)
            FCUTurnable(onTurn: { _ in }, onPush: c.toggleStandardBaro) { t in
                ZStack {
                    // The IN / HPA selector round the BARO knob.
                    SelectorRing(outer: 44, band: 5, tabAngle: 53, tabLength: 8)
                    KnurledKnob(diameter: 34, turns: t, ridges: 26)
                    Text("STD")
                        .font(.system(size: 6.5, weight: .heavy))
                        .foregroundStyle(readout.isStandardBaro ? FCUColors.lightGreen : FCUColors.boeingLegend)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color(white: 0.12)))
                }
            }
            .position(x: 245, y: 52)

            legend("MODE", size: 7).position(x: 95, y: 66)
            PointerSelector(labels: ["APP", "VOR", "MAP", "PLN"], angles: fcuArc(4, from: -80, to: 80), selected: 2,
                            diameter: 30, labelRadius: 25, legend: FCUColors.boeingLegend, labelSize: 6.5, center: "CTR")
                .position(x: 95, y: 104)
            legend("RANGE", size: 7).position(x: 195, y: 66)
            PointerSelector(labels: ["5", "10", "20", "40", "80", "160", "320", "640"],
                            angles: fcuArc(8, from: -125, to: 125), selected: nil,
                            diameter: 30, labelRadius: 25, legend: FCUColors.boeingLegend, labelSize: 6.5, center: "TFC")
                .position(x: 195, y: 104)

            ForEach(keys.indices, id: \.self) { i in
                efisKey(keys[i]).position(x: 31 + CGFloat(i) * 38, y: 150)
            }
        }
    }

    private func efisKey(_ key: String) -> some View {
        let isTerrain = key == "TERR"
        let action: (() -> Void)? = isTerrain ? { c.toggleTerrain() } : nil
        return BoeingPushbutton(legend: key, lit: isTerrain ? af.terrainOnND : nil, width: 36, height: 30,
                                fontSize: 7.5, action: action)
    }
}
