"""Exercise actual Swift decoders and accounting without BLE/HealthKit mocks."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
bluetooth = (root / "TreadmillFTMSProbe/TreadmillBluetooth.swift").read_text()
models = bluetooth[bluetooth.index("struct WorkoutStep:"):bluetooth.index("final class TreadmillBluetooth:")]
data = (root / "TreadmillFTMSProbe/WorkoutData.swift").read_text()
importer = (root / "TreadmillFTMSProbe/PlanImport.swift").read_text()
checks = r'''
func u16(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8((n >> 8) & 255)] }
// All optional fields before distance, energy and elapsed exercise offsets.
let flags = 0x1FFE
let full: [UInt8] = u16(flags) + u16(600) + u16(550) + [0x39, 0x30, 0]
    + u16(20) + u16(0) + u16(4) + u16(0) + [10, 11]
    + u16(120) + u16(300) + [5, 100, 20] + u16(600) + u16(120) + u16(0) + u16(0)
let parsed = TreadmillMetrics.parse(Data(full))!
assert(parsed.speed == 6 && parsed.distanceMeters == 12345 && parsed.energyKcal == 120 && parsed.elapsedSeconds == 600)
for length in 0..<full.count { assert(TreadmillMetrics.parse(Data(full.prefix(length))) == nil) }
let fragment = TreadmillMetrics.parse(Data(u16(5) + [100, 0, 0]))!
assert(fragment.speed == nil && fragment.distanceMeters == 100)
let unavailable = TreadmillMetrics.parse(Data(u16(0x0484) + u16(0xFFFF) + [255,255,255] + u16(0xFFFF) + [255,255,255] + u16(0xFFFF)))!
assert(unavailable.speed == nil && unavailable.distanceMeters == nil && unavailable.energyKcal == nil && unavailable.elapsedSeconds == nil)
assert(TreadmillMetrics.parse(Data(u16(0xE000) + u16(100))) == nil)
let start = Date(timeIntervalSince1970: 1000)
var accumulator = WorkoutAccumulator(record: WorkoutRecord(title: "test", running: false))
func observe(_ t: Double) { accumulator.observe(date: start.addingTimeInterval(t), uptime: t) }
func metrics(_ t: Double, _ distance: Double, _ energy: Double) {
    accumulator.metrics(TreadmillMetrics(distanceMeters: distance, energyKcal: energy), uptime: t)
}
observe(0); metrics(0, 100, 20)
observe(1); metrics(1, 105, 21)
observe(2); metrics(2, 110, 22)
assert(accumulator.record.duration == 2 && accumulator.record.distanceMeters == 10 && accumulator.record.energyKcal == 2)
// A gap drops unknown time and counters instead of fabricating activity.
observe(12); metrics(12, 300, 50)
observe(13); metrics(13, 305, 51)
assert(accumulator.record.duration == 3 && accumulator.record.intervals.count == 2)
assert(accumulator.record.distanceMeters == 15 && accumulator.record.energyKcal == 3)
// Counter resets and implausible jumps aren't counted.
observe(14); metrics(14, 0, 0)
observe(15); metrics(15, 5, 1)
observe(16); metrics(16, 100000, 10000)
assert(accumulator.record.distanceMeters == 20 && accumulator.record.energyKcal == 4)
// Clock jumps aren't interpreted as exercise time.
accumulator.observe(date: start.addingTimeInterval(900), uptime: 17)
assert(accumulator.record.duration == 6)
let restored = try JSONDecoder().decode(WorkoutRecord.self, from: JSONEncoder().encode(accumulator.record))
assert(restored.id == accumulator.record.id && restored.duration == 6 && restored.intervals.count == 2)
for preset in WorkoutPlan.presets {
    assert(preset.validationError == nil)
    let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: JSONEncoder().encode(preset))
    assert(decoded.duration == preset.duration && decoded.steps.count == preset.steps.count)
}
var plan = WorkoutPlan.presets[0]
plan.steps[0].duration = 0; assert(plan.validationError != nil)
plan = WorkoutPlan.presets[0]; plan.steps[0].speed = .nan; assert(plan.validationError != nil)
plan = WorkoutPlan.presets[0]; plan.steps[0].speed = 5.15; assert(plan.validationError != nil)
plan = WorkoutPlan.presets[0]; plan.steps[0].incline = 26; assert(plan.validationError != nil)
plan = WorkoutPlan.presets[0]; plan.steps[1].start = 100; assert(plan.validationError != nil)
plan = WorkoutPlan.presets[0]; plan.steps[1].id = 0; assert(plan.validationError != nil)
plan = WorkoutPlan.presets[0]; plan.title = " "; assert(plan.validationError != nil)

assert(MerachMotionCommand.start == [2, 0x53, 9, 0x5A, 3])
assert(MerachMotionCommand.stop == [2, 0x53, 3, 0x50, 3])
for frame in [MerachMotionCommand.start, MerachMotionCommand.stop] {
    assert(frame[1..<(frame.count - 2)].reduce(UInt8(0), ^) == frame[frame.count - 2])
}
var starting = WorkoutMotionTransition(kind: .start, deadline: 15)
assert(!starting.observe(machineState: 3)) // Before write confirmation.
starting.writeConfirmed = true
assert(!starting.observe(machineState: 2)) // Countdown doesn't start timing.
assert(!starting.observe(machineState: 3))
assert(starting.observe(machineState: 3))
assert(!starting.timedOut(at: 14.99) && starting.timedOut(at: 15))
var stopping = WorkoutMotionTransition(kind: .stop, deadline: 15)
stopping.writeConfirmed = true
assert(!stopping.observe(machineState: 2)) // Countdown isn't stopped.
assert(!stopping.observe(machineState: 3))
assert(!stopping.observe(machineState: 0x0A))
assert(!stopping.observe(machineState: 3)) // Intervening motion resets confirmation.
assert(!stopping.observe(machineState: 0x0A))
assert(stopping.observe(machineState: 0x0A))
assert(starting.id != stopping.id)
let segment = WorkoutRecord(title: "duplicates", running: false,
    intervals: [RecordedInterval(start: start, end: start.addingTimeInterval(60), duration: 60),
                RecordedInterval(start: start.addingTimeInterval(120), end: start.addingTimeInterval(180), duration: 60)])
assert(segment.mayDuplicate(start: start, end: start.addingTimeInterval(180)))
assert(!segment.mayDuplicate(start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))) // Gap only.
assert(!segment.mayDuplicate(start: start.addingTimeInterval(180), end: start.addingTimeInterval(240)))
assert(!segment.mayDuplicate(start: start, end: start.addingTimeInterval(10)))
let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let imported = try PlanImportDocument.decode(fixture, firstID: 10)
assert(imported.count == 1 && imported[0].duration == 180 && imported[0].id == 10)
assert(imported[0].steps.map(\.start) == [0, 60, 120])
assert(imported[0].steps.map(\.incline) == [0, 1, 0])
var document = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
func rejected(_ object: [String: Any]) -> Bool {
    do { _ = try PlanImportDocument.decode(JSONSerialization.data(withJSONObject: object), firstID: 10); return false }
    catch { return true }
}
var badVersion = document; badVersion["version"] = 2; assert(rejected(badVersion))
var badFormat = document; badFormat["format"] = "csv"; assert(rejected(badFormat))
var batch = document["plans"] as! [[String: Any]]
var invalid = batch[0]
var badSteps = invalid["steps"] as! [[String: Any]]
badSteps[0]["durationSeconds"] = 0
invalid["steps"] = badSteps
batch.append(invalid); document["plans"] = batch; assert(rejected(document))
badSteps[0]["durationSeconds"] = "60"; invalid["steps"] = badSteps; document["plans"] = [invalid]; assert(rejected(document))
badSteps[0]["durationSeconds"] = 60; badSteps[0]["speedKmh"] = 5.15; invalid["steps"] = badSteps; document["plans"] = [invalid]; assert(rejected(document))
badSteps[0]["speedKmh"] = 5.1; badSteps[0]["inclinePercent"] = 26; invalid["steps"] = badSteps; document["plans"] = [invalid]; assert(rejected(document))
badSteps[0]["inclinePercent"] = 0; badSteps[0].removeValue(forKey: "title"); invalid["steps"] = badSteps; document["plans"] = [invalid]; assert(rejected(document))
document["plans"] = []; assert(rejected(document))
do { _ = try PlanImportDocument.decode(Data(repeating: 32, count: 1_048_577), firstID: 10); assertionFailure() } catch {}
print("Passed: FTMS, accounting, plan validation, motion confirmation, overlap review and batch JSON import.")

'''
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / "main.swift"
    path.write_text("import Foundation\n" + models + data + importer + checks)
    subprocess.run(["swift", str(path), str(root / "Examples/plan-import.json")], check=True)
