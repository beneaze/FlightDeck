import SwiftUI

/// Left-hand drawer for app settings that have no place on the instruments
/// themselves. Swipe right anywhere to open it; swipe left or tap beside it
/// to put it away.
struct SideMenuView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @Environment(\.openURL) private var openURL
    @Binding var isOpen: Bool

    @State private var isPickingDestination = false

    var body: some View {
        // Scrolls when the content outgrows the screen (landscape). It must
        // never report more than the proposed height: an oversized menu —
        // even parked offscreen — would inflate the root ZStack and shove the
        // instruments off-centre.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("MENU")
                    .font(EFIS.label(15))
                    .foregroundStyle(.white)

                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(height: 1)

                navigationSection

                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(height: 1)

                unitsSection

                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(height: 1)

                attitudeSection
            }
            .padding(20)
        }
        .frame(maxHeight: .infinity)
        .background(EFIS.background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1)
        }
        .fullScreenCover(isPresented: $isPickingDestination) {
            DestinationPickerView { isOpen = false }
        }
    }

    // MARK: Navigation

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NAVIGATION")
                .font(EFIS.label(11))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 8) {
                Text(routePlanner.destination.map { "DEST: \($0.name.uppercased())" } ?? "DEST: NONE")
                    .font(EFIS.digits(12))
                    .foregroundStyle(routePlanner.destination == nil ? .white : EFIS.green)
                    .lineLimit(1)
                if routePlanner.isPlanning {
                    ProgressView().tint(.white).scaleEffect(0.7)
                }
            }

            menuButton("SELECT DESTINATION", color: EFIS.cyan) {
                isPickingDestination = true
            }

            if routePlanner.destination != nil {
                menuButton("OPEN IN GOOGLE MAPS", color: EFIS.green) {
                    if let url = routePlanner.googleMapsURL(from: flightData.location?.coordinate) {
                        openURL(url)
                    }
                }
                menuButton("CLEAR ROUTE", color: EFIS.amber) {
                    routePlanner.clearRoute()
                }
            }
        }
    }

    // MARK: Units

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SPEED UNIT")
                .font(EFIS.label(11))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 8) {
                ForEach(SpeedUnit.allCases, id: \.self) { unit in
                    unitButton(unit.label, isSelected: flightData.speedUnit == unit) {
                        flightData.speedUnit = unit
                    }
                }
            }

            Text("VERTICAL SPEED")
                .font(EFIS.label(11))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 8) {
                ForEach(VerticalSpeedUnit.allCases, id: \.self) { unit in
                    unitButton(unit.label, isSelected: flightData.verticalSpeedUnit == unit) {
                        flightData.verticalSpeedUnit = unit
                    }
                }
            }
        }
    }

    private func unitButton(_ label: String, isSelected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(EFIS.digits(12, .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? .black : EFIS.cyan)
                .background(isSelected ? EFIS.cyan : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(EFIS.cyan, lineWidth: 1))
        }
    }

    // MARK: Attitude calibration

    private var attitudeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ATTITUDE REFERENCE")
                .font(EFIS.label(11))
                .foregroundStyle(.white.opacity(0.6))

            // Live values, so setting the zero visibly snaps them to 0.0.
            HStack(spacing: 14) {
                readout("PITCH", flightData.pitchDeg)
                readout("ROLL", flightData.rollDeg)
            }

            Text(flightData.isCalibrated ? "ZERO: CURRENT MOUNT" : "ZERO: PHONE VERTICAL")
                .font(EFIS.digits(12))
                .foregroundStyle(flightData.isCalibrated ? EFIS.cyan : .white)

            menuButton("SET ZERO HERE", color: EFIS.cyan) {
                flightData.calibrate()
            }

            if flightData.isCalibrated {
                menuButton("RESET TO VERTICAL", color: EFIS.amber) {
                    flightData.clearCalibration()
                }
            }

            Text("Sets the phone's current pose as 0° pitch and 0° roll, for mounts that sit at an angle.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readout(_ label: String, _ value: Double) -> some View {
        (Text(label + " ").font(EFIS.digits(11)).foregroundStyle(.white)
         + Text(String(format: "%+.1f°", value)).font(EFIS.digits(13, .bold))
            .foregroundStyle(EFIS.green))
    }

    private func menuButton(_ title: String, color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(EFIS.digits(13, .bold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 1.2))
        }
    }
}

#Preview {
    SideMenuView(isOpen: .constant(true))
        .environmentObject(FlightDataModel())
        .frame(width: 280)
        .background(.black)
}
