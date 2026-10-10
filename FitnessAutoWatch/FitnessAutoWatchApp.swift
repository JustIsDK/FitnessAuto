import SwiftUI

@main
struct FitnessAutoWatchApp: App {
    @StateObject private var workout = WatchWorkoutManager()
    var body: some Scene {
        WindowGroup { WatchWorkoutView().environmentObject(workout) }
    }
}

struct WatchWorkoutView: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: workout.running ? "heart.fill" : "figure.run")
                .foregroundStyle(workout.running ? .red : .green).font(.title2)
            Text(workout.running ? "记录心率中" : "等待训练")
                .font(.headline)
            Text(workout.heartRate.map { String(format: "%.0f BPM", $0) } ?? "— BPM")
                .font(.title3.monospacedDigit())
            Text(workout.status).font(.caption2).foregroundStyle(.secondary)
        }.padding()
    }
}
