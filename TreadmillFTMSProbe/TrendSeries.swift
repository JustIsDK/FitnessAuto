import Foundation

enum TrendPeriod: String, CaseIterable, Identifiable {
    case day = "日", week = "周", month = "月"
    var id: String { rawValue }
    var component: Calendar.Component {
        switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month }
    }
    func interval(offset: Int, now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let anchor = calendar.dateInterval(of: component, for: now)!.start
        let date = calendar.date(byAdding: component, value: offset, to: anchor) ?? anchor
        return calendar.dateInterval(of: component, for: date)!
    }
}

struct TrendSample {
    let date: Date
    let value: Double
}
struct TrendPoint: Identifiable, Equatable {
    let date: Date
    let value: Double
    let count: Int
    var id: Date { date }
}
enum TrendSeries {
    enum Reduction { case average, sum }
    static func points(_ samples: [TrendSample], period: TrendPeriod, interval: DateInterval,
                       reduction: Reduction, calendar: Calendar = .current) -> [TrendPoint] {
        let filtered = samples.filter { $0.value.isFinite && $0.date >= interval.start && $0.date < interval.end }
        // Daily view preserves each measurement/session. Longer views aggregate
        // by local calendar day, including daylight-saving changes.
        let groups = Dictionary(grouping: filtered) {
            period == .day ? $0.date : calendar.startOfDay(for: $0.date)
        }
        return groups.map { date, values in
            let total = values.reduce(0) { $0 + $1.value }
            return TrendPoint(date: date, value: reduction == .average ? total / Double(values.count) : total, count: values.count)
        }.sorted { $0.date < $1.date }
    }
}
