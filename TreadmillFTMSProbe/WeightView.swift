import SwiftUI
import UIKit

struct WeightView: View {
    @StateObject private var scale = ScaleBluetooth()
    @StateObject private var health = WeightHealthStore()
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
        guard let value = Double(heightText), (90...240).contains(value) else { return nil }
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
            Section("沃莱 · 蚂蚁阿福专用秤") {
                Text(scale.status).font(.subheadline)
                Text("请先退出蚂蚁阿福的秤连接页面，再踩秤唤醒。支持 AFU-WL-TZ-A1，无需在系统蓝牙列表中配对。")
                    .font(.footnote).foregroundStyle(.secondary)
                if scale.active {
                    Button("断开体脂秤") { scale.stop() }
                } else {
                    Button("连接体脂秤") { inputFocused = false; scale.stop(); scale.start(profile: profile) }
                }
            }
            Section("本次测量") {
                HStack(alignment: .firstTextBaseline) {
                    Text(scale.reading.map { String(format: "%.2f", $0.kilograms) } ?? "—")
                        .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("kg").foregroundStyle(.secondary)
                }
                Text(scale.reading?.stable == true ? "体重已稳定，可保存" : "等待体重稳定")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("身高")
                    TextField("输入身高", text: $heightText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($inputFocused)
                    Text("cm").foregroundStyle(.secondary)
                }
                if let height, let reading = scale.reading, let bmi = ScaleReading.bmi(weight: reading.kilograms, heightCm: height) {
                    LabeledContent("BMI", value: String(format: "%.1f", bmi))
                } else { LabeledContent("BMI", value: "填写身高后计算") }
                LabeledContent("体脂测量", value: scale.reading?.hasImpedance == true ? "已收到阻抗数据" : "尚未收到有效阻抗")
                LabeledContent("体脂率", value: scale.reading?.hasImpedance == true ? "数据已收到，算法待解析" : "等待测量数据")
                Text("BMI 根据体重和身高计算。体脂率的计算尚未验证，本版不显示估算值。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(scale.saved ? "本次测量已保存" : "保存本次测量") {
                    inputFocused = false
                    scale.save(heightCm: height)
                    if autoHealth, let record = scale.records.first {
                        Task { await health.save(record) }
                    }
                }
                    .disabled(!scale.canSave)
                Text("记录保存在本机；健康授权后可自动同步体重与 BMI。离开此页面或进入后台会断开体脂秤。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("苹果健康") {
                Button(health.fullyAuthorized ? "已授权体重与 BMI" : "授权体重与 BMI") {
                    inputFocused = false
                    Task { await health.authorize() }
                }.disabled(!health.available || health.busy || health.fullyAuthorized)
                Toggle("测量完成后自动保存并同步", isOn: $autoHealth)
                Text("授权后，收到最终测量会保存到本机并同步；BMI 使用本次保存的身高计算。体脂率等尚未解析的指标不会写入。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(health.status).font(.footnote).foregroundStyle(.secondary)
                if health.busy { ProgressView("正在处理苹果健康…") }
                Text("写入前检查相近记录并提示可能重复。检查依赖健康读取权限；建议只开启一个 APP 的健康同步。删除本机记录不会删除健康里的数据。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("体脂测量资料（实验）") {
                Text("体重通知不需要初始化；体脂测量可能需要个人资料。填写与蚂蚁阿福一致的资料后应用，再离秤重新裸脚站稳测量。资料字段仍需真机核对。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    inputFocused = false
                    showingBirthMonthPicker = true
                } label: {
                    HStack {
                        Text("出生年月").foregroundStyle(.primary)
                        Spacer()
                        Text(birthYear > 0 && (1...12).contains(birthMonth)
                             ? "\(String(birthYear)) 年 \(birthMonth) 月" : "请选择")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("当前年龄", value: age.map { "\($0) 岁" } ?? "请选择有效出生年月")
                Text("出生年月只需填写一次，测量时自动计算年龄，按出生月份更新。")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("性别", selection: $sex) {
                    Text("请选择").tag(-1)
                    Text("女").tag(0)
                    Text("男").tag(1)
                }.pickerStyle(.segmented)
                profileInput("最近体重", text: $referenceText, unit: "kg")
                if let reading = scale.reading {
                    Button("使用本次体重填写最近体重") {
                        inputFocused = false
                        referenceText = String(format: "%.2f", reading.kilograms)
                    }
                }
                Text("身高沿用上方输入值，初始化暂支持整数厘米。最近体重可用上方按钮自动填写。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("应用资料并准备体脂测量") {
                    inputFocused = false
                    if let profile { scale.prepareComposition(profile) }
                }.disabled(!scale.active || profile == nil)
                Text(scale.compositionStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Section("测量记录") {
                if scale.records.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
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
                }.onDelete(perform: scale.delete)
            }
            Section {
                LabeledContent("APP 构建", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")
                DisclosureGroup("连接诊断") {
                    Text(scale.logs.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item: scale.logs.joined(separator: "\n")) { Label("导出诊断日志", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("体重测量")
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
        .onChange(of: scale.reading) { _, reading in
            guard autoHealth, health.weightAuthorized || health.bmiAuthorized,
                  reading?.stable == true, reading?.resistance1 != nil, scale.canSave else { return }
            scale.save(heightCm: height)
            if let record = scale.records.first {
                Task { await health.save(record, requestPermission: false) }
            }
        }
        .onDisappear { scale.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { scale.stop() }
            if phase == .active { health.refreshAuthorization() }
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
}

/// Explicit wheel layout keeps long year lists scrollable and independent of live BLE updates.
private struct BirthMonthPicker: View {
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
