import SwiftUI

@main
struct TreadmillFTMSProbeApp: App {
    @StateObject private var bluetooth = TreadmillBluetooth()

    @StateObject private var library = PlanLibrary()
    @StateObject private var scale = ScaleBluetooth()
    @StateObject private var weightHealth = WeightHealthStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(library)
                .environmentObject(bluetooth.recorder)
                .environmentObject(scale)
                .environmentObject(weightHealth)
                .tint(AppDesign.accent)
        }
    }
}
