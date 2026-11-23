import SwiftUI
import UIKit

/// The glareshield panel, brought up with a left swipe: the A320's FCU with
/// the FD and LS pushbuttons of its EFIS control panel, or the 737's MCP.
/// Our own drawing, after the real panels' arrangement: LCD windows over
/// knobs, pushbuttons with a light bar that comes on when engaged.
///
/// Knobs: drag up or down to turn; tap to push, long-press to pull. On the
/// A320 pushing hands the target to the FMS (managed, dashes and a dot) and
/// pulling selects it; on the 737 the knobs only move the bugs and the
/// mode buttons engage them.
///
/// The panel is wide, a phone is narrow: in portrait it is shown in its
/// sections one above the other, in landscape in one row.
struct FCUView: View {
    @ObservedObject var flightData: FlightDataModel
    var close: () -> Void

    private var isBoeing: Bool { flightData.displayStyle == .boeing }
    private var af: AutoFlight { flightData.autoFlight }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 10) {
                    HStack {
                        Spacer()
                        closeButton
                    }
                    Spacer(minLength: 0)
                    let sections = isBoeing ? boeingSections : airbusSections
                    if landscape {
                        HStack(alignment: .top, spacing: 4) { ForEach(sections.indices, id: \.self) { sections[$0] } }
                            .scaleEffect(min(1, geo.size.width / 980))
                    } else {
                        VStack(spacing: 10) {
                            ForEach(sections.indices, id: \.self) { sections[$0].frame(maxWidth: .infinity) }
                        }
                        .frame(maxWidth: 380)
                        .scaleEffect(min(1, (geo.size.width - 16) / 380))
                    }
                    Spacer(minLength: 0)
                    Text("Knobs: drag up or down to turn · tap to push · hold to pull")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .simultaneousGesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                // A right swipe puts the panel away, mirroring how it came.
                if value.translation.width > 80,
                   abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                    close()
                }
            })
    }

    private var closeButton: some View {
        Button(action: close) {
            Label("DISPLAYS", systemImage: "chevron.right")
                .labelStyle(TrailingIconLabelStyle())
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
    }

    private func update(_ change: (inout AutoFlight) -> Void) {
        var copy = flightData.autoFlight
        change(&copy)
        flightData.autoFlight = copy
    }

    // MARK: Present values the knobs start from

    private var currentSpeedKts: Double { flightData.groundSpeedKts.rounded() }
    private var currentHeading: Double { flightData.headingDeg.rounded() }
    private var currentVerticalSpeed: Double { (flightData.verticalSpeedFpm / 100).rounded() * 100 }

    private func turnSpeed(_ steps: Int) {
        let unit = flightData.speedUnit.perKnot
        update {
            let start = ($0.speedTargetKts ?? currentSpeedKts) * unit
            $0.speedTargetKts = ((start.rounded() + Double(steps)) / unit).clamped(to: AutoFlight.speedRange)
        }
    }

    private func turnHeading(_ steps: Int) {
        update {
            $0.headingTargetDeg = normalizedHeading(($0.headingTargetDeg ?? currentHeading).rounded() + Double(steps))
        }
    }

    private func turnAltitude(_ steps: Int) {
        let step = isBoeing ? 100 : af.altitudeStepFt
        let next = ((flightData.selectedAltitudeFt / step).rounded() + Double(steps)) * step
        flightData.selectedAltitudeFt = next.clamped(to: AutoFlight.altitudeRange)
    }

    private func turnVerticalSpeed(_ steps: Int) {
        update {
            let start = $0.isVerticalSpeedEngaged ? $0.verticalSpeedTargetFpm : currentVerticalSpeed
            $0.verticalSpeedTargetFpm = (start + Double(steps) * 100).clamped(to: AutoFlight.verticalSpeedRange)
            $0.isVerticalSpeedEngaged = true
        }
    }

    // MARK: - A320 FCU

    private var airbusSections: [AnyView] {
        let unitLabel: String = {
            switch flightData.speedUnit {
            case .knots: return "SPD"
            case .kmh: return "SPD KMH"
            case .mph: return "SPD MPH"
            }
        }()
        let speedText = af.selectedSpeedKts.map { String(format: "%03d", Int(($0 * flightData.speedUnit.perKnot).rounded())) }
        let headingText = af.selectedHeadingDeg.map { String(format: "%03d", Int($0.rounded()) % 360) }
        let vsText = af.selectedVerticalSpeedFpm.map { v -> String in
            v == 0 ? "00oo" : String(format: "%@%02doo", v < 0 ? "-" : "+", Int(abs(v) / 100))
        }

        let efis = FCUSection(style: .airbus, title: "EFIS") {
            HStack(spacing: 18) {
                FCUPushbutton(style: .airbus, label: "FD", lit: af.flightDirector) { update { $0.flightDirector.toggle() } }
                FCUPushbutton(style: .airbus, label: "LS", lit: af.landingSystem) { update { $0.landingSystem.toggle() } }
            }
        }

        let left = FCUSection(style: .airbus, title: nil) {
            HStack(alignment: .top, spacing: 10) {
                FCUChannel(style: .airbus, label: unitLabel, text: speedText ?? "---", managed: speedText == nil,
                           onTurn: { steps in
                               if !af.isSpeedSelected { update { $0.speedTargetKts = currentSpeedKts; $0.isSpeedSelected = true } }
                               turnSpeed(steps)
                           },
                           onPush: { update { $0.isSpeedSelected = false } },
                           onPull: { update { $0.speedTargetKts = $0.speedTargetKts ?? currentSpeedKts; $0.isSpeedSelected = true } })
                VStack {
                    Spacer().frame(height: 52)
                    FCUPushbutton(style: .airbus, label: "LOC", lit: af.localizerArmed) {
                        update { $0.localizerArmed.toggle(); if $0.localizerArmed { $0.approachArmed = false } }
                    }
                }
                FCUChannel(style: .airbus, label: "HDG", text: headingText ?? "---", managed: headingText == nil,
                           onTurn: { steps in
                               if !af.isHeadingSelected { update { $0.headingTargetDeg = currentHeading; $0.isHeadingSelected = true } }
                               turnHeading(steps)
                           },
                           onPush: { update { $0.isHeadingSelected = false } },
                           onPull: { update { $0.headingTargetDeg = $0.headingTargetDeg ?? currentHeading; $0.isHeadingSelected = true } })
            }
        }

        let center = FCUSection(style: .airbus, title: nil) {
            HStack(spacing: 10) {
                FCUPushbutton(style: .airbus, label: "AP1", lit: af.autopilot1) { update { $0.autopilot1.toggle() } }
                FCUPushbutton(style: .airbus, label: "AP2", lit: af.autopilot2) { update { $0.autopilot2.toggle() } }
                FCUPushbutton(style: .airbus, label: "A/THR", lit: af.autothrust) { update { $0.autothrust.toggle() } }
            }
        }

        let right = FCUSection(style: .airbus, title: nil) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 6) {
                    FCUChannel(style: .airbus, label: "ALT",
                               text: String(format: "%05d", Int(flightData.selectedAltitudeFt.rounded())),
                               managed: !af.isVerticalSpeedEngaged,
                               onTurn: turnAltitude,
                               onPush: { update { $0.isVerticalSpeedEngaged = false } },
                               onPull: { update { $0.isVerticalSpeedEngaged = false } })
                    FCUSelector(options: ["100", "1000"], selected: af.altitudeStepFt == 100 ? 0 : 1) { index in
                        update { $0.altitudeStepFt = index == 0 ? 100 : 1_000 }
                    }
                }
                FCUChannel(style: .airbus, label: "V/S", text: vsText ?? "-----", managed: false,
                           onTurn: turnVerticalSpeed,
                           onPush: { update { $0.verticalSpeedTargetFpm = 0; $0.isVerticalSpeedEngaged = true } },
                           onPull: { update { $0.verticalSpeedTargetFpm = currentVerticalSpeed; $0.isVerticalSpeedEngaged = true } })
                VStack {
                    Spacer().frame(height: 52)
                    FCUPushbutton(style: .airbus, label: "APPR", lit: af.approachArmed) {
                        update { $0.approachArmed.toggle(); if $0.approachArmed { $0.localizerArmed = false } }
                    }
                }
            }
        }

        return [AnyView(efis), AnyView(left), AnyView(center), AnyView(right)]
    }

    // MARK: - 737 MCP

    private var boeingSections: [AnyView] {
        let speedText = af.selectedSpeedKts.map { String(Int(($0 * flightData.speedUnit.perKnot).rounded())) }
        let headingText = String(format: "%03d", Int((af.headingTargetDeg ?? currentHeading).rounded()) % 360)
        let vsText = af.selectedVerticalSpeedFpm.map { String(format: "%+d", Int($0)) }

        let speed = FCUSection(style: .boeing, title: nil) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 10) {
                    FCUToggleSwitch(label: "F/D", isOn: af.flightDirector) { update { $0.flightDirector.toggle() } }
                    FCUToggleSwitch(label: "A/T ARM", isOn: af.autothrust) { update { $0.autothrust.toggle() } }
                }
                FCUChannel(style: .boeing, label: "IAS/MACH", text: speedText ?? "", managed: false,
                           onTurn: { steps in
                               if !af.isSpeedSelected { update { $0.speedTargetKts = currentSpeedKts; $0.isSpeedSelected = true } }
                               turnSpeed(steps)
                           },
                           onPush: { update { $0.isSpeedSelected.toggle(); if $0.speedTargetKts == nil { $0.speedTargetKts = currentSpeedKts } } },
                           onPull: { update { $0.isSpeedSelected = true; $0.speedTargetKts = $0.speedTargetKts ?? currentSpeedKts } })
                VStack(spacing: 8) {
                    FCUPushbutton(style: .boeing, label: "VNAV", lit: !af.isSpeedSelected && !af.isVerticalSpeedEngaged) {
                        update { $0.isSpeedSelected = false; $0.isVerticalSpeedEngaged = false }
                    }
                    FCUPushbutton(style: .boeing, label: "SPEED", lit: af.isSpeedSelected) {
                        update { $0.isSpeedSelected = true; $0.speedTargetKts = $0.speedTargetKts ?? currentSpeedKts }
                    }
                }
            }
        }

        let lateral = FCUSection(style: .boeing, title: nil) {
            HStack(alignment: .top, spacing: 12) {
                FCUChannel(style: .boeing, label: "HEADING", text: headingText, managed: false,
                           onTurn: turnHeading,
                           onPush: { update { $0.headingTargetDeg = $0.headingTargetDeg ?? currentHeading; $0.isHeadingSelected = true } },
                           onPull: { update { $0.headingTargetDeg = $0.headingTargetDeg ?? currentHeading; $0.isHeadingSelected = true } })
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        FCUPushbutton(style: .boeing, label: "HDG SEL", lit: af.isHeadingSelected) {
                            update { $0.headingTargetDeg = $0.headingTargetDeg ?? currentHeading; $0.isHeadingSelected = true }
                        }
                        FCUPushbutton(style: .boeing, label: "LNAV", lit: !af.isHeadingSelected) {
                            update { $0.isHeadingSelected = false }
                        }
                    }
                    HStack(spacing: 8) {
                        FCUPushbutton(style: .boeing, label: "VOR LOC", lit: af.localizerArmed) {
                            update { $0.localizerArmed.toggle(); if $0.localizerArmed { $0.approachArmed = false } }
                        }
                        FCUPushbutton(style: .boeing, label: "APP", lit: af.approachArmed) {
                            update { $0.approachArmed.toggle(); if $0.approachArmed { $0.localizerArmed = false } }
                        }
                    }
                }
            }
        }

        let vertical = FCUSection(style: .boeing, title: nil) {
            HStack(alignment: .top, spacing: 12) {
                FCUChannel(style: .boeing, label: "ALTITUDE",
                           text: String(Int(flightData.selectedAltitudeFt.rounded())), managed: false,
                           onTurn: turnAltitude,
                           onPush: { update { $0.isVerticalSpeedEngaged = false } },
                           onPull: { update { $0.isVerticalSpeedEngaged = false } })
                VStack(spacing: 8) {
                    FCUPushbutton(style: .boeing, label: "ALT HLD", lit: false) {
                        flightData.selectedAltitudeFt = (flightData.altitudeFt / 100).rounded() * 100
                        update { $0.isVerticalSpeedEngaged = false }
                    }
                    FCUPushbutton(style: .boeing, label: "V/S", lit: af.isVerticalSpeedEngaged) {
                        update {
                            if $0.isVerticalSpeedEngaged { $0.isVerticalSpeedEngaged = false }
                            else { $0.verticalSpeedTargetFpm = currentVerticalSpeed; $0.isVerticalSpeedEngaged = true }
                        }
                    }
                }
                FCUChannel(style: .boeing, label: "VERT SPEED", text: vsText ?? "", managed: false,
                           onTurn: turnVerticalSpeed,
                           onPush: { update { $0.isVerticalSpeedEngaged = false } },
                           onPull: { update { $0.verticalSpeedTargetFpm = currentVerticalSpeed; $0.isVerticalSpeedEngaged = true } })
            }
        }

        let command = FCUSection(style: .boeing, title: "A/P ENGAGE") {
            HStack(spacing: 10) {
                FCUPushbutton(style: .boeing, label: "CMD A", lit: af.autopilot1) { update { $0.autopilot1.toggle() } }
                FCUPushbutton(style: .boeing, label: "CMD B", lit: af.autopilot2) { update { $0.autopilot2.toggle() } }
            }
        }

        return [AnyView(speed), AnyView(lateral), AnyView(vertical), AnyView(command)]
    }
}

