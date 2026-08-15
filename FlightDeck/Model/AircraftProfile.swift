import SwiftUI

/// Behavioural definition of one aircraft type's displays: the speed envelope
/// the tapes annotate and the scale each tape is drawn at.
///
/// Colours are *not* part of the profile — Airbus EFIS colour is standardised
/// across the fleet and lives in ``EFIS``.
struct AircraftProfile {
    let name: String

    // MARK: Speed envelope (KIAS)

    /// Lowest selectable speed — amber bar on the speed tape.
    let vls: Double
    /// Max operating speed — red/black barber pole on the speed tape.
    let vmo: Double
    /// Stall warning speed — red bar below VLS.
    let vAlphaMax: Double

    // MARK: Tape scales

    /// Knots visible top-to-bottom on the speed tape.
    let speedTapeRangeKts: Double
    let speedTickKts: Double
    let speedLabelEveryKts: Double

    /// Feet visible top-to-bottom on the altitude tape.
    let altTapeRangeFt: Double
    let altTickFt: Double
    let altLabelEveryFt: Double

    /// Degrees visible across the PFD heading tape.
    let headingTapeRangeDeg: Double

    // MARK: ND

    /// Selectable ND ranges, in nautical miles.
    let ndRangesNm: [Double]
    let ndDefaultRangeIndex: Int

    static let a320 = AircraftProfile(
        name: "A320",
        vls: 132,
        vmo: 350,
        vAlphaMax: 118,
        speedTapeRangeKts: 84,
        speedTickKts: 10,
        speedLabelEveryKts: 20,
        altTapeRangeFt: 1_200,
        altTickFt: 100,
        altLabelEveryFt: 500,
        headingTapeRangeDeg: 50,
        // The real EFIS panel stops at 10 NM; the sub-mile settings extend it
        // down to street scale (0.1 NM ≈ 185 m) for navigating in a car.
        ndRangesNm: [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 40, 80, 160, 320],
        ndDefaultRangeIndex: 6
    )
}
