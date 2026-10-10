import SwiftUI
import Charts

enum WorkoutTrendMetric: String, CaseIterable, Identifiable {
    case duration = "时长", distance = "距离", energy = "消耗热量"
    var id: String { rawValue }
    var unit: String {
        switch self { case .duration: return "分钟"; case .distance: return "km"; case .energy: return "kcal" }
    }
    func value(_ record: WorkoutRecord) -> Double? {
        switch self {
        case .duration: return record.duration / 60
        case .distance: return record.distanceMeters.map { $0 / 1000 }
        case .energy: return record.energyKcal
        }
    }
}

struct WeightTrendView: View {
    let records: [WeightRecord]
    var body: some View {
        TrendChartView(samples: records.map { TrendSample(date: $0.date, value: $0.kilograms) },
                       title: "体重", unit: "kg", reduction: .average)
    }
}
struct WorkoutTrendView: View {
    let records: [WorkoutRecord]
    @State private var metric: WorkoutTrendMetric = .duration
    var body: some View {
        VStack(spacing: 16) {
            Picker("运动指标", selection: $metric) {
                ForEach(WorkoutTrendMetric.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            TrendChartView(samples: records.compactMap { record in
                guard let date = record.start, let value = metric.value(record) else { return nil }
                return TrendSample(date: date, value: value)
            }, title: metric.rawValue, unit: metric.unit, reduction: .sum)
            .id(metric)
        }
    }
}

struct TrendChartView: View {
    let samples: [TrendSample]
    let title: String
    let unit: String
    let reduction: TrendSeries.Reduction
    @State private var period: TrendPeriod = .week
    @State private var offset = 0
    @State private var selected: Date?
    private var interval: DateInterval { period.interval(offset: offset) }
    private var points: [TrendPoint] { TrendSeries.points(samples, period: period, interval: interval, reduction: reduction) }
    private var selectedPoint: TrendPoint? { points.first { $0.id == selected } }
    private var yRange: ClosedRange<Double> {
        let low = points.map(\.value).min() ?? 0
        let high = points.map(\.value).max() ?? 1
        let padding = max((high - low) * 0.2, reduction == .average ? 0.5 : 1)
        return (reduction == .sum ? 0 : max(0, low - padding))...max(high + padding, 1)
    }
    private var rangeLabel: String {
        if period == .day { return interval.start.formatted(.dateTime.year().month().day()) }
        if period == .month { return interval.start.formatted(.dateTime.year().month()) }
        let last = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return interval.start.formatted(.dateTime.month().day()) + " – " + last.formatted(.dateTime.month().day())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("时间维度", selection: $period) {
                ForEach(TrendPeriod.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Button { offset -= 1; selected = nil } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("上一\(period.rawValue)")
                Spacer(minLength: 0)
                Text(rangeLabel).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Button { offset += 1; selected = nil } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(offset >= 0).accessibilityLabel("下一\(period.rawValue)")
            }
            if points.isEmpty {
                ContentUnavailableView("这段时间暂无数据", systemImage: "chart.xyaxis.line",
                                       description: Text("可切换时间维度或查看上一段时间。"))
                    .frame(minHeight: 220)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("日期", point.date), y: .value(title, point.value))
                            .foregroundStyle(AppDesign.accent)
                        PointMark(x: .value("日期", point.date), y: .value(title, point.value))
                            .foregroundStyle(AppDesign.accent).symbolSize(point.id == selected ? 100 : 45)
                    }
                    if let point = selectedPoint {
                        RuleMark(x: .value("选中日期", point.date)).foregroundStyle(.secondary.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartXScale(domain: interval.start...interval.end)
                .chartYScale(domain: yRange)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: period == .day ? 4 : 5)) { value in
                        AxisGridLine(); AxisTick()
                        if let date = value.as(Date.self) {
                            AxisValueLabel { Text(date, format: period == .day ? .dateTime.hour().minute() : .dateTime.month().day()) }
                        }
                    }
                }
                .chartYAxisLabel("\(title)（\(unit)）")
                .frame(height: 240)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                guard let frame = proxy.plotFrame else { return }
                                let origin = geometry[frame].origin
                                let nearest = points.min { a, b in
                                    distance(a, proxy: proxy, origin: origin, tap: tap.location) < distance(b, proxy: proxy, origin: origin, tap: tap.location)
                                }
                                selected = nearest?.id
                            })
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let point = selectedPoint {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(point.date, format: period == .day ? .dateTime.month().day().hour().minute() : .dateTime.month().day())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.2f %@", point.value, unit)).font(.headline).monospacedDigit()
                            Text("\(point.count) 条记录" + (period == .day ? "" : reduction == .average ? " · 日均值" : " · 当日合计"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.leading, 12).allowsHitTesting(false)
                    }
                }
            }
            Text(period == .day ? "点击数据点查看详情。" : reduction == .average ? "按日展示体重均值，点击数据点查看详情。" : "按日汇总有数据的运动记录，点击数据点查看详情。缺失的距离或热量不计入。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: period) { _, _ in offset = 0; selected = nil }
        .onChange(of: points) { _, updated in if !updated.contains(where: { $0.id == selected }) { selected = nil } }
    }
    private func distance(_ point: TrendPoint, proxy: ChartProxy, origin: CGPoint, tap: CGPoint) -> Double {
        guard let x = proxy.position(forX: point.date), let y = proxy.position(forY: point.value) else { return .infinity }
        return hypot(Double(x + origin.x - tap.x), Double(y + origin.y - tap.y))
    }
}
