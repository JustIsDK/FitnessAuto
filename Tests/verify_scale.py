"""Exercise the actual A1 Swift decoder using verified capture packets."""
import pathlib
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'TreadmillFTMSProbe/ScaleProtocol.swift').read_text()
checks = r'''
func packet(_ hex: String) -> Data { Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! }) }
let live = packet("AC 29 00 69 45 96 02 00 05 40 00 64 00 00 00 00 00 29 D5 0D")
let locked = packet("AC 29 80 69 45 96 02 00 05 40 00 64 00 00 00 00 00 29 D5 0D")
let final = packet("AC 29 02 00 01 BF 01 96 01 80 69 45 96 00 00 00 00 29 D6 1D")
assert(ScaleReading.decode(live)!.kilograms == 83.35)
assert(!ScaleReading.decode(live)!.stable)
assert(ScaleReading.decode(locked)!.stable)
let result = ScaleReading.decode(final)!
assert(result.kilograms == 83.35 && result.stable)
assert(result.resistance1 == 447 && result.resistance2 == 406)
for count in 0..<20 { assert(ScaleReading.decode(Data(final.prefix(count))) == nil) }
var bad = live; bad[5] ^= 1; assert(ScaleReading.decode(bad) == nil)
bad = live; bad[0] = 0xAF; assert(ScaleReading.decode(bad) == nil)
assert(ScaleReading.decode(packet("AC 29 06 00 C6 4A FC A0 A7 32 DF 2B 12 89 35 86 A9 69 DF 1C")) == nil)
assert(abs(ScaleReading.bmi(weight: 83.35, heightCm: 178)! - 26.306) < 0.001)
assert(ScaleReading.bmi(weight: 83.35, heightCm: 0) == nil)
assert(ScaleReading.bmi(weight: .nan, heightCm: 178) == nil)
let ack = Array(ScaleReading.finalAcknowledgement)
assert(ack[2...18].reduce(0, { $0 + Int($1) }) & 255 == Int(ack[19]))
let record = WeightRecord(kilograms: result.kilograms, heightCm: 178, resistance1: 447, resistance2: 406)
let restored = try JSONDecoder().decode(WeightRecord.self, from: JSONEncoder().encode(record))
assert(restored.id == record.id && restored.bmi == record.bmi)
print("Scale protocol checks passed")
'''
with tempfile.TemporaryDirectory() as folder:
    path = pathlib.Path(folder)
    (path / 'main.swift').write_text(source + '\n' + checks)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'verify')], check=True)
    subprocess.run([str(path / 'verify')], check=True)
