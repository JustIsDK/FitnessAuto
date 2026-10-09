"""Verify the actual Swift presets against the saved training tables."""
import csv
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / "TreadmillFTMSProbe/TreadmillBluetooth.swift").read_text()
model = source[source.index("struct WorkoutStep:"):source.index("final class TreadmillBluetooth:")]
checks = r'''
for plan in WorkoutPlan.presets {
    assert(plan.stepIndex(at: -1) == nil)
    assert(plan.stepIndex(at: plan.duration) == nil)
    for (index, step) in plan.steps.enumerated() {
        assert(plan.stepIndex(at: step.start) == index)
        assert(plan.stepIndex(at: step.start + step.duration - 1) == index)
        print("\(plan.id),\(step.start),\(step.duration),\(step.title),\(step.speed),\(step.incline)")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / "main.swift"
    path.write_text("import Foundation\n" + model + checks)
    result = subprocess.run(["swift", str(path)], check=True, text=True, capture_output=True)
actual = list(csv.reader(result.stdout.splitlines()))
expected = []
def seconds(value):
    minutes, seconds = map(int, value.split(":"))
    return minutes * 60 + seconds
for plan_id in (1, 2):
    with (root / f"Tests/Fixtures/plan{plan_id}.csv").open(encoding="utf-8-sig") as file:
        for row in csv.DictReader(file):
            start = seconds(row["开始"])
            expected.append([str(plan_id), str(start), str(seconds(row["结束"]) - start),
                             row["阶段"], row["速度(km/h)"], row["坡度(%)"]])
assert actual == expected, (actual, expected)
assert sum(int(row[2]) for row in actual if row[0] == "1") == 1800
assert sum(int(row[2]) for row in actual if row[0] == "2") == 2580
print("Passed: both plans match CSV, with correct phase boundaries and durations.")
