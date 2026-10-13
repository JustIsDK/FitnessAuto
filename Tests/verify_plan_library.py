"""Check file staging, preview/commit, queue ordering, cancellation and persistence."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
bluetooth = (root / 'FitnessAuto/TreadmillBluetooth.swift').read_text()
models = bluetooth[bluetooth.index('struct WorkoutStep:'):bluetooth.index('final class TreadmillBluetooth:')]
library = (root / 'FitnessAuto/PlanLibrary.swift').read_text()
library = library[library.index('@MainActor'):library.index('private enum PlanLibrarySheet:')]
importer = (root / 'FitnessAuto/PlanImport.swift').read_text()
checks = r'''
@main struct Checks {
    @MainActor static func wait(_ library: PlanLibrary) async throws {
        for _ in 0..<200 {
            if library.pendingImports.allSatisfy({ !$0.receiving }) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        assertionFailure("Import never finished")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first.json")
        let second = root.appending(path: "second.json")
        let invalid = root.appending(path: "invalid.json")
        let oversized = root.appending(path: "oversized.json")
        let data = Data(FIXTURE.utf8)
        try data.write(to: first); try data.write(to: second)
        try Data("{}".utf8).write(to: invalid)
        try Data(repeating: 32, count: 1_048_577).write(to: oversized)
        let directory = root.appending(path: "library")
        let library = PlanLibrary(directory: directory)
        library.receiveImport(first)
        library.receiveImport(first) // Repeated URL event during this presentation is ignored.
        library.receiveImport(second)
        library.receiveImport(invalid)
        library.receiveImport(oversized)
        assert(library.pendingImports.count == 4)
        try await wait(library)
        assert(library.custom.isEmpty) // Preview must never mutate plans.
        assert(library.pendingImports[0].plans?.count == 2, "count=\(String(describing: library.pendingImports[0].plans?.count)), error=\(String(describing: library.pendingImports[0].failure))")
        assert(library.pendingImports[1].plans?.count == 2)
        assert(library.pendingImports[2].failure != nil)
        assert(library.pendingImports[3].failure?.contains("1 MB") == true)
        let firstID = library.pendingImports[0].id
        let secondID = library.pendingImports[1].id
        assert(!library.confirmImport(secondID)) // Queue must retain receive order.
        // IDs are allocated at commit after edits made while the preview was open.
        let draft = WorkoutPlan(id: 2_000_000_000_000, title: "existing", steps: library.pendingImports[0].plans![0].steps)
        try library.save(draft)
        assert(library.confirmImport(firstID))
        assert(!library.confirmImport(firstID))
        assert(library.custom.count == 3 && Set(library.custom.map(\.id)).count == 3)
        assert(library.custom.dropFirst().allSatisfy { $0.id > draft.id })
        assert(library.pendingImports.first?.id == secondID)
        let restored = PlanLibrary(directory: directory)
        assert(restored.custom.count == 3 && restored.pendingImports.count == 3)
        assert(restored.pendingImports.first?.plans?.count == 2)
        restored.discardImport(secondID)
        assert(restored.pendingImports.count == 2 && restored.custom.count == 3)
        assert(!FileManager.default.fileExists(atPath: directory.appending(path: "Imports/\(secondID).json").path))
        for request in restored.pendingImports { restored.discardImport(request.id) }
        // A later deliberate open of the same file may create another copy after confirmation.
        restored.receiveImport(first); try await wait(restored)
        assert(restored.confirmImport(restored.pendingImports[0].id))
        assert(restored.custom.count == 5 && Set(restored.custom.map(\.id)).count == 5)
        let snapshot = restored.custom.map(\.id)
        let missing = root.appending(path: "missing.json")
        restored.receiveImport(missing); try await wait(restored)
        assert(restored.pendingImports[0].failure != nil)
        assert(restored.custom.map(\.id) == snapshot)
        // Cancellation while the background read is pending must clean up its eventual file.
        let cancellation = PlanLibrary(directory: root.appending(path: "cancel"))
        cancellation.receiveImport(first)
        let cancelledID = cancellation.pendingImports[0].id
        cancellation.discardImport(cancelledID)
        try await Task.sleep(nanoseconds: 200_000_000)
        assert(cancellation.pendingImports.isEmpty && cancellation.custom.isEmpty)
        assert(!FileManager.default.fileExists(atPath: root.appending(path: "cancel/Imports/\(cancelledID).json").path))
        // Simulate a crash between the saved plans and cleanup of the commit journal.
        let committed = PendingPlanImport(id: UUID(), fileName: "already.json", sourceKey: "already",
            plans: [], committedPlanIDs: Array(snapshot.suffix(2)))
        try JSONEncoder().encode([committed]).write(to: directory.appending(path: "pending-imports.json"))
        let recovered = PlanLibrary(directory: directory)
        assert(recovered.pendingImports.isEmpty && recovered.custom.map(\.id) == snapshot)
        // An unwritable destination keeps the pending preview and existing library.
        let broken = root.appending(path: "broken")
        let failing = PlanLibrary(directory: broken)
        failing.receiveImport(first); try await wait(failing)
        try FileManager.default.createDirectory(at: broken.appending(path: "plans.json"), withIntermediateDirectories: true)
        assert(!failing.confirmImport(failing.pendingImports[0].id))
        assert(failing.custom.isEmpty && failing.pendingImports.count == 1 && failing.error != nil)
        print("Passed: bounded file reads, preview, deduplication, queued batches, fresh IDs, cancel, persistence and save failure.")
    }
}
'''
import json
fixture_document = json.loads((root / 'Examples/plan-import.json').read_text())
fixture_document['plans'].append(dict(fixture_document['plans'][0], title='第二套计划'))
fixture = json.dumps(fixture_document, ensure_ascii=False)
# Swift raw literal avoids shell or Python escaping of fixture contents.
checks = checks.replace('FIXTURE', '#"' + fixture.replace('\n', '') + '"#')
with tempfile.TemporaryDirectory() as tmp:
    source = pathlib.Path(tmp) / 'Checks.swift'
    source.write_text('import Foundation\nimport Combine\nimport CoreData\n' + models + importer + library + checks)
    executable = pathlib.Path(tmp) / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True)
    if result.returncode:
        import re
        match = re.search(r'Checks.swift:(\d+)', result.stderr)
        if match:
            line = int(match.group(1))
            print(f"Failed assertion: {source.read_text().splitlines()[line - 1]}")
        raise RuntimeError(result.stderr)
    print(result.stdout, end='')
