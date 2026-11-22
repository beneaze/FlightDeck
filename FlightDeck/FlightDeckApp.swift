import SwiftUI

@main
struct FlightDeckApp: App {
    @StateObject private var flightData = FlightDataModel()
    @StateObject private var routePlanner = RoutePlanner()
    @StateObject private var speedLimits = SpeedLimitProvider()
    @StateObject private var flightPacks = FlightPackStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(flightData)
                .environmentObject(routePlanner)
                .environmentObject(speedLimits)
                .environmentObject(flightPacks)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    flightData.start()
                    // An instrument panel must not dim and lock mid-drive.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
