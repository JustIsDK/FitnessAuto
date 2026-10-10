import SwiftUI

struct ContentView: View {
    @EnvironmentObject var workout: WatchWorkoutManager
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "heart.fill").foregroundStyle(.red).font(.title2)
                Text(workout.title).font(.headline)
                Text(workout.heartRate.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("次 / 分").foregroundStyle(.secondary)
                Text(workout.status).font(.caption).multilineTextAlignment(.center)
                if workout.running {
                    Button("结束心率记录", role: .destructive) { workout.stop() }
                    Text("此按钮不会停止跑步机").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("授权并等待训练") { workout.authorize() }
                    Button("同步 iPhone 状态") { workout.fetchCurrentState() }
                }
            }.padding()
        }
    }
}
