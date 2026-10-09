import SwiftUI
import UIKit

struct WeightView: View {
    @StateObject private var scale = ScaleBluetooth()
    @AppStorage("fitnessauto.weight.heightCm") private var heightText = ""
    @AppStorage("fitnessauto.weight.age") private var ageText = ""
    @AppStorage("fitnessauto.weight.sex") private var sex = -1
    @AppStorage("fitnessauto.weight.referenceKg") private var referenceText = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    private var height: Double? {
        guard let value = Double(heightText), (90...240).contains(value) else { return nil }
        return value
    }
    private var profile: ScaleProfile? {
        guard let height, height.rounded() == height, let age = Int(ageText), sex == 0 || sex == 1,
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
                LabeledContent("体脂率", value: "尚未解析")
                Text("BMI 根据体重和身高计算。体脂率的计算尚未验证，本版不显示估算值。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(scale.saved ? "本次测量已保存" : "保存本次测量") { scale.save(heightCm: height) }
                    .disabled(!scale.canSave)
                Text("记录保存在本机，目前不写入苹果健康。离开此页面或进入后台会断开体脂秤。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("体脂测量资料（实验）") {
                Text("体重通知不需要初始化；体脂测量可能需要个人资料。填写与蚂蚁阿福一致的资料后应用，再离秤重新裸脚站稳测量。资料字段仍需真机核对。")
                    .font(.footnote).foregroundStyle(.secondary)
                profileInput("年龄", text: $ageText, unit: "岁", keyboard: .numberPad)
                Picker("性别", selection: $sex) {
                    Text("请选择").tag(-1)
                    Text("女").tag(0)
                    Text("男").tag(1)
                }
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
                    }
                }.onDelete(perform: scale.delete)
            }
            Section {
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
        .onDisappear { scale.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { scale.stop() } }
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
