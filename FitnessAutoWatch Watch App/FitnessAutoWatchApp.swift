import SwiftUI
import WatchKit
import HealthKit

final class WorkoutAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        // Fetch current intent, so a delayed system launch cannot replay a stopped workout.
        WatchWorkoutManager.shared.fetchCurrentState()
    }
}

@main
struct FitnessAutoWatchApp: App {
    @WKApplicationDelegateAdaptor(WorkoutAppDelegate.self) var delegate
    @StateObject private var workout = WatchWorkoutManager.shared
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(workout) }
    }
}
