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

    /// Signed error between the guidance course and the actual track, in
    /// degrees, positive right.
    var courseError: Double {
        guard let bearing else { return 0 }
        return angularDifference(bearing, flightData.trackDeg)
    }

    /// Deviation from a 3° path to the destination, normalised to ±1 full scale.
    var glideDeviation: Double? {
        guard let distance = routePlanner.distanceToGoNm(from: flightData.location),
              distance > 0.3 else { return nil }
        let onPathFt = distance * 6_076.12 * tan(3 * .pi / 180)
        return ((flightData.altitudeFt - onPathFt) / 600).clamped(to: -1...1)
    }
}
