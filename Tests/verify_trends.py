"""Verify calendar boundaries and aggregation using the production Swift model."""
import pathlib
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'TreadmillFTMSProbe/TrendSeries.swift').read_text()
checks = r'''
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}
let interval = TrendPeriod.month.interval(offset: -1, now: date(2026, 3, 31), calendar: cal)
assert(interval.start == date(2026, 2, 1) && interval.end == date(2026, 3, 1))
let month = TrendPeriod.month.interval(offset: 0, now: date(2026, 3, 8), calendar: cal)
let samples = [TrendSample(date: date(2026, 3, 8, 12), value: 84),
               TrendSample(date: date(2026, 3, 8, 8), value: 82),
               TrendSample(date: date(2026, 3, 9), value: 85),
               TrendSample(date: month.end, value: 100),
               TrendSample(date: date(2026, 3, 10), value: .nan)]
let averages = TrendSeries.points(samples, period: .month, interval: month, reduction: .average, calendar: cal)
assert(averages.count == 2 && averages[0].value == 83 && averages[0].count == 2 && averages[1].value == 85)
let totals = TrendSeries.points(samples, period: .month, interval: month, reduction: .sum, calendar: cal)
assert(totals[0].value == 166 && totals[1].value == 85)
let day = TrendPeriod.day.interval(offset: 0, now: date(2026, 3, 8), calendar: cal)
assert(day.duration == 23 * 3600) // daylight-saving day
let daily = TrendSeries.points(samples, period: .day, interval: day, reduction: .average, calendar: cal)
assert(daily.count == 2 && daily[0].value == 82 && daily[1].value == 84)
assert(TrendSeries.points([], period: .week, interval: day, reduction: .sum, calendar: cal).isEmpty)
print("Passed: trend averages, totals, missing data, midnight, month navigation and DST.")
'''
with tempfile.TemporaryDirectory() as folder:
    path = pathlib.Path(folder)
    (path / 'main.swift').write_text(source + '\n' + checks)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'verify')], check=True)
    subprocess.run([str(path / 'verify')], check=True)
