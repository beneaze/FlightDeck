import Foundation

/// Lateral and vertical guidance derived from the flight plan — what the
/// PFD's flight director, course pointer and deviation scales steer by.
/// Shared by both flight-deck styles.
@MainActor
struct Guidance {
    let flightData: FlightDataModel
    let routePlanner: RoutePlanner

    /// Bearing the guidance steers toward: a point on the flight plan a few
    /// seconds ahead of the aircraft — the current leg, following the planned
    /// path around its curves — not the final destination. On a direct-to leg
    /// the destination is the path.
    var bearing: Double? {
        guard let location = flightData.location else { return nil }
        // Look ahead 5 s at the current speed, at least 150 m, so the command
        // leads each turn without cutting the corner.
        let lookaheadMeters = max(150, flightData.groundSpeedKts * 1852 / 3600 * 5)
        guard let target = routePlanner.guidanceTargetCoordinate(lookaheadMeters: lookaheadMeters)
        else { return nil }
        return NDGeometry(apex: .zero, radius: 1, rangeNm: 1,
                          origin: location.coordinate, headingDeg: 0)
            .vector(to: target).bearingDeg
    }

    /// What the flight director steers to: the selected heading in HDG
    /// (HDG SEL), else the route.
    var commandBearing: Double? {
        // Once the localiser is captured it is flown, whatever the heading.
        isLocalizerCaptured ? bearing : (flightData.autoFlight.selectedHeadingDeg ?? bearing)
    }

    /// The localiser deviation: the route's course against the track,
    /// whatever heading is selected.
    var localizerError: Double {
        guard let bearing else { return 0 }
        return angularDifference(bearing, flightData.trackDeg)
    }

    /// Signed error between the commanded course and the actual track, in
    /// degrees, positive right.
    var courseError: Double {
        guard let commandBearing else { return 0 }
        return angularDifference(commandBearing, flightData.trackDeg)
    }

    /// The flight director's pitch command relative to the present
    /// attitude, degrees: in V/S, the flight-path angle the selected
    /// vertical speed asks for at this speed, less the present one;
    /// otherwise one degree per 1000 ft to the selected altitude.
    var pitchCommandDeg: Double {
        if let target = flightData.autoFlight.selectedVerticalSpeedFpm {
            let groundFpm = max(flightData.groundSpeedKts, 30) * 101.27
            let want = atan(target / groundFpm) * 180 / .pi
            let now = atan(flightData.verticalSpeedFpm / groundFpm) * 180 / .pi
            return (want - now).clamped(to: -10...10)
        }
        return ((flightData.selectedAltitudeFt - flightData.altitudeFt) / 1_000).clamped(to: -10...10)
    }

    /// The approach scales: on final approach, or any time with the Airbus
    /// LS pushbutton on.
    var showsDeviationScales: Bool {
        routePlanner.destination != nil && (isOnFinalApproach || flightData.autoFlight.landingSystem)
    }

    /// LOC / G/S captured: armed, and on final.
    var isLocalizerCaptured: Bool { flightData.autoFlight.isLocalizerArmed && isOnFinalApproach }
    var isGlideslopeCaptured: Bool { flightData.autoFlight.approachArmed && isOnFinalApproach }

    /// Deviation from a 3° path to the destination, normalised to ±1 full scale.
    var glideDeviation: Double? {
        guard let distance = routePlanner.distanceToGoNm(from: flightData.location),
              distance > 0.3 else { return nil }
        let onPathFt = touchdownElevationFt + distance * 6_076.12 * tan(3 * .pi / 180)
        return ((flightData.altitudeFt - onPathFt) / 600).clamped(to: -1...1)
    }

    /// Where the 3° path meets the ground: the approach runway's threshold,
    /// else the destination airport; a road destination is taken as sea
    /// level, as before.
    private var touchdownElevationFt: Double {
        guard let plan = routePlanner.flightPlan else { return 0 }
        return plan.approachRunway?.elevationFt ?? plan.destination.elevationFt
    }

    /// Final approach: from the intercept point in (12 NM out on a flight,
    /// with some margin), or the last mile of a road route. The LOC and
    /// G/S scales show only then, as on the real displays, which show them
    /// once the approach is armed rather than all flight long.
    var isOnFinalApproach: Bool {
        guard let distance = routePlanner.distanceToGoNm(from: flightData.location) else { return false }
        let finalNm = routePlanner.transportMode == .plane ? FlightPlan.interceptNm + 3 : 1
        return distance <= finalNm
    }
}
