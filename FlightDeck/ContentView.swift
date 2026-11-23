import SwiftUI

/// Root layout: PFD above ND in portrait, side by side in landscape —
/// decided purely by the aspect ratio of the available space so it also
/// behaves sensibly on iPad and in split screen. Which flight deck's
/// displays appear — Airbus or Boeing — is the crew's choice in the menu.
///
/// A right swipe brings up the MCDU, where the route or flight is set up and
/// every setting lives; a left swipe (or its DISPLAYS key) puts it away.
/// A left swipe on the displays brings up the glareshield panel — the A320
/// FCU or the 737 MCP — which a right swipe puts away.
struct ContentView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner
    @EnvironmentObject private var speedLimits: SpeedLimitProvider
    @EnvironmentObject private var flightPacks: FlightPackStore

    /// The MCDU or the glareshield panel, whichever is up — one cover, as
    /// two on one view do not present reliably.
    @State private var cover: Cover?
    private enum Cover: Identifiable {
        case mcdu, panel
        var id: Self { self }
    }
    @StateObject private var mcdu = MCDUController()
    @AppStorage(SafetyNoticeView.acceptedKey) private var hasAcceptedSafetyNotice = false

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack(alignment: .leading) {
                background.ignoresSafeArea()
                // The PFD is a square instrument, so it is given a square box
                // and the ND takes whatever is left.
                if landscape {
                    HStack(spacing: 2) {
                        pfd.frame(width: min(proxy.size.height, proxy.size.width * 0.55))
                        nd
                    }
                } else {
                    VStack(spacing: 2) {
                        pfd.frame(height: min(proxy.size.width, proxy.size.height * 0.58))
                        nd
                    }
                }

                if flightData.isLocationDenied {
                    locationDeniedBanner
                }

            }
            .fullScreenCover(item: $cover) { which in
                switch which {
                case .mcdu: MCDUView(controller: mcdu)
                case .panel: FCUView(flightData: flightData) { cover = nil }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        // Mostly-horizontal swipes only, so the gesture never
                        // fights the instruments' own controls.
                        guard abs(value.translation.width) > abs(value.translation.height)
                        else { return }
                        if value.translation.width > 60 { setMenu(open: true) }
                        if value.translation.width < -60 { cover = .panel }
                    }
            )
        }
        .statusBarHidden(true)
        .fullScreenCover(isPresented: Binding(get: { !hasAcceptedSafetyNotice }, set: { _ in })) {
            SafetyNoticeView { hasAcceptedSafetyNotice = true }
        }
        // Every position update advances the flight plan — the aircraft's
        // projection onto the route, and the waypoints sequencing as they
        // pass — so the guidance follows the dead-reckoned position between
        // fixes. Speed limits match against the fixes themselves.
        .onReceive(flightData.$location) { routePlanner.updateProgress(location: $0) }
        .onReceive(flightData.$gpsFix) {
            // Road speed limits only on the road: in plane mode no position
            // goes to OpenStreetMap.
            guard routePlanner.transportMode.isRoad else { return }
            speedLimits.update(fix: $0, trackDeg: flightData.trackDeg)
        }
        // Plane mode: the sensors switch to their in-cabin sources, and the
        // active flight pack's plan becomes the route.
        .onAppear {
            mcdu.attach(routePlanner: routePlanner, flightData: flightData,
                        packs: flightPacks, speedLimits: speedLimits)
            mcdu.close = { cover = nil }
            syncFlightMode()
        }
        .onChange(of: routePlanner.transportMode) { syncFlightMode() }
        .onChange(of: flightPacks.activePackID) { syncFlightMode() }
        .onChange(of: routePlanner.flightPlan?.id) {
            flightData.demoFlightPlan = routePlanner.flightPlan
        }
    }

    // MARK: Flight deck

    /// The displays in whichever manufacturer's style the crew has chosen.
    @ViewBuilder private var pfd: some View {
        switch flightData.displayStyle {
        case .airbus: PFDView()
        case .boeing: BoeingPFDView()
        }
    }

    @ViewBuilder private var nd: some View {
        switch flightData.displayStyle {
        case .airbus: NDView()
        case .boeing: BoeingNDView()
        }
    }

    private var background: Color {
        flightData.displayStyle == .boeing ? Boeing.background : EFIS.background
    }

    /// Without location the tapes and the map have nothing to show; say why
    /// and offer the way back, rather than leaving the displays blank.
    private var locationDeniedBanner: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text("LOCATION OFF — NO SPEED, ALTITUDE OR MAP")
                    .font(EFIS.digits(12, .bold))
                    .foregroundStyle(EFIS.amber)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("SETTINGS")
                        .font(EFIS.digits(12, .bold))
                        .foregroundStyle(EFIS.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EFIS.cyan, lineWidth: 1))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(EFIS.amber, lineWidth: 1))
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private func syncFlightMode() {
        let flying = routePlanner.transportMode == .plane
        flightData.isFlightMode = flying
        if flying { speedLimits.pause() }
        #if DEBUG
        // Test hook: `-debugFlight LSZH-LPPT` plans and downloads that flight
        // on launch, so plane mode can be exercised without the picker.
        if flying, let spec = UserDefaults.standard.string(forKey: "debugFlight"),
           flightPacks.activePack == nil, flightPacks.progress == nil {
            let codes = spec.split(separator: "-").map(String.init)
            if codes.count == 2, let from = AirportDatabase.shared.airport(code: codes[0]),
               let to = AirportDatabase.shared.airport(code: codes[1]) {
                let existing = flightPacks.packs.first { $0.plan.origin == from && $0.plan.destination == to }?.plan
                let plan = existing ?? FlightPlan(flightNumber: nil, callsign: nil, date: Date(), origin: from, destination: to)
                Task { await flightPacks.prepare(plan) }
                return
            }
        }
        #endif
        guard flying, let plan = flightPacks.activePack?.plan,
              routePlanner.flightPlan?.id != plan.id else { return }
        routePlanner.adopt(flightPlan: plan)
        flightData.selectedAltitudeFt = plan.reachableCruiseFt
    }

    private func setMenu(open: Bool) {
        cover = open ? .mcdu : nil
    }
}

#Preview {
    ContentView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
        .environmentObject(FlightPackStore())
        .environmentObject(SpeedLimitProvider())
}
