"""Exercise production jump gates, queued jumps and automatic Health sync scheduling."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
bluetooth = (root / "FitnessAuto/TreadmillBluetooth.swift").read_text()
recorder = (root / "FitnessAuto/WorkoutRecorder.swift").read_text()
models = bluetooth[bluetooth.index("struct WorkoutStep:"):bluetooth.index("final class TreadmillBluetooth:")]
data = (root / "FitnessAuto/WorkoutData.swift").read_text()
gates = bluetooth[bluetooth.index("    var canJumpStage:"):bluetooth.index("    func jumpToNextStage()")]
jump = bluetooth[bluetooth.index("    func jumpToStage(at index:"):bluetooth.index("    private struct Checkpoint:")]
sync = recorder[recorder.index("    @MainActor func syncPendingRecords()"):recorder.index("    @discardableResult private func persist")]
sync = sync.replace("UserDefaults.standard", "preferences")
harness = r'''
struct DeviceRange { func contains(_ value: Double) -> Bool { (0...25).contains(value) } }
@MainActor final class JumpProbe {
    var workoutActive = true, appIsActive = true, readyForMotion = true, connected = true
    var vendorAuthorized = true, vendorSubscribed = true, vendorRunning = true
    var vendorWritePending = false, vendorTargetPending = false
    var workoutMotion: WorkoutMotionTransition?
    var workoutConfirmationDeadline: Double?
    var lastVendorStatus: Date? = Date()
    var speedRange: DeviceRange? = DeviceRange(), inclineRange: DeviceRange? = DeviceRange()
    var workoutPlan: WorkoutPlan? = WorkoutPlan(id: 3, title: "probe", steps: [
        WorkoutStep(id: 0, start: 0, duration: 20, title: "one", speed: 5, incline: 0),
        WorkoutStep(id: 1, start: 20, duration: 40, title: "two", speed: 6, incline: 2),
        WorkoutStep(id: 2, start: 60, duration: 60, title: "three", speed: 5, incline: 6)])
    var currentPlan: WorkoutPlan? { workoutPlan }
    var currentStageIndex: Int? { workoutPlan?.stepIndex(at: workoutElapsed) }
    var workoutStartedAt: Double? = ProcessInfo.processInfo.systemUptime - 10
    var workoutActiveAccumulated = 0.0, workoutAccumulated = 0.0
    var workoutActiveSeconds = 0, workoutElapsed = 0
    var workoutStepIndex: Int?
    var workoutExpectedTarget: (speed: UInt8, incline: UInt8)?
    var workoutMessage = ""
    var queuedVendorAction: (() -> Void)?
    var applied: [Int] = []
    GATES
    JUMP
    func saveCheckpoint() {}
    func log(_ message: String) {}
    func tickWorkout() { if !vendorWritePending { applied.append(workoutElapsed) } }
}
enum HKHealthStore { static var available = true; static func isHealthDataAvailable() -> Bool { available } }
struct DuplicateReview { let id: UUID }
@MainActor final class SyncProbe {
    let preferences = UserDefaults(suiteName: "FitnessAuto.SyncCheck.\(UUID())")!
    var automaticSyncRunning = false, saving = false
    var records = [WorkoutRecord(title: "one", running: false), WorkoutRecord(title: "two", running: false)]
    var duplicateReview: DuplicateReview?
    var calls: [UUID] = []
    var markSaved = true, disableDuringSave = false
    var appendDuringSave: WorkoutRecord?
    SYNC
    func saveToHealth(_ record: WorkoutRecord, requestPermission: Bool, automatic: Bool) async {
        assert(!requestPermission && automatic)
        saving = true
        calls.append(record.id)
        await Task.yield()
        if let extra = appendDuringSave { records.append(extra); appendDuringSave = nil }
        if markSaved, let index = records.firstIndex(where: { $0.id == record.id }) { records[index].healthSaved = true }
        if disableDuringSave { preferences.set(false, forKey: "fitnessauto.workout.health.auto") }
        saving = false
    }
}
@main struct Checks {
    @MainActor static func main() async {
        let jump = JumpProbe()
        assert(jump.canJumpStage)
        jump.vendorWritePending = true
        assert(jump.canJumpStage && jump.canJumpNextStage) // Routine polling does not flash disabled states.
        jump.jumpToStage(at: 1)
        assert(jump.workoutElapsed == 20 && jump.workoutActiveSeconds == 10 && jump.applied.isEmpty)
        jump.jumpToStage(at: 2) // Latest choice wins while a status write is finishing.
        assert(jump.workoutElapsed == 60 && jump.workoutActiveSeconds == 10)
        jump.vendorWritePending = false
        let queued = jump.queuedVendorAction; jump.queuedVendorAction = nil; queued?()
        assert(jump.applied == [60])
        jump.vendorTargetPending = true; assert(!jump.canJumpStage)
        jump.vendorTargetPending = false; jump.workoutConfirmationDeadline = 100; assert(!jump.canJumpStage)
        jump.workoutConfirmationDeadline = nil; jump.lastVendorStatus = Date().addingTimeInterval(-4); assert(!jump.canJumpStage)

        let sync = SyncProbe()
        let extra = WorkoutRecord(title: "arrived during sync", running: false)
        sync.appendDuringSave = extra
        await sync.syncPendingRecords()
        assert(sync.calls.count == 3 && sync.records.allSatisfy(\.healthSaved))
        await sync.syncPendingRecords(); assert(sync.calls.count == 3)
        let failures = SyncProbe(); failures.markSaved = false
        await failures.syncPendingRecords()
        assert(failures.calls.count == 2 && failures.records.allSatisfy { !$0.healthSaved })
        assert(!failures.automaticSyncRunning) // A later foreground retry remains possible.
        let disabled = SyncProbe(); disabled.preferences.set(false, forKey: "fitnessauto.workout.health.auto")
        await disabled.syncPendingRecords(); assert(disabled.calls.isEmpty)
        let switchOff = SyncProbe(); switchOff.disableDuringSave = true
        await switchOff.syncPendingRecords(); assert(switchOff.calls.count == 1)
        let reviewing = SyncProbe(); reviewing.duplicateReview = DuplicateReview(id: reviewing.records[0].id)
        await reviewing.syncPendingRecords(); assert(reviewing.calls == [reviewing.records[1].id])
        let concurrent = SyncProbe()
        async let first: Void = concurrent.syncPendingRecords()
        async let second: Void = concurrent.syncPendingRecords()
        _ = await (first, second)
        assert(concurrent.calls.count == 2 && Set(concurrent.calls).count == 2)
        print("Passed: polling-stable jumps, queued targets, real active time and serial automatic Health sync scheduling.")
    }
}
'''
harness = harness.replace("GATES", gates).replace("JUMP", jump).replace("SYNC", sync)
with tempfile.TemporaryDirectory() as folder:
    path = pathlib.Path(folder) / "checks.swift"
    path.write_text("import Foundation\n" + models + data + harness)
    binary = pathlib.Path(folder) / "checks"
    subprocess.run(["swiftc", "-parse-as-library", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
