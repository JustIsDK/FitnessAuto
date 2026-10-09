import Foundation

enum MerachMotionCommand {
    // Start/stop frames observed in the official APP capture on this device.
    static let start: [UInt8] = [0x02, 0x53, 0x09, 0x5A, 0x03]
    static let stop: [UInt8] = [0x02, 0x53, 0x03, 0x50, 0x03]
}

struct WorkoutMotionTransition {
    enum Kind { case start, stop }
    let id = UUID()
    let kind: Kind
    let deadline: Double
    var writeConfirmed = false
    private var matchingReports = 0

    init(kind: Kind, deadline: Double) {
        self.kind = kind
        self.deadline = deadline
    }
    mutating func observe(machineState: UInt8) -> Bool {
        guard writeConfirmed else { return false }
        if kind == .start ? machineState == 0x03 : machineState == 0x0A { matchingReports += 1 }
        else { matchingReports = 0 }
        return matchingReports >= 2
    }
    func timedOut(at uptime: Double) -> Bool { uptime >= deadline }
}

/// Bluetooth SIG FTMS Treadmill Data (2ACD). Private counters are deliberately
/// not used until their units have been verified against this treadmill.
struct TreadmillMetrics {
    var speed: Double?
    var distanceMeters: Double?
    var energyKcal: Double?
    var elapsedSeconds: Int?

    static func parse(_ data: Data) -> TreadmillMetrics? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let flags = Int(bytes[0]) | Int(bytes[1]) << 8
        guard flags & 0xE000 == 0 else { return nil }
        var offset = 2
        func read(_ count: Int) -> Int? {
            guard offset + count <= bytes.count else { return nil }
            var value = 0
            for i in 0..<count { value |= Int(bytes[offset + i]) << (8 * i) }
            offset += count
            return value
        }
        var result = TreadmillMetrics()
        if flags & 1 == 0 {
            guard let raw = read(2) else { return nil }
            if raw != 0xFFFF { result.speed = Double(raw) / 100 }
        }
        if flags & 2 != 0 { guard read(2) != nil else { return nil } }
        if flags & 4 != 0 {
            guard let raw = read(3) else { return nil }
            if raw != 0xFFFFFF { result.distanceMeters = Double(raw) }
        }
        for (flag, size) in [(3, 4), (4, 4), (5, 1), (6, 1)] {
            if flags & (1 << flag) != 0 { guard read(size) != nil else { return nil } }
        }
        if flags & (1 << 7) != 0 {
            guard let raw = read(2), read(3) != nil else { return nil }
            if raw != 0xFFFF { result.energyKcal = Double(raw) }
        }
        for flag in [8, 9] {
            if flags & (1 << flag) != 0 { guard read(1) != nil else { return nil } }
        }
        if flags & (1 << 10) != 0 {
            guard let raw = read(2) else { return nil }
            if raw != 0xFFFF { result.elapsedSeconds = raw }
        }
        if flags & (1 << 11) != 0 { guard read(2) != nil else { return nil } }
        if flags & (1 << 12) != 0 { guard read(4) != nil else { return nil } }
        return result
    }
}

struct RecordedInterval: Codable {
    var start: Date
    var end: Date
    var duration: Double
}

struct WorkoutRecord: Identifiable, Codable {
    var id = UUID()
    var title: String
    var running: Bool
    var intervals: [RecordedInterval] = []
    var distanceMeters: Double?
    var energyKcal: Double?
    var healthSaved = false
    var duration: Double { intervals.reduce(0) { $0 + $1.duration } }
    var start: Date? { intervals.first?.start }
    var end: Date? { intervals.last?.end }

    func mayDuplicate(start otherStart: Date, end otherEnd: Date) -> Bool {
        guard duration > 0, otherEnd > otherStart else { return false }
        let overlap = intervals.reduce(0.0) { result, interval in
            result + max(0, min(interval.end, otherEnd).timeIntervalSince(max(interval.start, otherStart)))
        }
        // This is a review trigger, not a claim that the workouts are identical.
        return overlap >= min(30, max(1, duration / 2))
    }
}

/// Only counts intervals with successive confirmed running status <= 3 seconds
/// apart. Reconnects, background time, countdown and stale data add no time.
struct WorkoutAccumulator {
    var record: WorkoutRecord
    private var lastObservation: (date: Date, uptime: Double)?
    private var distanceBaseline: (value: Double, uptime: Double)?
    private var energyBaseline: (value: Double, uptime: Double)?

    mutating func observe(date: Date, uptime: Double) {
        defer { lastObservation = (date, uptime) }
        guard let previous = lastObservation else { return }
        let delta = uptime - previous.uptime
        guard delta > 0, delta <= 3, date > previous.date,
              abs(date.timeIntervalSince(previous.date) - delta) < 1 else {
            distanceBaseline = nil
            energyBaseline = nil
            return
        }
        if let last = record.intervals.last, abs(last.end.timeIntervalSince(previous.date)) < 0.01 {
            let index = record.intervals.count - 1
            record.intervals[index].end = date
            record.intervals[index].duration += delta
        } else {
            record.intervals.append(RecordedInterval(start: previous.date, end: date, duration: delta))
        }
    }

    mutating func metrics(_ metrics: TreadmillMetrics, uptime: Double) {
        guard let observation = lastObservation, uptime - observation.uptime < 3 else {
            distanceBaseline = nil; energyBaseline = nil; return
        }
        if let value = metrics.distanceMeters {
            if let base = distanceBaseline {
                let dt = uptime - base.uptime, delta = value - base.value
                if dt > 0, dt <= 3, delta >= 0, delta <= dt * 6 + 20 {
                    record.distanceMeters = (record.distanceMeters ?? 0) + delta
                }
            }
            distanceBaseline = (value, uptime)
        }
        if let value = metrics.energyKcal {
            if let base = energyBaseline {
                let dt = uptime - base.uptime, delta = value - base.value
                if dt > 0, dt <= 3, delta >= 0, delta <= dt + 5 {
                    record.energyKcal = (record.energyKcal ?? 0) + delta
                }
            }
            energyBaseline = (value, uptime)
        }
    }
}
