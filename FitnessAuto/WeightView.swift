import SwiftUI
import UIKit

struct WeightView: View {
    @EnvironmentObject private var scale: ScaleBluetooth
    @EnvironmentObject private var health: WeightHealthStore
    private var height: Double? {
        guard let value = health.profileHeight, (90...240).contains(value) else { return nil }
        return value
    }
    private var bmi: String {
        guard let height, let reading = scale.reading,
              let value = ScaleReading.bmi(weight: reading.kilograms, heightCm: height) else { return "—" }
        return String(format: "%.1f", value)
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label("沃莱体脂秤", systemImage: "scalemass").font(.headline)
                        Spacer()
                        Button { scale.stop(); scale.start() } label: {
                            ConnectionBadge(title: scale.connectionState == .idle ? "等待连接" : scale.connectionButtonTitle,
                                            connected: scale.active, connecting: scale.connectionState == .connecting)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(scale.active || scale.connectionState == .scanning || scale.connectionState == .connecting)
                        .accessibilityIdentifier("scaleConnection")
                        .accessibilityHint("体脂秤自动连接；连接失败时可点击重试")
                        .accessibilityValue(scale.status)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        MetricTile(title: "本次体重", value: scale.reading.map { String(format: "%.2f", $0.kilograms) } ?? "—", unit: "kg", icon: "scalemass")
                            .accessibilityIdentifier("weightCurrentValue")
                        MetricTile(title: "BMI", value: bmi, unit: "", icon: "figure.stand")
                            .accessibilityIdentifier("weightCurrentBMI")
                    }
                }.padding(.vertical, 8)
                    .listRowSeparator(.hidden)
            }
            Section("体重趋势") {
                WeightTrendView(records: scale.records)
            }
            Section("测量记录") {
                if scale.records.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("还没有测量记录", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                        Text("连接秤完成测量后，体重与 BMI 会保存在这里。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                ForEach(scale.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(String(format: "%.2f kg", record.kilograms)).font(.headline)
                            Spacer()
                            if let bmi = record.bmi { Text(String(format: "BMI %.1f", bmi)) }
                        }.monospacedDigit()
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(health.savedText(record)) {
                            Task { await health.save(record) }
                        }.disabled(health.saved(record) || health.busy)
                    }
                }.onDelete(perform: deleteRecords)
            }
        }
        .appListStyle()
        .navigationTitle("体重测量")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deleteRecords(at offsets: IndexSet) {
        let records = offsets.compactMap { scale.records.indices.contains($0) ? scale.records[$0] : nil }
        Task {
            for record in records { await health.delete(record) }
            // New measurements may arrive while HealthKit deletion is pending.
            scale.delete(ids: Set(records.map(\.id)))
        }
    }
}

/// Explicit wheel layout keeps long year lists scrollable and independent of live BLE updates.
struct BirthMonthPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    @State private var month: Int
    private let years: ClosedRange<Int>
    private let save: (Int, Int) -> Void

    init(year: Int, month: Int, save: @escaping (Int, Int) -> Void) {
        let currentYear = Calendar.current.component(.year, from: Date())
        years = (currentYear - 101)...(currentYear - 10)
        _year = State(initialValue: years.contains(year) ? year : currentYear - 30)
        _month = State(initialValue: (1...12).contains(month) ? month : 1)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    Picker("出生年份", selection: $year) {
                        ForEach(years, id: \.self) { year in Text("\(String(year)) 年").tag(year) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    Picker("出生月份", selection: $month) {
                        ForEach(1...12, id: \.self) { month in Text("\(month) 月").tag(month) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                    .clipped()
                }
                .frame(height: 216)
                Text("分别上下滚动年份和月份，点击完成保存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("出生年月")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save(year, month); dismiss() }
                }
            }
        }
        .presentationDetents([.height(360), .large])
        .presentationDragIndicator(.visible)
    }
}
