import SwiftUI

/// Behavioural definition of one aircraft type's displays: the speed envelope
/// the tapes annotate and the scale each tape is drawn at.
///
/// Colours are *not* part of the profile — each manufacturer's EFIS colour code
/// is standardised across its fleet and lives in ``EFIS`` and ``Boeing``.
struct AircraftProfile {
    let name: String

    // MARK: Speed envelope (KIAS)

    /// Max operating speed — the red barber pole on the speed tape, when no
    /// road speed limit is known to take its place. The low-speed
    /// protections are deliberately absent: a car has no minimum speed.
    let vmo: Double

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
        vmo: 350,
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

    /// Boeing 737-800: a speed tape showing ±60 kt and an altitude tape
    /// showing ±400 ft around the current values.
    static let b737 = AircraftProfile(
        name: "B737-800",
        vmo: 340,
        speedTapeRangeKts: 120,
        speedTickKts: 10,
        speedLabelEveryKts: 20,
        altTapeRangeFt: 800,
        altTickFt: 100,
        altLabelEveryFt: 200,
        headingTapeRangeDeg: 100,
        // The EFIS control panel's 5…640 NM, halved as the display labels
        // them, with the same street-scale settings below.
        ndRangesNm: [0.1, 0.2, 0.5, 1, 2.5, 5, 10, 20, 40, 80, 160, 320],
        ndDefaultRangeIndex: 6
    )
}
