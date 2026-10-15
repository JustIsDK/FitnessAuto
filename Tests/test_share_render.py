"""Render the production share card in a disposable iOS simulator, without BLE/HealthKit."""
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]


def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, **kwargs).strip()


def test_actual_share_png(tmp_path):
    runtime = next(item["identifier"] for item in json.loads(command("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
                   if item["name"].startswith("iOS ") and item["isAvailable"])
    device = command("xcrun", "simctl", "create", "FitnessAuto PNG pytest", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime)
    bundle = "com.fitnessauto.tests.sharerender"
    try:
        command("xcrun", "simctl", "boot", device)
        command("xcrun", "simctl", "bootstatus", device, "-b", timeout=120)
        app = tmp_path / "RenderCheck.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle, "CFBundleExecutable": "RenderCheck", "CFBundleName": "RenderCheck",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1", "CFBundlePackageType": "APPL",
            "LSRequiresIPhoneOS": True, "UILaunchScreen": {}, "UIDeviceFamily": [1], "MinimumOSVersion": "17.0",
        }))
        data_source = (ROOT / "FitnessAuto/WorkoutData.swift").read_text()
        (tmp_path / "Record.swift").write_text("import Foundation\n" + data_source[data_source.index("struct RecordedInterval:"):data_source.index("struct WorkoutAccumulator {")])
        shutil.copy(ROOT / "FitnessAuto/WorkoutShare.swift", tmp_path / "WorkoutShare.swift")
        design_source = (ROOT / "FitnessAuto/AppDesign.swift").read_text()
        (tmp_path / "Design.swift").write_text(design_source[:design_source.index("struct AppSectionTitle:")])
        (tmp_path / "Harness.swift").write_text(r'''
import SwiftUI
import UIKit


@MainActor func runChecks() {
            let directory = URL.documentsDirectory
            do {
                var normal = WorkoutRecord(title: "M4", running: false)
                normal.intervals = [RecordedInterval(start: Date(timeIntervalSince1970: 1760000000), end: Date(timeIntervalSince1970: 1760001688), duration: 1688)]
                normal.distanceMeters = 2460; normal.energyKcal = 182
                var missing = WorkoutRecord(title: "缺失距离热量", running: true)
                missing.intervals = normal.intervals
                var long = normal
                long.id = UUID(); long.title = String(repeating: "长计划标题", count: 60)
                var zero = WorkoutRecord(title: "零值", running: true)
                zero.distanceMeters = 0; zero.energyKcal = 0
                var report: [[String: Any]] = []
                for (name, record) in [("normal", normal), ("missing", missing), ("long", long), ("zero", zero)] {
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let before = try encoder.encode(record)
                    let first = try WorkoutShareRenderer.render(record: record)
                    let png = try Data(contentsOf: first)
                    guard let image = UIImage(data: png), image.cgImage?.width == 1080, image.cgImage?.height == 1350 else {
                        throw NSError(domain: "PNG dimensions", code: 1)
                    }
                    let second = try WorkoutShareRenderer.render(record: record)
                    guard png == (try Data(contentsOf: second)), before == (try encoder.encode(record)) else {
                        throw NSError(domain: "Share mutated record or repeated render changed", code: 2)
                    }
                    let output = directory.appending(path: name + ".png")
                    try png.write(to: output)
                    report.append(["name": name, "bytes": png.count, "width": 1080, "height": 1350,
                                   "type": record.activityTitle, "duration": record.durationText,
                                   "distance": record.distanceText, "energy": record.energyText])
                    try FileManager.default.removeItem(at: first)
                }
                try JSONSerialization.data(withJSONObject: report).write(to: directory.appending(path: "report.json"))
            } catch {
                try? String(describing: error).write(to: directory.appending(path: "error.txt"), atomically: true, encoding: .utf8)
            }
}
@main struct Checks: App {
    var body: some Scene { WindowGroup { Text("PNG renderer test").task { runChecks() } } }
}
''')
        sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
        command("xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-swift-version", "5",
                "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk,
                str(tmp_path / "Record.swift"), str(tmp_path / "Design.swift"), str(tmp_path / "WorkoutShare.swift"), str(tmp_path / "Harness.swift"),
                "-o", str(app / "RenderCheck"), timeout=90)
        command("codesign", "--force", "--sign", "-", str(app))
        command("xcrun", "simctl", "install", device, str(app))
        command("xcrun", "simctl", "launch", device, bundle)
        directory = Path(command("xcrun", "simctl", "get_app_container", device, bundle, "data")) / "Documents"
        for _ in range(150):
            if (directory / "report.json").exists() or (directory / "error.txt").exists():
                break
            time.sleep(0.1)
        assert not (directory / "error.txt").exists(), (directory / "error.txt").read_text() if (directory / "error.txt").exists() else ""
        assert (directory / "report.json").exists(), "Production ImageRenderer did not complete"
        report = json.loads((directory / "report.json").read_text())
        by_name = {item["name"]: item for item in report}
        assert by_name["normal"]["type"] == "室内步行"
        assert by_name["normal"]["duration"] == "28:08"
        assert by_name["normal"]["distance"] == "2.46 km"
        assert by_name["normal"]["energy"] == "182 kcal"
        assert by_name["missing"]["type"] == "室内跑步"
        assert by_name["missing"]["distance"] == by_name["missing"]["energy"] == "—"
        assert by_name["zero"]["distance"] == "0.00 km"
        assert by_name["zero"]["energy"] == "0 kcal"
        for item in report:
            png = (directory / (item["name"] + ".png")).read_bytes()
            assert png[:8] == b"\x89PNG\r\n\x1a\n"
            assert struct.unpack(">II", png[16:24]) == (1080, 1350)
            assert len(png) > 10000
            shutil.copy(directory / (item["name"] + ".png"), tmp_path / (item["name"] + ".png"))
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True)
