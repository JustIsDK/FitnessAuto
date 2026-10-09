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
// Independently captured second measurement, not used to fit a body-fat formula.
let final2 = packet("AC 29 02 00 01 B5 01 88 01 80 69 45 64 00 00 00 00 29 D6 13")
let second = ScaleReading.decode(final2)!
assert(second.kilograms == 83.3 && second.resistance1 == 437 && second.resistance2 == 392)
// Additional real notifications cover changing grams and both impedance fields.
let measured = ScaleReading.decode(packet("AC 29 02 00 01 AE 01 83 01 80 69 45 FA 00 00 00 00 29 D6 1D"))!
assert(measured.kilograms == 83.45 && measured.resistance1 == 430 && measured.resistance2 == 387)
let latest = ScaleReading.decode(packet("AC 29 02 00 01 A5 01 7A 01 80 69 46 90 00 00 00 00 29 D6 02"))!
assert(latest.kilograms == 83.6 && latest.stable && latest.resistance1 == 421 && latest.resistance2 == 378)
// Screen and notification explicitly paired by the user; fat is not yet decoded.
let paired = ScaleReading.decode(packet("AC 29 02 00 01 A8 01 7E 01 80 69 46 5E 00 00 00 00 29 D6 17"))!
assert(paired.kilograms == 83.55 && paired.stable && paired.resistance1 == 424 && paired.resistance2 == 382)
let app1904 = ScaleReading.decode(packet("AC 29 02 00 01 AB 01 80 01 80 69 47 26 00 00 00 00 29 D6 05"))!
assert(app1904.kilograms == 83.75 && app1904.resistance1 == 427 && app1904.resistance2 == 384)
let capture3 = ScaleReading.decode(packet("AC 29 02 00 01 B1 01 86 01 80 69 47 26 00 00 00 00 29 D6 11"))!
assert(capture3.kilograms == 83.75 && capture3.stable && capture3.resistance1 == 433 && capture3.resistance2 == 390)
let profile = ScaleProfile(heightCm: 178, age: 34, male: true, referenceKg: 83.45)
let initialization = profile.initialization(at: Date(timeIntervalSince1970: Double(0x6AC8B8F7)))
assert(initialization == [
    packet("AC 27 08 6A C8 B8 F7 20 00 00 00 00 00 00 00 00 00 00 DF E8"),
    packet("AC 27 01 00 01 B2 20 99 22 01 00 00 00 00 00 00 00 00 D1 61"),
    packet("AC 27 6A C8 B8 F7 20 00 01 B2 20 99 22 01 13 88 03 00 D0 FE"),
    packet("AC 27 06 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 DF E5")])
let changed = ScaleProfile(heightCm: 175, age: 40, male: false, referenceKg: 70)
let changedPackets = changed.initialization(at: Date(timeIntervalSince1970: 1234))
assert(changedPackets.count == 4 && changedPackets != initialization)
for packet in changedPackets {
    let b = Array(packet)
    assert(b.count == 20 && b[2...18].reduce(0, { $0 + Int($1) }) & 255 == Int(b[19]))
}
assert(ScaleProfile(heightCm: 178, age: 34, male: true, referenceKg: .nan).initialization().isEmpty)
assert(profile.initialization(at: Date(timeIntervalSince1970: -1)).isEmpty)
assert(ScaleProfile.closeReport == packet("AC 27 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 DF E6"))
let chunk = packet("AC 29 06 04 89 0F BA F6 33 F0 AA 9D 00 00 00 00 00 00 DF 1B")
assert(ScaleProfile.reportChunkIndex(chunk) == 4)
var corrupt = chunk; corrupt[4] ^= 1
assert(ScaleProfile.reportChunkIndex(corrupt) == nil)
assert(result.hasImpedance && second.hasImpedance)
assert(!ScaleReading.decode(live)!.hasImpedance)
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
func date(_ year: Int, _ month: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: 1))!
}
assert(ScaleBirthMonth.age(year: 1992, month: 10, at: date(2026, 9), calendar: calendar) == 33)
assert(ScaleBirthMonth.age(year: 1992, month: 10, at: date(2026, 10), calendar: calendar) == 34)
assert(ScaleBirthMonth.age(year: 1992, month: 10, at: date(2027, 10), calendar: calendar) == 35)
assert(ScaleBirthMonth.age(year: 0, month: 10, at: date(2026, 10), calendar: calendar) == nil)
assert(ScaleBirthMonth.age(year: 1992, month: 0, at: date(2026, 10), calendar: calendar) == nil)
assert(ScaleBirthMonth.age(year: 2030, month: 10, at: date(2026, 10), calendar: calendar) == nil)
print("Scale protocol checks passed")
'''
with tempfile.TemporaryDirectory() as folder:
    path = pathlib.Path(folder)
    (path / 'main.swift').write_text(source + '\n' + checks)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'verify')], check=True)
    subprocess.run([str(path / 'verify')], check=True)
