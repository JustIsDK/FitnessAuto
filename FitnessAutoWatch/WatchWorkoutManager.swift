import Foundation
import HealthKit
import WatchConnectivity

final class WatchWorkoutManager: NSObject, ObservableObject, WCSessionDelegate, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    @Published private(set) var running = false
    @Published private(set) var heartRate: Double?
    @Published private(set) var status = "等待 iPhone 开始训练"
    private let health = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func handle(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        DispatchQueue.main.async {
            switch command {
            case "start", "resume": self.start()
            case "pause": self.pause()
            case "stop": self.stop()
            default: break
            }
        }
    }

    private func start() {
        guard !running else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .indoor
        do {
            let workout = try HKWorkoutSession(healthStore: health, configuration: configuration)
            let live = workout.associatedWorkoutBuilder()
            workout.delegate = self; live.delegate = self
            session = workout; builder = live
            running = true; status = "正在启动运动记录"
            workout.startActivity(with: Date())
            live.beginCollection(withStart: Date()) { [weak self] success, error in
                DispatchQueue.main.async { self?.status = success ? "正在记录心率" : (error?.localizedDescription ?? "无法开始心率记录") }
            }
        } catch { status = "无法启动运动记录：\(error.localizedDescription)" }
    }
    private func pause() { session?.pause(); status = "已暂停心率记录" }
    private func stop() {
        guard let session, let builder else { return }
        session.end()
        builder.endCollection(withEnd: Date()) { [weak self] _, _ in
            builder.finishWorkout { _, _ in DispatchQueue.main.async { self?.running = false; self?.status = "心率记录已保存" } }
        }
    }
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) { DispatchQueue.main.async { self.status = error.localizedDescription; self.running = false } }
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate), types.contains(type),
              let value = workoutBuilder.statistics(for: type)?.mostRecentQuantity() else { return }
        let rate = value.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        DispatchQueue.main.async { self.heartRate = rate }
    }
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKQuantityType>) {}
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) { handle(message) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) { handle(userInfo) }
}
