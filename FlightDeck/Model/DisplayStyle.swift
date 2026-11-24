import Foundation

/// Whose flight deck the displays imitate.
///
/// Both styles show the same data — the car's speed, height, heading, the
/// route — in the symbology of a different airliner. Both looks are our own
/// parametric drawings of the real displays: the A320's and the 737NG's.
enum DisplayStyle: String, CaseIterable {
    case airbus
    case boeing

    var label: String {
        switch self {
        case .airbus: return "A320"
        case .boeing: return "B737"
        }
    }

    var profile: AircraftProfile {
        switch self {
        case .airbus: return .a320
        case .boeing: return .b737
        }
    }
}
