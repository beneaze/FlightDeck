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

    /// The Airbus EFIS panel's ND mode selector.
    var ndMode: NDMode = .arc
    /// The ND range, an index into the profile's `ndRangesNm`: set by the
    /// EFIS panel's range selector and by the ND's own range keys.
    var ndRangeIndex = AircraftProfile.a320.ndDefaultRangeIndex
    /// The map option pushbutton that is lit — CSTR, WPT, VOR.D, NDB or
    /// ARPT, one at a time — or none.
    var ndOption: NDOption? = .airports

    var selectedSpeedKts: Double? { isSpeedSelected ? speedTargetKts : nil }
    var selectedHeadingDeg: Double? { isHeadingSelected ? headingTargetDeg : nil }
    var selectedVerticalSpeedFpm: Double? { isVerticalSpeedEngaged ? verticalSpeedTargetFpm : nil }
    var isLocalizerArmed: Bool { localizerArmed || approachArmed }

    static let speedRange = 0.0...999.0
    static let altitudeRange = 0.0...49_000.0
    static let verticalSpeedRange = -6_000.0...6_000.0
}

/// The A320 ND modes, in the order of the EFIS panel's mode selector.
enum NDMode: Int, CaseIterable {
    case roseLS, roseVOR, roseNAV, arc, plan

    /// The full compass rose round the aircraft.
    var isRose: Bool { self == .roseLS || self == .roseVOR || self == .roseNAV }
    /// The flight plan and the map options: NAV, ARC and PLAN. ROSE LS and
    /// ROSE VOR show the radio course instead.
    var showsMap: Bool { self == .roseNAV || self == .arc || self == .plan }
    /// Terrain shows in the heading-up map modes.
    var showsTerrain: Bool { self == .roseNAV || self == .arc }
}

/// The EFIS panel's map option pushbuttons, left to right.
enum NDOption: CaseIterable {
    case constraints, waypoints, vorDme, ndb, airports

    var legend: String {
        switch self {
        case .constraints: return "CSTR"
        case .waypoints: return "WPT"
        case .vorDme: return "VOR.D"
        case .ndb: return "NDB"
        case .airports: return "ARPT"
        }
    }
}

/// The EFIS panel's baro reference. A phone flies on GPS altitude, so the
/// setting changes what the PFD and the EFIS window show, not the altitude.
struct BaroSetting: Equatable {
    /// Pulled: STD. Pushed: QNH.
    var isStandard = true
    /// The QNH, hPa — kept in hPa whichever unit the ring shows.
    var hpa = Self.standardHpa
    /// The knob's outer ring at inHg rather than hPa.
    var inHg = false
    /// Turned while STD: the QNH a push will set, shown under STD.
    var preselectHpa: Double?

    static let standardHpa = 1013.25
    static let hpaPerInHg = 33.8639
    /// The window's limits, 745 to 1100 hPa (22.00 to 32.48 inHg).
    static let hpaRange = 745.0...1_100.0

    /// "1013" or "29.92".
    func text(_ value: Double) -> String {
        inHg ? String(format: "%.2f", value / Self.hpaPerInHg) : String(Int(value.rounded()))
    }

    var valueText: String { text(hpa) }

    /// `value` moved by knob detents: 1 hPa, or 0.01 inHg.
    func turned(_ value: Double, by steps: Int) -> Double {
        let next = inHg
            ? ((value / Self.hpaPerInHg * 100).rounded() + Double(steps)) / 100 * Self.hpaPerInHg
            : value.rounded() + Double(steps)
        return next.clamped(to: Self.hpaRange)
    }

    /// The ring turned to the other unit. The standard setting stays
    /// exactly standard (1013 / 29.92); any other value rounds to the new
    /// unit's step.
    func withUnit(inHg: Bool) -> BaroSetting {
        var b = self
        b.inHg = inHg
        func snap(_ v: Double) -> Double {
            if abs(v - Self.standardHpa) < 0.6 { return Self.standardHpa }
            return inHg ? (v / Self.hpaPerInHg * 100).rounded() / 100 * Self.hpaPerInHg : v.rounded()
        }
        b.hpa = snap(hpa)
        b.preselectHpa = preselectHpa.map(snap)
        return b
    }
}
