import Foundation
import WatchConnectivity

/// Sends workout lifecycle events to the companion watch app. HealthKit
/// recording remains on the watch so watchOS can prioritize its workout UI.
final class WatchSessionCoordinator: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionCoordinator()
    private let session = WCSession.default

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }
    func startWorkout(title: String, running: Bool) { send(["command": "start", "title": title, "running": running]) }
    func pauseWorkout() { send(["command": "pause"]) }
    func resumeWorkout(title: String, running: Bool) { send(["command": "resume", "title": title, "running": running]) }
    func stopWorkout() { send(["command": "stop"]) }
    private func send(_ message: [String: Any]) {
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        if session.isReachable { session.sendMessage(message, replyHandler: nil) }
        else { session.transferUserInfo(message) }
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
