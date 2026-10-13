"""Check the actual HealthKit callback wait without needing health permissions."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / "FitnessAuto/WorkoutRecorder.swift").read_text()
result = source[source.index("private final class HealthOperationResult"):source.index("struct HealthDuplicateReview")]
operation = source[source.index("    @MainActor private func healthOperation"):source.index("    @MainActor private func healthStep")]
operation = operation.replace("private func healthOperation", "func healthOperation")
checks = r'''
@main struct Checks {
    @MainActor static func main() async throws {
        let probe = Probe()
        let value: Int = try await probe.healthOperation("success") { finish in
            finish(.success(42))
            finish(.failure(NSError(domain: "late", code: 1)))
        }
        assert(value == 42)
        do {
            let _: Int = try await probe.healthOperation("failure") { finish in
                finish(.failure(NSError(domain: "expected", code: 7)))
                finish(.success(1))
            }
            assertionFailure("Should throw the first callback error")
        } catch { assert((error as NSError).code == 7) }

        var late: (@Sendable (Result<Int, Error>) -> Void)?
        var stopped = false
        do {
            let _: Int = try await probe.healthOperation("missing callback", onTimeout: { stopped = true }) { late = $0 }
            assertionFailure("Should time out")
        } catch { assert(error.localizedDescription.contains("超时")) }
        assert(stopped)
        late?(.success(99)) // A delayed callback must not resume the continuation again.
        await Task.yield()
        print("Health callback success, failure, timeout and late completion checks passed")
    }
}
'''
swift = "import Foundation\n" + result + "\nfinal class Probe { var status = \"\"\n" + operation + "}\n" + checks
with tempfile.TemporaryDirectory() as folder:
    path = pathlib.Path(folder)
    (path / "Checks.swift").write_text(swift)
    subprocess.run(["swiftc", "-parse-as-library", str(path / "Checks.swift"), "-o", str(path / "checks")], check=True)
    subprocess.run([str(path / "checks")], check=True, timeout=35)
