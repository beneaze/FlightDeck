import SwiftUI
import UIKit

/// The glareshield panel, brought up with a left swipe: the A320's FCU
/// with the captain's EFIS control panel, or the 737's MCP with the
/// captain's EFIS control panel. Our own drawing after the arrangement of
/// the real units: LCD windows over knurled knobs, pushbuttons with light
/// bars that come on when the function is engaged.
///
/// Knobs: drag up or down to turn. On the A320 a tap pushes (hands the
/// target to the FMS: dashes and the managed dot) and a long press pulls
/// (selects it); on the 737 the knobs only move the bugs and the mode
/// buttons engage them. The 737's V/S is a thumbwheel, dragged up or down.
///
/// The panels are wide, a phone is narrow: in landscape each is drawn in
/// one row as the real unit is, in portrait in its sections one above the
/// other, reading as the panel does left to right. Either way the panel is
/// laid out at a fixed size and scaled as a whole to the screen.
struct FCUView: View {
    @ObservedObject var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    var close: () -> Void

    private var isBoeing: Bool { flightData.displayStyle == .boeing }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: landscape ? 4 : 8) {
                    HStack {
                        Text(isBoeing ? "737 MCP" : "A320 FCU")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                        Spacer()
                        closeButton
                    }
                    panel(landscape: landscape)
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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

    @ViewBuilder private func panel(landscape: Bool) -> some View {
        let controls = FCUControls(flightData: flightData)
        if isBoeing {
            FittedPanel(size: B737Panel.size(landscape: landscape)) {
                B737Panel(readout: readout, landscape: landscape, controls: controls).equatable()
            }
        } else {
            FittedPanel(size: A320Panel.size(landscape: landscape)) {
                A320Panel(readout: readout, landscape: landscape, controls: controls).equatable()
            }
        }
    }

    private var hint: String {
        isBoeing
            ? "Knobs and thumbwheel: drag up or down · buttons engage the modes"
            : "Knobs: drag up or down to turn · tap to push · hold to pull"
    }

    /// What the panel shows, and nothing more, so it is redrawn when one of
    /// its windows or lights changes rather than with every sensor update.
    private var readout: FCUReadout {
        let course = Guidance(flightData: flightData, routePlanner: routePlanner).bearing
        return FCUReadout(
            autoFlight: flightData.autoFlight,
            selectedAltitudeFt: flightData.selectedAltitudeFt,
            speedUnit: flightData.speedUnit,
            isStandardBaro: flightData.isStandardBaro,
            boeingHeadingDeg: Int(normalizedHeading((flightData.autoFlight.headingTargetDeg
                                                      ?? flightData.headingDeg).rounded())) % 360,
            courseDeg: course.map { Int(normalizedHeading($0.rounded())) % 360 })
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
}

/// The values the panel's windows and lights show.
struct FCUReadout: Equatable {
    var autoFlight: AutoFlight
    var selectedAltitudeFt: Double
    var speedUnit: SpeedUnit
    var isStandardBaro: Bool
    /// The 737 HEADING window: the bug once set, else the present heading.
    var boeingHeadingDeg: Int
    /// The 737 COURSE windows: the route's course, when there is one.
    var courseDeg: Int?

    var af: AutoFlight { autoFlight }

    /// Selected speed in the display unit.
    var selectedSpeed: Int? {
        af.selectedSpeedKts.map { Int(($0 * speedUnit.perKnot).rounded()) }
    }
}

/// What the knobs, buttons and switches do: they set `autoFlight` (and
/// the selected altitude and baro reference) on the flight data model,
/// which the PFDs and FMA follow. Present values are read when a control
/// is used, so a knob starts from where the aircraft is.
@MainActor
struct FCUControls {
    let flightData: FlightDataModel

    private var af: AutoFlight { flightData.autoFlight }
    private var isBoeing: Bool { flightData.displayStyle == .boeing }

    func update(_ change: (inout AutoFlight) -> Void) {
        var copy = flightData.autoFlight
        change(&copy)
        flightData.autoFlight = copy
    }

    // MARK: Present values the knobs start from

    var currentSpeedKts: Double { flightData.groundSpeedKts.rounded() }
    var currentHeading: Double { flightData.headingDeg.rounded() }
    var currentVerticalSpeed: Double { (flightData.verticalSpeedFpm / 100).rounded() * 100 }

    // MARK: Turning

    func turnSpeed(_ steps: Int) {
        let unit = flightData.speedUnit.perKnot
        update {
            let start = ($0.speedTargetKts ?? currentSpeedKts) * unit
            $0.speedTargetKts = ((start.rounded() + Double(steps)) / unit).clamped(to: AutoFlight.speedRange)
        }
    }

    func turnHeading(_ steps: Int) {
        update {
            $0.headingTargetDeg = normalizedHeading(($0.headingTargetDeg ?? currentHeading).rounded() + Double(steps))
        }
    }

    func turnAltitude(_ steps: Int) {
        let step = isBoeing ? 100 : af.altitudeStepFt
        let next = ((flightData.selectedAltitudeFt / step).rounded() + Double(steps)) * step
        flightData.selectedAltitudeFt = next.clamped(to: AutoFlight.altitudeRange)
    }

    func turnVerticalSpeed(_ steps: Int) {
        update {
            let start = $0.isVerticalSpeedEngaged ? $0.verticalSpeedTargetFpm : currentVerticalSpeed
            $0.verticalSpeedTargetFpm = (start + Double(steps) * 100).clamped(to: AutoFlight.verticalSpeedRange)
            $0.isVerticalSpeedEngaged = true
        }
    }

    // MARK: Speed

    /// Turning the speed knob selects the speed, starting from the present one.
    func turnSelectingSpeed(_ steps: Int) {
        if !af.isSpeedSelected { update { $0.speedTargetKts = currentSpeedKts; $0.isSpeedSelected = true } }
        turnSpeed(steps)
    }

    func selectSpeed() {
        update { $0.speedTargetKts = $0.speedTargetKts ?? currentSpeedKts; $0.isSpeedSelected = true }
    }

    func manageSpeed() { update { $0.isSpeedSelected = false } }

    /// A320 SPD knob turned. Selected: the target moves. Managed: the
    /// window shows a preset — starting from the present speed — which a
    /// pull then selects; the FMS keeps the speed meanwhile.
    func turnAirbusSpeed(_ steps: Int, presetShown: Bool) {
        if !af.isSpeedSelected && !presetShown { update { $0.speedTargetKts = currentSpeedKts } }
        turnSpeed(steps)
    }

    /// A320 SPD knob pulled: selected speed — the preset if one is shown,
    /// else the present speed.
    func pullAirbusSpeed(presetShown: Bool) {
        update {
            guard !$0.isSpeedSelected else { return }
            if !presetShown || $0.speedTargetKts == nil { $0.speedTargetKts = currentSpeedKts }
            $0.isSpeedSelected = true
        }
    }

    /// 737 SPD INTV: opens or closes the IAS/MACH window.
    func toggleSpeedIntervention() {
        update {
            $0.isSpeedSelected.toggle()
            if $0.speedTargetKts == nil { $0.speedTargetKts = currentSpeedKts }
        }
    }

    // MARK: Heading

    func selectHeading() {
        update { $0.headingTargetDeg = $0.headingTargetDeg ?? currentHeading; $0.isHeadingSelected = true }
    }

    func manageHeading() { update { $0.isHeadingSelected = false } }

    /// A320 HDG knob turned: as the SPD knob, a preset while managed.
    func turnAirbusHeading(_ steps: Int, presetShown: Bool) {
        if !af.isHeadingSelected && !presetShown { update { $0.headingTargetDeg = currentHeading } }
        turnHeading(steps)
    }

    func pullAirbusHeading(presetShown: Bool) {
        update {
            guard !$0.isHeadingSelected else { return }
            if !presetShown || $0.headingTargetDeg == nil { $0.headingTargetDeg = currentHeading }
            $0.isHeadingSelected = true
        }
    }

    // MARK: Vertical

    /// Pushing or pulling the Airbus ALT knob leaves V/S for the managed
    /// or open climb or descent.
    func leaveVerticalSpeed() { update { $0.isVerticalSpeedEngaged = false } }

    /// Airbus V/S knob pushed: level off, V/S zero.
    func levelOff() { update { $0.verticalSpeedTargetFpm = 0; $0.isVerticalSpeedEngaged = true } }

    /// V/S pulled (Airbus) or V/S pressed (737): fly the present vertical speed.
    func engageVerticalSpeed() {
        update { $0.verticalSpeedTargetFpm = currentVerticalSpeed; $0.isVerticalSpeedEngaged = true }
    }

    func toggleVerticalSpeed() {
        if af.isVerticalSpeedEngaged { leaveVerticalSpeed() } else { engageVerticalSpeed() }
    }

    func setAltitudeStep(_ feet: Double) { update { $0.altitudeStepFt = feet } }

    /// 737 ALT HLD: hold the present altitude.
    func altitudeHold() {
        flightData.selectedAltitudeFt = (flightData.altitudeFt / 100).rounded() * 100
        leaveVerticalSpeed()
    }

    /// 737 VNAV: speed and path from the FMC.
    func vnav() { update { $0.isSpeedSelected = false; $0.isVerticalSpeedEngaged = false } }

    // MARK: Approach

    func toggleLocalizer() {
        update { $0.localizerArmed.toggle(); if $0.localizerArmed { $0.approachArmed = false } }
    }

    func toggleApproach() {
        update { $0.approachArmed.toggle(); if $0.approachArmed { $0.localizerArmed = false } }
    }

    // MARK: Engagement and EFIS

    func toggleFlightDirector() { update { $0.flightDirector.toggle() } }
    func toggleAutopilot1() { update { $0.autopilot1.toggle() } }
    func toggleAutopilot2() { update { $0.autopilot2.toggle() } }
    func disengageAutopilots() { update { $0.autopilot1 = false; $0.autopilot2 = false } }
    func toggleAutothrust() { update { $0.autothrust.toggle() } }
    func toggleLandingSystem() { update { $0.landingSystem.toggle() } }
    func toggleTerrain() { update { $0.terrainOnND.toggle() } }

    /// Baro reference: STD or QNH.
    func setStandardBaro(_ standard: Bool) { flightData.isStandardBaro = standard }
    func toggleStandardBaro() { flightData.isStandardBaro.toggle() }
}
