"""Pytest gate for the training layout and workout sharing changes."""

from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def test_training_layout_contract():
    source = (ROOT / "FitnessAuto/ContentView.swift").read_text()

    assert 'case .starting: return nil' in source
    assert 'trainingNextStageTarget' in source
    assert 'StageProgressView' in source
    assert 'trainingProgressStage-' in source
    assert '.disabled(state != .running || !canJumpNext)' in source
    assert 'Button("下一阶段"' not in source
    assert "等待跑步机倒计时及运行确认" not in source


def test_workout_share_contract():
    source = (ROOT / "FitnessAuto/WorkoutShare.swift").read_text()

    for text in ["WorkoutRecordDetailView", "WorkoutShareCard", "ImageRenderer",
                 "UIActivityViewController", "距离", "消耗热量", "workoutShare"]:
        assert text in source
    assert "record.distanceText" in source
    assert "record.energyText" in source


def test_production_progress_and_record_formatting():
    bluetooth = (ROOT / 'FitnessAuto/TreadmillBluetooth.swift').read_text()
    models = bluetooth[bluetooth.index('struct WorkoutStep:'):bluetooth.index('final class TreadmillBluetooth:')]
    source = (ROOT / 'FitnessAuto/WorkoutData.swift').read_text()
    checks = r'''
let plan = WorkoutPlan(id: 1, title: "test", steps: [
    WorkoutStep(id: 0, start: 0, duration: 120, title: "one", speed: 3, incline: 0),
    WorkoutStep(id: 1, start: 120, duration: 1, title: "two", speed: 6, incline: 2),
    WorkoutStep(id: 2, start: 121, duration: 1079, title: "three", speed: 4, incline: 1)])
assert(plan.progress(at: 0) == 0 && plan.progress(at: 120) == 0.1)
assert(plan.progress(at: 1200) == 1 && plan.progress(at: 1500) == 1)
assert(plan.progress(at: -20) == 0)
let markers = plan.progressMarkers(width: 300)
assert(markers.map(\.id) == [1] && markers[0].start == 120)
assert(plan.progressMarkers(width: 0).isEmpty)
assert(WorkoutPlan(id: 2, title: "empty", steps: []).progress(at: 0) == 0)
var record = WorkoutRecord(title: "M4", running: false)
assert(record.distanceText == "—" && record.energyText == "—")
assert(record.durationText == "00:00" && record.activityTitle == "室内步行")
let start = Date(timeIntervalSince1970: 1000)
record.intervals = [RecordedInterval(start: start, end: start.addingTimeInterval(1688), duration: 1688)]
record.distanceMeters = 2460; record.energyKcal = 182
assert(record.durationText == "28:08" && record.distanceText == "2.46 km" && record.energyText == "182 kcal")
record.running = true; assert(record.activityTitle == "室内跑步")
assert(!record.startText.isEmpty)
'''
    with tempfile.TemporaryDirectory() as folder:
        script = Path(folder) / 'main.swift'
        script.write_text('import Foundation\n' + models + source + checks)
        subprocess.run(['swift', str(script)], cwd=ROOT, check=True, timeout=120)


def test_existing_swift_regressions():
    for script in ["Tests/verify_workout_data.py", "Tests/verify_training_sync.py"]:
        subprocess.run([sys.executable, str(ROOT / script)], cwd=ROOT, check=True)