// MARK: - Parts

/// Which panel a part belongs to: colours and type follow it.
enum FCUPanelStyle {
    case airbus, boeing

    var panel: Color {
        self == .airbus ? Color(red: 0.33, green: 0.37, blue: 0.41) : Color(red: 0.36, green: 0.37, blue: 0.38)
    }
    var legend: Color { self == .airbus ? Color(red: 0.98, green: 0.92, blue: 0.80) : .white }
    /// LCD digits: the A320 FCU's orange, the 737 MCP's white.
    var digits: Color {
        self == .airbus ? Color(red: 1.0, green: 0.62, blue: 0.18) : Color(red: 0.95, green: 0.95, blue: 0.9)
    }
}

/// A section of panel with its edge and, optionally, a legend on top.
struct FCUSection<Content: View>: View {
    let style: FCUPanelStyle
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(style.legend.opacity(0.8))
            }
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [style.panel.opacity(0.92), style.panel], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .topLeading) { screw.offset(x: 4, y: 4) }
        .overlay(alignment: .bottomTrailing) { screw.offset(x: -4, y: -4) }
    }

    private var screw: some View {
        Circle().fill(Color(white: 0.55)).frame(width: 5, height: 5)
            .overlay(Rectangle().fill(Color(white: 0.3)).frame(width: 4, height: 1).rotationEffect(.degrees(35)))
    }
}

