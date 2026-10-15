"""Run only training, record deletion and file import checks on a dedicated simulator."""
import datetime
import json
import pathlib
import subprocess
import sys
import time
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
simulator = sys.argv[1] if len(sys.argv) >= 2 else sys.exit('Usage: python3 Tests/run_changed_ui.py SIMULATOR_UUID [TEST_METHOD ...] (dedicated test simulator)')
selected_tests = [f'-only-testing:EditorChecks/EditorChecks/{name}' for name in sys.argv[2:]]

def run(*args):
    return subprocess.check_output(args, text=True).strip()

stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
output = pathlib.Path('/private/tmp') / ('fitnessauto-changed-ui-' + stamp)
output.mkdir()
build = output / 'app-build'
with (output / 'build.log').open('w') as log:
    subprocess.run(['xcodebuild', '-project', str(root / 'FitnessAuto.xcodeproj'), '-scheme', 'FitnessAuto',
                    '-destination', f'platform=iOS Simulator,id={simulator}', '-derivedDataPath', str(build), 'build'],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
run('xcrun', 'simctl', 'install', simulator, str(build / 'Build/Products/Debug-iphonesimulator/FitnessAuto.app'))
container = pathlib.Path(run('xcrun', 'simctl', 'get_app_container', simulator, 'com.example.TreadmillFTMSProbe', 'data'))
subprocess.run(['xcrun', 'simctl', 'terminate', simulator, 'com.example.TreadmillFTMSProbe'], capture_output=True)
base = container / 'Library/Application Support/FitnessAuto'
base.mkdir(parents=True, exist_ok=True)
paths = [base / name for name in ['plans.json', 'pending-imports.json', 'workouts.json']]
backups = {path: path.read_bytes() if path.exists() else None for path in paths}
fixture = json.loads((root / 'Examples/plan-import.json').read_text())
fixture['plans'].append(dict(fixture['plans'][0]))
for index, plan in enumerate(fixture['plans']):
    plan['title'] = f'外部导入验证 {index + 1}'
pathlib.Path('/private/tmp/fitnessauto-external-ui.json').write_text(json.dumps(fixture, ensure_ascii=False))
pathlib.Path('/private/tmp/fitnessauto-invalid-ui.json').write_text('{}')
now = time.time() - 978307200
records = [dict(id=str(uuid.uuid4()), title=title, running=False,
                intervals=[dict(start=now-1800-i*3600, end=now-600-i*3600, duration=1200)],
                distanceMeters=1500, energyKcal=100, healthSaved=False)
           for i, title in enumerate(['删除交互验证', '保留记录验证', '分享交互验证'])]
try:
    paths[0].write_text('[]'); paths[1].write_text('[]'); paths[2].write_text(json.dumps(dict(records=records)))
    with (output / 'ui.log').open('w') as log:
        subprocess.run(['xcodebuild', '-project', str(root / 'Tests/UI/EditorChecks.xcodeproj'), '-scheme', 'EditorChecks',
                        '-destination', f'platform=iOS Simulator,id={simulator}', '-derivedDataPath', str(output / 'ui-build'),
                        '-resultBundlePath', str(output / 'checks.xcresult'), '-collect-test-diagnostics', 'never',
                        '-parallel-testing-enabled', 'NO', '-skip-testing:EditorChecks/EditorChecks/testWorkoutAutomaticSyncSetting',
                        *selected_tests, 'test'], stdout=log, stderr=subprocess.STDOUT, check=True)
finally:
    subprocess.run(['xcrun', 'simctl', 'terminate', simulator, 'com.example.TreadmillFTMSProbe'], capture_output=True)
    for path, data in backups.items():
        if data is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(data)
    print(f'Logs and screenshots: {output}', flush=True)
