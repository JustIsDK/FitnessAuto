import SwiftUI
import UIKit

struct WeightView: View {
    @EnvironmentObject private var scale: ScaleBluetooth
    @EnvironmentObject private var health: WeightHealthStore
    @AppStorage("fitnessauto.weight.health.auto") private var autoHealth = true
    @AppStorage("fitnessauto.weight.heightCm") private var heightText = ""
    @AppStorage("fitnessauto.weight.birthYear") private var birthYear = 0
    @AppStorage("fitnessauto.weight.birthMonth") private var birthMonth = 0
    @AppStorage("fitnessauto.weight.sex") private var sex = -1
    @AppStorage("fitnessauto.weight.referenceKg") private var referenceText = ""
    @State private var showingBirthMonthPicker = false
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    private var height: Double? {
        guard let value = health.profileHeight, (90...240).contains(value) else { return nil }
        return value
    }
    private var age: Int? { ScaleBirthMonth.age(year: birthYear, month: birthMonth) }

    private var profile: ScaleProfile? {
        guard let height, height.rounded() == height, let age, sex == 0 || sex == 1,
              let reference = Double(referenceText) else { return nil }
        let profile = ScaleProfile(heightCm: Int(height), age: age, male: sex == 1,
                                   referenceKg: reference)
        return profile.valid ? profile : nil
    }
    var body: some View {
        List {
            Section {
                PageIntro(eyebrow: "BODY METRICS", title: "看见身体的变化。", subtitle: "每次测量，留下一份清晰的记录。")
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            Section {
                HStack {
                    Label("沃莱体脂秤", systemImage: "scalemass").font(.headline)
                    Spacer()
                    Button {
                        inputFocused = false
                        if scale.active { scale.stop() } else { scale.start(profile: profile) }
                    } label: {
                        Text(scale.active ? "断开" : "连接")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(scale.active ? AppDesign.accent : .secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background((scale.active ? AppDesign.accent : Color.secondary).opacity(0.12), in: Capsule())
                    }
                }.padding(.vertical, 4)
            }
            Section("本次测量") {
                MetricTile(title: "本次体重", value: scale.reading.map { String(format: "%.2f", $0.kilograms) } ?? "—", unit: "kg", icon: "scalemass")
                    .listRowSeparator(.hidden)
                Text(scale.reading?.stable == true ? "体重已稳定，已自动保存" : "等待体重稳定")
                    .font(.caption).foregroundStyle(.secondary)
                if let height, let reading = scale.reading, let bmi = ScaleReading.bmi(weight: reading.kilograms, heightCm: height) {
                    LabeledContent("BMI", value: String(format: "%.1f", bmi))
                } else { LabeledContent("BMI", value: "健康中有身高后计算") }
                Text("测量稳定后会自动保存；健康同步可在设置中管理。离开此页面或进入后台会断开体脂秤。")
                    .font(.footnote).foregroundStyle(.secondary)
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
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { inputFocused = false }
            }
        }
        .sheet(isPresented: $showingBirthMonthPicker) {
            BirthMonthPicker(year: birthYear, month: birthMonth) { year, month in
                birthYear = year
                birthMonth = month
            }
        }
        .alert(item: $health.duplicateReview) { review in
            Alert(title: Text("可能已有同一次测量"),
                  message: Text("苹果健康中发现时间和数值接近的记录，来源：\(review.sources)。是否仍然写入？"),
                  primaryButton: .cancel(Text("取消")),
                  secondaryButton: .default(Text("仍然写入")) {
                    Task { await health.save(review.record, allowDuplicate: true) }
                  })
        }
        .onAppear { health.refreshAuthorization() }
        .task { await health.refreshProfile() }
        .onChange(of: scale.reading) { _, reading in
            guard reading?.stable == true, scale.canSave else { return }
            scale.save(heightCm: height)
            if autoHealth, let record = scale.records.first {
                Task { await health.save(record, requestPermission: false) }
            }
        }
        .onDisappear { scale.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { scale.stop() }
            if phase == .active {
                health.refreshAuthorization()
                Task { await health.refreshProfile() }
            }
        }
    }
    private func profileInput(_ label: String, text: Binding<String>, unit: String,
                              keyboard: UIKeyboardType = .decimalPad) -> some View {
        HStack {
            Text(label)
            TextField("请输入", text: text).keyboardType(keyboard)
                .multilineTextAlignment(.trailing).focused($inputFocused)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func deleteRecords(at offsets: IndexSet) {
        let records = offsets.compactMap { scale.records.indices.contains($0) ? scale.records[$0] : nil }
        Task {
            for record in records { await health.delete(record) }
            scale.delete(at: offsets)
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
