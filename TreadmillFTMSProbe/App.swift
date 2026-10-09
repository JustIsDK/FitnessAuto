import SwiftUI

@main
struct TreadmillFTMSProbeApp: App {
    @StateObject private var bluetooth = TreadmillBluetooth()

    @StateObject private var library = PlanLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(library)
                .environmentObject(bluetooth.recorder)
        }
    }
}
