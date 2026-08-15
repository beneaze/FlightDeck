import SwiftUI

@main
struct FlightDeckApp: App {
    @StateObject private var flightData = FlightDataModel()
    @StateObject private var routePlanner = RoutePlanner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(flightData)
                .environmentObject(routePlanner)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                .onAppear { flightData.start() }
        }
    }
}
