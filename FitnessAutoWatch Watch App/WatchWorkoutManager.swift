import Foundation
import Combine
import HealthKit
import WatchConnectivity

final class WatchWorkoutManager: NSObject, ObservableObject, WCSessionDelegate, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    static let shared = WatchWorkoutManager()
    @Published private(set) var running = false
    @Published private(set) var heartRate: Double?
    @Published private(set) var title = "跑步机心率"
    @Published private(set) var status = "首次使用请授权健康权限"
    private let health = HKHealthStore()
    private let heartType = HKQuantityType(.heartRate)
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var currentID: String?
    private var dismissedID: String?
    private var revision = -1.0
    private var pending: [String: Any]?
    private var authorizing = false
    private var ending = false
    private var lastSampleDate: Date?
    private var saveFailed = false

    override init() {
        super.init()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    func authorize() {
        guard !authorizing else { return }
        authorizing = true
        health.requestAuthorization(toShare: [HKObjectType.workoutType(), heartType], read: [heartType]) { _, error in
            DispatchQueue.main.async {
                self.authorizing = false
                guard error == nil, self.health.authorizationStatus(for: self.heartType) == .sharingAuthorized,
                      self.health.authorizationStatus(for: .workoutType()) == .sharingAuthorized else {
                    self.status = error?.localizedDescription ?? "请在健康设置中允许心率与运动权限"
                    return
                }
                self.status = "已授权，等待 iPhone 训练"
                if let intent = self.pending { self.apply(intent) }
                else { self.fetchCurrentState() }
            }
        }
    }
    func fetchCurrentState() {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            status = running ? "心率继续记录；等待 iPhone 连接" : "请保持 iPhone 和手表连接后再同步"
            return
        }
        WCSession.default.sendMessage(["request": "state"], replyHandler: { message in
            DispatchQueue.main.async { self.accept(message) }
        }, errorHandler: { error in
            DispatchQueue.main.async { self.status = "同步失败：\(error.localizedDescription)" }
        })
    }
    private func accept(_ message: [String: Any]) {
        guard let version = message["revision"] as? Double, version >= revision else { return }
        revision = version
        pending = message
        apply(message)
    }
    private func apply(_ message: [String: Any]) {
        guard message["active"] as? Bool == true else { stop(manual: false); return }
        guard let id = message["id"] as? String, id != dismissedID else { return }
        if currentID == id { return }
        if workout != nil { stop(manual: false); return }
        guard !ending else { return }
        guard health.authorizationStatus(for: heartType) == .sharingAuthorized,
              health.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { authorize(); return }
        title = message["title"] as? String ?? "跑步机训练"
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = message["running"] as? Bool == true ? .running : .walking
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
            let live = session.associatedWorkoutBuilder()
            live.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: configuration)
            session.delegate = self
            live.delegate = self
            workout = session; builder = live; currentID = id
            heartRate = nil; lastSampleDate = nil; saveFailed = false
            let date = Date()
            running = true; status = "正在启动心率记录"
            session.startActivity(with: date)
            live.beginCollection(withStart: date) { success, error in
                DispatchQueue.main.async {
                    guard self.workout === session, !self.ending else { return }
                    if success { self.status = "心率自动保存至苹果健康" }
                    else { self.status = error?.localizedDescription ?? "心率采集启动失败"; self.stop() }
                }
            }
        } catch { status = "启动失败：\(error.localizedDescription)" }
    }
    func stop(manual: Bool = true) {
        if manual { dismissedID = currentID }
        guard let workout, !ending else { return }
        ending = true
        status = "正在结束心率记录"
        workout.end()
    }
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        DispatchQueue.main.async {
            guard self.workout === workoutSession, let live = self.builder else { return }
            if !self.ending { self.dismissedID = self.currentID }
            self.ending = true
            live.endCollection(withEnd: date) { _, error in
                // Heart samples are saved explicitly; discard the builder to avoid a second workout.
                live.discardWorkout()
                DispatchQueue.main.async {
                    self.workout = nil; self.builder = nil; self.currentID = nil
                    self.running = false; self.ending = false
                    self.status = error?.localizedDescription ?? (self.saveFailed ? "部分心率保存失败，请检查健康权限" : "心率记录已结束")
                    if let next = self.pending { self.apply(next) }
                }
            }
        }
    }
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            guard self.workout === workoutSession else { return }
            self.dismissedID = self.currentID
            self.builder?.discardWorkout()
            self.workout = nil; self.builder = nil; self.currentID = nil
            self.running = false; self.ending = false
            self.status = "心率采集失败：\(error.localizedDescription)"
        }
    }
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        guard types.contains(heartType), let statistics = workoutBuilder.statistics(for: heartType),
              let quantity = statistics.mostRecentQuantity(), let interval = statistics.mostRecentQuantityDateInterval() else { return }
        DispatchQueue.main.async {
            guard self.builder === workoutBuilder, interval.end != self.lastSampleDate else { return }
            self.lastSampleDate = interval.end
            self.heartRate = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
            let metadata: [String: Any] = [HKMetadataKeySyncIdentifier: "FitnessAuto.hr.\(self.currentID ?? "").\(interval.end.timeIntervalSince1970)", HKMetadataKeySyncVersion: 1]
            let sample = HKQuantitySample(type: self.heartType, quantity: quantity, start: interval.start, end: interval.end, metadata: metadata)
            self.health.save(sample) { success, error in
                if !success { DispatchQueue.main.async { self.saveFailed = true; self.status = "心率保存失败：\(error?.localizedDescription ?? "请检查健康权限")" } }
            }
        }
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.fetchCurrentState() }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { DispatchQueue.main.async { self.fetchCurrentState() } }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { self.accept(message) }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Context is only a wake hint. Ask for fresh intent rather than replaying a cached start.
        DispatchQueue.main.async { self.fetchCurrentState() }
    }
}
