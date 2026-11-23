import Foundation

/// What the crew set on the glareshield: the Airbus FCU and EFIS control
/// panel, or the Boeing MCP. Nothing here moves the vehicle — a phone flies
/// nothing — but the displays follow it as they would the real panel: the
/// target bugs, the flight director's commands, the FMA's modes and the
/// approach scales.
///
/// Each target has its value (what the window shows, what the Boeing bugs
/// point at) and whether it is engaged: on the 737 the HDG knob moves the
/// bug, HDG SEL engages it; on the A320 pulling the knob engages it.
struct AutoFlight: Equatable {
    var speedTargetKts: Double?
    /// Selected speed (Airbus pulled, Boeing MCP SPD); off is managed / VNAV.
    var isSpeedSelected = false

    var headingTargetDeg: Double?
    /// Selected heading (HDG, HDG SEL); off flies the route (NAV, LNAV).
    var isHeadingSelected = false

    var verticalSpeedTargetFpm: Double = 0
    var isVerticalSpeedEngaged = false

    var flightDirector = true
    var autopilot1 = false
    var autopilot2 = false
    var autothrust = true
    /// LOC (Airbus) / VOR LOC (Boeing): localiser armed.
    var localizerArmed = false
    /// APPR / APP: localiser and glideslope armed.
    var approachArmed = false
    /// Airbus EFIS panel LS: show the approach scales whatever the phase.
    var landingSystem = false
    /// Terrain on the ND: the Airbus EFIS panel's TERR ON ND pushbutton,
    /// the Boeing EFIS control panel's TERR switch.
    var terrainOnND = true

    /// The ALT knob's step, the Airbus 100 / 1000 selector.
    var altitudeStepFt: Double = 1_000

    var selectedSpeedKts: Double? { isSpeedSelected ? speedTargetKts : nil }
    var selectedHeadingDeg: Double? { isHeadingSelected ? headingTargetDeg : nil }
    var selectedVerticalSpeedFpm: Double? { isVerticalSpeedEngaged ? verticalSpeedTargetFpm : nil }
    var isLocalizerArmed: Bool { localizerArmed || approachArmed }

    static let speedRange = 0.0...999.0
    static let altitudeRange = 0.0...49_000.0
    static let verticalSpeedRange = -6_000.0...6_000.0
}
