import Foundation

/// Height above the terrain under the aircraft, presented the way the
/// airliners' radio altimeter readouts present it. There is no radio
/// altimeter on a phone: the height is the GPS altitude less the flight
/// pack's terrain elevation, so it is only as good as both.
enum RadioAltitude {

    /// Both PFDs show the readout only below this height, and blank it above.
    static let displayCeilingFt = 2_500.0

    /// The height to show, or nil when the readout is blanked: no terrain
    /// known, or at or above the display ceiling. Never negative — terrain
    /// data a little above the GPS altitude on the ground reads 0.
    static func height(altitudeFt: Double, groundFt: Double?) -> Double? {
        guard let groundFt else { return nil }
        let height = max(0, altitudeFt - groundFt)
        return height < displayCeilingFt ? height : nil
    }

    /// The A320's steps: 10 ft above 50 ft, 5 ft from 50 ft down to 10 ft,
    /// 1 ft below 10 ft.
    static func airbusDisplayed(_ height: Double) -> Int {
        let step: Double = height > 50 ? 10 : (height >= 10 ? 5 : 1)
        return Int((height / step).rounded() * step)
    }

    /// The A320 turns the readout amber at and below 400 ft when no decision
    /// height is entered — and there is none to enter here.
    static let airbusAmberBelowFt = 400

    /// The 737's steps: 10 ft above 100 ft, 2 ft below.
    static func boeingDisplayed(_ height: Double) -> Int {
        let step: Double = height >= 100 ? 10 : 2
        return Int((height / step).rounded() * step)
    }

    /// The 737 rising runway climbs toward the aircraft symbol over the last
    /// 200 ft: 0 at 200 ft and above, 1 on the ground.
    static func risingRunwayProgress(_ height: Double) -> Double {
        (1 - height / 200).clamped(to: 0...1)
    }
}