/// One channel: legend, LCD window and the knob below it.
struct FCUChannel: View {
    let style: FCUPanelStyle
    let label: String
    let text: String
    /// Airbus managed mode: the window shows dashes and the dot beside it.
    let managed: Bool
    var onTurn: (Int) -> Void
    var onPush: () -> Void
    var onPull: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(style.legend)
            HStack(spacing: 3) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(style.digits)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if style == .airbus {
                    Circle().fill(managed ? style.digits : .clear).frame(width: 6, height: 6)
                }
            }
            .frame(width: 92, height: 34)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.06, green: 0.05, blue: 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.8), lineWidth: 2))
            FCUKnob(onTurn: onTurn, onPush: onPush, onPull: onPull)
        }
    }
}

/// A knurled rotary knob with a white index line. Drag up or down to turn
/// (about one step per 9 points); tap to push, hold to pull.
struct FCUKnob: View {
    var onTurn: (Int) -> Void
    var onPush: () -> Void
    var onPull: () -> Void

    @State private var angle = 0.0
    @State private var applied = 0
    private let haptics = UISelectionFeedbackGenerator()

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.32), Color(white: 0.12)], center: .topLeading,
                                     startRadius: 2, endRadius: 46))
            // Knurling.
            ForEach(0..<24, id: \.self) { i in
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 5)
                    .offset(y: -25).rotationEffect(.degrees(Double(i) * 15))
            }
            Circle().fill(Color(white: 0.2)).padding(9)
            Capsule().fill(.white).frame(width: 2.5, height: 12).offset(y: -15)
        }
        .frame(width: 58, height: 58)
        .rotationEffect(.degrees(angle))
        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let steps = Int((-value.translation.height / 9).rounded(.towardZero))
                    let delta = steps - applied
                    guard delta != 0 else { return }
                    applied = steps
                    angle += Double(delta) * 12
                    haptics.selectionChanged()
                    onTurn(delta)
                }
                .onEnded { _ in applied = 0 }
        )
        .onTapGesture { haptics.selectionChanged(); onPush() }
        .onLongPressGesture(minimumDuration: 0.45) { haptics.selectionChanged(); onPull() }
    }
}

