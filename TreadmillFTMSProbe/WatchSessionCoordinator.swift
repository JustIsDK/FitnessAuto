import Foundation
import HealthKit
import WatchConnectivity

/// Latest desired state replaces pending commands; never queue stale starts.
final class WatchSessionCoordinator: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionCoordinator()
    @Published private(set) var status = "等待运动开始"
    private let session = WCSession.default
    private let health = HKHealthStore()
    private var identifier: String?
    private var desired: [String: Any] = ["active": false, "revision": 0.0]

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }
    func startWorkout(title: String, running: Bool) {
        guard identifier == nil else { return }
        let id = UUID().uuidString
        identifier = id
        desired = ["id": id, "active": true, "title": title, "running": running,
                   "revision": Date().timeIntervalSince1970]
        publish()
        launch(id: id, running: running)
    }
    private func launch(id: String, running: Bool) {
        guard session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else {
            status = "请先在 Apple Watch 安装 FitnessAuto"; return
        }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = running ? .running : .walking
        configuration.locationType = .indoor
        health.startWatchApp(with: configuration) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, self.identifier == id else { return }
                self.status = success ? "已请求手表开始心率记录" : "手表启动失败：\(error?.localizedDescription ?? "请检查手表连接及健康权限")"
            }
        }
    }
    func stopWorkout() {
        guard identifier != nil else { return }
        identifier = nil
        status = "已请求手表结束心率记录"
        desired["active"] = false
        desired["revision"] = Date().timeIntervalSince1970
        publish()
    }
    private func publish() {
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        do { try session.updateApplicationContext(desired) }
        catch { status = "手表同步失败：\(error.localizedDescription)" }
        if session.isReachable {
            session.sendMessage(desired, replyHandler: nil) { [weak self] error in
                DispatchQueue.main.async { self?.status = "等待手表同步：\(error.localizedDescription)" }
            }
        }
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.publish()
            if let id = self.identifier { self.launch(id: id, running: self.desired["running"] as? Bool ?? false) }
        }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async { replyHandler(self.desired) }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
