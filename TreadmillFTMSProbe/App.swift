import SwiftUI

@main
struct TreadmillFTMSProbeApp: App {
    @StateObject private var bluetooth = TreadmillBluetooth()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
        }
    }
}
