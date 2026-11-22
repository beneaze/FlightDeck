import SwiftUI

/// Left-hand drawer for app settings that have no place on the instruments
/// themselves. Swipe right anywhere to open it; swipe left or tap beside it
/// to put it away.
struct SideMenuView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @EnvironmentObject private var speedLimits: SpeedLimitProvider
    @EnvironmentObject private var packs: FlightPackStore
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

                divider
                navigationSection
                divider
                speedLimitSection
                divider
                flightDeckSection
                divider
                unitsSection
                divider
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
            if routePlanner.transportMode == .plane {
                FlightPickerView { isOpen = false }
            } else {
                DestinationPickerView { isOpen = false }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.25))
            .frame(height: 1)
    }

    // MARK: Navigation

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("NAVIGATION")

            HStack(spacing: 8) {
                Text(routePlanner.destination.map { "DEST: \($0.name.uppercased())" } ?? "DEST: NONE")
                    .font(EFIS.digits(12))
                    .foregroundStyle(routePlanner.destination == nil ? .white : EFIS.green)
                    .lineLimit(1)
                if routePlanner.isPlanning {
                    ProgressView().tint(.white).scaleEffect(0.7)
                }
            }

            menuButton(routePlanner.transportMode == .plane ? "SELECT FLIGHT" : "SELECT DESTINATION",
                       color: EFIS.cyan) {
                isPickingDestination = true
            }

            // Car, bicycle or plane. Between car and bike, switching replans
            // on the spot; plane mode flies a flight plan instead.
            HStack(spacing: 8) {
                ForEach(TransportMode.allCases, id: \.self) { mode in
                    choiceButton(mode.label, isSelected: routePlanner.transportMode == mode) {
                        routePlanner.transportMode = mode
                    }
                }
            }

            if routePlanner.transportMode == .plane {
                flightStatus
            } else if routePlanner.destination != nil {
                if let status = routePlanner.elevationStatus {
                    Text("ROUTE ELEV: \(status)")
                        .font(EFIS.digits(11))
                        .foregroundStyle(status == "LOADING" ? .white.opacity(0.6) : EFIS.amber)
                }
                menuButton("OPEN IN GOOGLE MAPS", color: EFIS.green) {
                    if let url = routePlanner.googleMapsURL(from: flightData.location?.coordinate) {
                        openURL(url)
                    }
                }
                menuButton("CLEAR ROUTE", color: EFIS.amber) {
                    routePlanner.clearRoute()
                }
            }

            Text(navigationNote)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var navigationNote: String {
        let parts: [String]
        if routePlanner.transportMode == .plane {
            parts = ["Flight paths from the free flight-track archive, or great circle.",
                     "Terrain is downloaded with the flight for use without internet.",
                     FlightArchiveProvider.attribution, TerrainStore.attribution, "Airports: OurAirports."]
        } else {
            parts = ["Routes by Apple Maps.",
                     "The vertical display's route height profile comes from terrain tiles downloaded when a route is planned.",
                     TerrainStore.attribution]
        }
        return parts.joined(separator: " ")
    }

    /// Plane mode: the flight being flown and whether it is ready to work
    /// without internet.
    @ViewBuilder private var flightStatus: some View {
        if let plan = routePlanner.flightPlan {
            Text("\(plan.title)  \(plan.origin.code)→\(plan.destination.code)")
                .font(EFIS.digits(12, .bold))
                .foregroundStyle(EFIS.green)
            let ready = packs.activePack.map { $0.plan.id == plan.id && $0.isComplete } ?? false
            Text(ready ? "OFFLINE DATA: READY" : "OFFLINE DATA: NOT DOWNLOADED")
                .font(EFIS.digits(11))
                .foregroundStyle(ready ? EFIS.green : EFIS.amber)
            menuButton("CLEAR FLIGHT", color: EFIS.amber) {
                packs.activate(nil)
                routePlanner.clearRoute()
            }
        } else {
            Text("NO FLIGHT SELECTED")
                .font(EFIS.digits(11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: Speed limit

    private var speedLimitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("SPEED LIMIT (VMAX)")

            HStack(spacing: 8) {
                choiceButton("ON", isSelected: speedLimits.isEnabled) { speedLimits.isEnabled = true }
                choiceButton("OFF", isSelected: !speedLimits.isEnabled) { speedLimits.isEnabled = false }
            }

            if speedLimits.isEnabled {
                HStack(spacing: 14) {
                    if let limit = speedLimits.limitKts {
                        readout("LIMIT",
                                value: "\(Int((limit * flightData.speedUnit.perKnot).rounded())) \(flightData.speedUnit.label)",
                                color: EFIS.red)
                    } else if speedLimits.isUnrestricted {
                        readout("LIMIT", value: "NONE", color: EFIS.green)
                    } else {
                        readout("LIMIT", value: "---", color: EFIS.amber)
                    }
                    if let road = speedLimits.roadName {
                        Text(road.uppercased())
                            .font(EFIS.digits(11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Text(speedLimits.status)
                    .font(EFIS.digits(11))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Text("Posted limit of the road being driven, from OpenStreetMap. Drawn as the red VMAX barber pole on the speed tape. Sends your position to overpass-api.de. Road data © OpenStreetMap contributors.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Flight deck

    /// Whose displays to fly with: the A320's or the 737's.
    private var flightDeckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("FLIGHT DECK")

            HStack(spacing: 8) {
                ForEach(DisplayStyle.allCases, id: \.self) { style in
                    choiceButton(style.label, isSelected: flightData.displayStyle == style) {
                        flightData.displayStyle = style
                    }
                }
            }
        }
    }

    // MARK: Units

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("SPEED UNIT")

            HStack(spacing: 8) {
                ForEach(SpeedUnit.allCases, id: \.self) { unit in
                    choiceButton(unit.label, isSelected: flightData.speedUnit == unit) {
                        flightData.speedUnit = unit
                    }
                }
            }

            sectionTitle("VERTICAL SPEED")

            HStack(spacing: 8) {
                ForEach(VerticalSpeedUnit.allCases, id: \.self) { unit in
                    choiceButton(unit.label, isSelected: flightData.verticalSpeedUnit == unit) {
                        flightData.verticalSpeedUnit = unit
                    }
                }
            }
        }
    }

    // MARK: Attitude

    private var attitudeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ROLL SOURCE")

            HStack(spacing: 8) {
                ForEach(RollSource.allCases, id: \.self) { source in
                    choiceButton(source.label, isSelected: flightData.rollSource == source) {
                        flightData.rollSource = source
                    }
                }
            }

            Text(flightData.rollSource == .lateralAcceleration
                 ? "Bank an aircraft would need for the same cornering force — a car corners flat, so tilt alone reads zero. 0.3 g is a 17° bank."
                 : "The phone's physical bank, from gravity — an aircraft's roll.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            sectionTitle("ATTITUDE REFERENCE")

            // Live values, so setting the zero visibly snaps them to 0.0.
            HStack(spacing: 14) {
                readout("PITCH", value: String(format: "%+.1f°", flightData.pitchDeg))
                readout("ROLL", value: String(format: "%+.1f°", flightData.rollDeg))
            }
            readout("LATERAL G", value: String(format: "%+.2f", flightData.lateralG))

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

    // MARK: Building blocks

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(EFIS.label(11))
            .foregroundStyle(.white.opacity(0.6))
    }

    private func readout(_ label: String, value: String, color: Color = EFIS.green) -> some View {
        (Text(label + " ").font(EFIS.digits(11)).foregroundStyle(.white)
         + Text(value).font(EFIS.digits(13, .bold)).foregroundStyle(color))
    }

    /// One option of a mutually exclusive set — filled cyan when selected.
    private func choiceButton(_ label: String, isSelected: Bool,
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
        .environmentObject(RoutePlanner())
        .environmentObject(FlightPackStore())
        .environmentObject(SpeedLimitProvider())
        .frame(width: 280)
        .background(.black)
}
