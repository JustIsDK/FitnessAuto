"""Exercise actual Swift decoders and accounting without BLE/HealthKit mocks."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
bluetooth = (root / "TreadmillFTMSProbe/TreadmillBluetooth.swift").read_text()
models = bluetooth[bluetooth.index("struct WorkoutStep:"):bluetooth.index("final class TreadmillBluetooth:")]
data = (root / "TreadmillFTMSProbe/WorkoutData.swift").read_text()
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
print("Passed: FTMS offsets/truncation/sentinels, observed duration, gaps, counter resets, clock changes, plan validation and Codable round trips.")
'''
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / "main.swift"
    path.write_text("import Foundation\n" + models + data + checks)
    subprocess.run(["swift", str(path)], check=True)
