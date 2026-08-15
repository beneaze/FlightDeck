import SwiftUI

/// Root layout: PFD above ND in portrait, side by side in landscape —
/// decided purely by the aspect ratio of the available space so it also
/// behaves sensibly on iPad and in split screen.
///
/// A settings drawer (attitude calibration and friends) slides in from the
/// left edge on a right swipe.
struct ContentView: View {
    @EnvironmentObject private var flightData: FlightDataModel
    @EnvironmentObject private var routePlanner: RoutePlanner

    @State private var isMenuOpen = false

    private let menuWidth: CGFloat = 280

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack(alignment: .leading) {
                EFIS.background.ignoresSafeArea()
                // The PFD is a square instrument, so it is given a square box
                // and the ND takes whatever is left.
                if landscape {
                    HStack(spacing: 2) {
                        PFDView()
                            .frame(width: min(proxy.size.height, proxy.size.width * 0.55))
                        NDView()
                    }
                } else {
                    VStack(spacing: 2) {
                        PFDView()
                            .frame(height: min(proxy.size.width, proxy.size.height * 0.58))
                        NDView()
                    }
                }

                // Scrim: dims the instruments and closes the menu on a tap.
                if isMenuOpen {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { setMenu(open: false) }
                }

                SideMenuView(isOpen: $isMenuOpen)
                    .frame(width: menuWidth)
                    .offset(x: isMenuOpen ? 0 : -menuWidth - 20)
            }
            .animation(.easeOut(duration: 0.22), value: isMenuOpen)
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        // Mostly-horizontal swipes only, so the gesture never
                        // fights the instruments' own controls.
                        guard abs(value.translation.width) > abs(value.translation.height)
                        else { return }
                        if value.translation.width > 60 { setMenu(open: true) }
                        if value.translation.width < -60 { setMenu(open: false) }
                    }
            )
        }
        .statusBarHidden(true)
        // Each fix advances the flight plan: waypoints sequence as they pass.
        .onReceive(flightData.$location) { routePlanner.updateProgress(location: $0) }
    }

    private func setMenu(open: Bool) {
        isMenuOpen = open
    }
}

#Preview {
    ContentView()
        .environmentObject(FlightDataModel())
        .environmentObject(RoutePlanner())
}