/// A square pushbutton with its legend and a light bar that comes on when
/// the function is engaged: green on the A320, the 737's bar above the
/// legend.
struct FCUPushbutton: View {
    let style: FCUPanelStyle
    let label: String
    let lit: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if style == .boeing { bar }
                Text(label)
                    .font(.system(size: style == .airbus ? 11 : 9.5, weight: .bold))
                    .foregroundStyle(style.legend)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if style == .airbus { bar }
            }
            .frame(width: style == .airbus ? 50 : 58, height: style == .airbus ? 44 : 38)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
        }
        .buttonStyle(FCUPressStyle())
    }

    private var bar: some View {
        HStack(spacing: 3) {
            ForEach(0..<(style == .airbus ? 3 : 1), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? Color(red: 0.3, green: 1.0, blue: 0.4) : Color.white.opacity(0.12))
                    .frame(width: style == .airbus ? 9 : 30, height: 3)
            }
        }
        .shadow(color: lit ? .green.opacity(0.8) : .clear, radius: 3)
    }
}

/// The 737's toggle switches (F/D, A/T ARM): a lever up for on.
struct FCUToggleSwitch: View {
    let label: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                ZStack {
                    Circle().fill(Color(white: 0.15)).frame(width: 20, height: 20)
                    Capsule().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.5)],
                                                  startPoint: .top, endPoint: .bottom))
                        .frame(width: 7, height: 18)
                        .offset(y: isOn ? -7 : 7)
                }
                .frame(height: 34)
                Text(isOn ? "ON" : "OFF").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 52)
        }
        .buttonStyle(.plain)
    }
}

/// The Airbus 100 / 1000 ft ALT step selector.
struct FCUSelector: View {
    let options: [String]
    let selected: Int
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                Button { onSelect(i) } label: {
                    Text(options[i])
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(i == selected ? .black : Color(red: 0.98, green: 0.92, blue: 0.80))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(i == selected ? Color(red: 0.98, green: 0.92, blue: 0.80) : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
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

/// Pushbuttons sink a little while held.
struct FCUPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}
