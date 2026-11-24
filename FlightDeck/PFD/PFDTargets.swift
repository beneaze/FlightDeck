import Foundation

/// A speed or altitude target as the PFDs show it: its value, and whether
/// the crew selected it on the glareshield (cyan on the A320) or the flight
/// management system manages it (magenta).
struct PFDTarget: Equatable {
    let value: Double
    let isManaged: Bool
}

/// Which speed and altitude the PFDs show as the target, and whose it is.
enum PFDTargets {

    /// The FMS speed limit both aircraft carry by default: 250 kt below
    /// 10,000 ft.
    static let speedLimitKts = 250.0
    static let speedLimitCeilingFt = 10_000.0

    /// The speed target. Selected: the panel's speed. Managed: the speed the
    /// plan or the limit asks for — the posted limit on the road, the FMS
    /// speed limit below 10,000 ft in the air — and none where neither is
    /// known, as there is no planned speed to manage to.
    static func speed(autoFlight: AutoFlight, isRoad: Bool, roadLimitKts: Double?,
                      altitudeFt: Double) -> PFDTarget? {
        if autoFlight.isSpeedSelected, let selected = autoFlight.speedTargetKts {
            return PFDTarget(value: selected, isManaged: false)
        }
        if isRoad {
            return roadLimitKts.map { PFDTarget(value: $0, isManaged: true) }
        }
        return altitudeFt < speedLimitCeilingFt ? PFDTarget(value: speedLimitKts, isManaged: true) : nil
    }

    /// Where a climb or descent will level off. The panel's altitude, unless
    /// the vertical mode is managed (a climb or descent, not V/S) and an
    /// altitude constraint ahead on the flight plan lies between the present
    /// altitude and the panel's: then the aircraft levels at that constraint
    /// first, and the target is the constraint, managed.
    @MainActor
    static func levelOff(selectedFt: Double, altitudeFt: Double, verticalSpeedFpm: Double,
                         autoFlight: AutoFlight, routePlanner: RoutePlanner) -> PFDTarget {
        let selected = PFDTarget(value: selectedFt, isManaged: false)
        guard !autoFlight.isVerticalSpeedEngaged, routePlanner.transportMode == .plane,
              let plan = routePlanner.flightPlan else { return selected }
        let climbing = verticalSpeedFpm > 200 && selectedFt > altitudeFt
        let descending = verticalSpeedFpm < -200 && selectedFt < altitudeFt
        guard climbing || descending else { return selected }

        let along = routePlanner.alongTrackNm
        for (fix, nm) in zip(plan.legs, plan.legDistancesNm) where nm > along {
            guard let constraint = fix.altitudeFt,
                  [.departure, .arrival, .approach].contains(fix.kind) else { continue }
            if climbing, constraint > altitudeFt + 50, constraint < selectedFt {
                return PFDTarget(value: constraint, isManaged: true)
            }
            if descending, constraint < altitudeFt - 50, constraint > selectedFt {
                return PFDTarget(value: constraint, isManaged: true)
            }
        }
        return selected
    }
}
