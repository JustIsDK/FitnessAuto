import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bluetooth: TreadmillBluetooth
    @EnvironmentObject private var recorder: WorkoutRecorder
    @EnvironmentObject private var library: PlanLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedPlanID = 1
    @State private var workoutConfirmed = false
    private var selectedPlan: WorkoutPlan { library.plans.first { $0.id == selectedPlanID } ?? WorkoutPlan.presets[0] }
    private var displayPlan: WorkoutPlan { bluetooth.currentPlan ?? selectedPlan }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(bluetooth.connectionText, systemImage: bluetooth.connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.subheadline)
                    HStack {
                        metric("速度", value: bluetooth.liveSpeed.map { String(format: "%.1f", $0) } ?? "—", unit: "km/h")
                        Spacer()
                        metric("坡度", value: bluetooth.liveIncline.map(String.init) ?? "—", unit: "%")
                    }.padding(.vertical, 8)
                    Text(bluetooth.vendorStatusText).font(.caption).foregroundStyle(.secondary)
                }
                Section("训练计划") {
                    Picker("选择计划", selection: $selectedPlanID) {
                        ForEach(library.plans) { Text($0.title).tag($0.id) }
                    }.disabled(bluetooth.workoutActive || bluetooth.workoutPaused)
                    HStack {
                        Label("\(displayPlan.duration / 60) 分钟", systemImage: "clock")
                        Spacer()
                        Text("\(displayPlan.steps.count) 个阶段")
                    }.foregroundStyle(.secondary)
                    if bluetooth.currentPlan != nil {
                        ProgressView(value: Double(bluetooth.workoutElapsed), total: Double(displayPlan.duration))
                        HStack {
                            Text("已进行 \(clock(bluetooth.workoutElapsed))")
                            Spacer()
                            Text("剩余 \(clock(max(0, displayPlan.duration - bluetooth.workoutElapsed)))")
                        }.font(.caption).monospacedDigit()
                        if let stage = bluetooth.currentStep {
                            Text(stage.title).font(.headline)
                            Text(String(format: "目标 %.1f km/h · 坡度 %d%%", stage.speed, stage.incline))
                            Text("本阶段剩余 \(clock(max(0, stage.start + stage.duration - bluetooth.workoutElapsed)))")
                                .font(.caption).monospacedDigit()
                        }
                    }
                    Text(bluetooth.workoutMessage).font(.subheadline)
                    Toggle("已查看计划，并在面板上启动跑带", isOn: $workoutConfirmed)
                        .disabled(bluetooth.workoutActive)
                    if bluetooth.workoutActive {
                        Button("暂停自动调节", systemImage: "pause.fill") { bluetooth.pauseWorkout() }
                    } else if bluetooth.workoutPaused {
                        Button("继续训练", systemImage: "play.fill") { bluetooth.resumeWorkout() }
                            .disabled(!workoutConfirmed || !bluetooth.canStartWorkout)
                    } else {
                        Button("开始训练", systemImage: "play.fill") {
                            bluetooth.readyForMotion = workoutConfirmed
                            bluetooth.startWorkout(selectedPlan)
                        }.disabled(!workoutConfirmed || !bluetooth.canStartWorkout)
                    }
                    if bluetooth.workoutActive || bluetooth.workoutPaused {
                        Button("结束自动调节", role: .destructive) { bluetooth.endWorkout() }
                    }
                    DisclosureGroup("完整阶段表") {
                        ForEach(displayPlan.steps) { step in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(clock(step.start))–\(clock(step.start + step.duration)) · \(step.title)")
                                Text(String(format: "%.1f km/h · 坡度 %d%%", step.speed, step.incline)).foregroundStyle(.secondary)
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }
                Section("运动记录") {
                    if recorder.recording {
                        Label("记录中 · \(clock(recorder.seconds))", systemImage: "record.circle")
                        Text(recorder.distanceMeters.map { String(format: "本次距离 %.2f km", $0 / 1000) } ?? "本次距离 —")
                        Text(recorder.energyKcal.map { String(format: "设备热量 %.0f kcal", $0) } ?? "设备热量 —")
                        Button("结束记录（不停止跑带）") { recorder.finish() }
                    } else {
                        Picker("运动类型", selection: $recorder.running) {
                            Text("室内步行").tag(false)
                            Text("室内跑步").tag(true)
                        }
                        Button("单独记录运动", systemImage: "record.circle") { bluetooth.startRecording() }
                            .disabled(!bluetooth.connected || bluetooth.liveSpeed == nil)
                    }
                    Text(bluetooth.telemetryText).font(.caption).foregroundStyle(.secondary)
                    NavigationLink("运动记录与苹果健康", destination: WorkoutRecordsView())
                    Text("开始训练会同时记录。记录结束后，可选择写入苹果健康。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("暂停和结束只停止自动调节，跑带仍会运行。请使用面板停止键停机。训练期间保持 APP 在前台；方案二放松阶段保留坡度 15%。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("FitnessAuto")
            .onChange(of: library.plans.map(\.id)) { _, ids in
                if !ids.contains(selectedPlanID) { selectedPlanID = 1 }
            }
            .toolbar {
                NavigationLink(destination: PlanLibraryView()) { Image(systemName: "list.bullet.rectangle") }
                NavigationLink(destination: DiagnosticsView()) { Image(systemName: "wrench.and.screwdriver") }
            }
            .onChange(of: workoutConfirmed) { _, confirmed in bluetooth.readyForMotion = confirmed }
            .onChange(of: scenePhase) { _, phase in
                bluetooth.setAppActive(phase == .active, background: phase == .background)
                if phase == .background { workoutConfirmed = false }
            }
            .onChange(of: bluetooth.connected) { _, connected in
                if !connected { workoutConfirmed = false }
            }
            .onChange(of: bluetooth.workoutActive) { _, active in UIApplication.shared.isIdleTimerDisabled = active }
        }
    }
    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

func clock(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }

struct DiagnosticsView: View {
    @EnvironmentObject private var bluetooth: TreadmillBluetooth
    var body: some View {
        List {
                Section("连接") {
                    Text("FitnessAuto · 训练与运动记录")
                        .font(.footnote)
                    Text(bluetooth.connectionText)
                    Text(bluetooth.autoConnectText).font(.footnote)
                    Button("扫描 FTMS 跑步机") { bluetooth.scan() }
                        .disabled(!bluetooth.bluetoothReady)

                    ForEach(bluetooth.devices) { device in
                        Button("连接 \(device.name) · \(device.rssi) dBm") {
                            bluetooth.connect(device.id)
                        }
                    }

                    if bluetooth.connected {
                        Button("断开连接", role: .destructive) { bluetooth.disconnect() }
                    }
                }

                Section("设备能力") {
                    Text(bluetooth.telemetryText)
                    Button("启用标准运动数据") { bluetooth.enableTelemetry() }
                    Text(bluetooth.deviceElapsedSeconds.map { "设备累计时间：" + clock($0) } ?? "设备累计时间：—")
                    Text(bluetooth.deviceDistanceMeters.map { String(format: "设备累计距离：%.0f m", $0) } ?? "设备累计距离：—")
                    Text(bluetooth.deviceEnergyKcal.map { String(format: "设备累计热量：%.0f kcal", $0) } ?? "设备累计热量：—")
                    Text(bluetooth.featureText)
                    Text(bluetooth.speedRangeText)
                    Text(bluetooth.inclineRangeText)
                    Text(bluetooth.extensionText)
                    Text("标准蓝牙速度：\(bluetooth.currentSpeedText)")
                    Text(bluetooth.vendorText)
                    Text(bluetooth.vendorStatusText)
                }

                Section("控制测试") {
                    Text(bluetooth.controlText)
                    Button("① 请求控制权（不会启动跑带）") {
                        bluetooth.requestControl()
                    }
                    .disabled(!bluetooth.canRequestControl)
                    Text("标准 FTMS 控制权请求仅用于诊断；麦瑞克私有协议训练无需此控制权。")
                        .font(.footnote)

                    Toggle("已确认跑带无人，并已在面板上手动启动", isOn: $bluetooth.readyForMotion)
                        .disabled(bluetooth.workoutActive)

                    Button("② 目标速度 1.0 km/h") { bluetooth.setSpeed(1.0) }
                        .disabled(!bluetooth.readyForMotion || !bluetooth.canSendSpeed)
                    Button("目标速度 1.5 km/h") { bluetooth.setSpeed(1.5) }
                        .disabled(!bluetooth.readyForMotion || !bluetooth.canSendSpeed)
                    Button("③ 目标坡度 1%") { bluetooth.setIncline(1) }
                        .disabled(!bluetooth.readyForMotion || !bluetooth.canSendIncline)
                    Button("目标坡度 0%") { bluetooth.setIncline(0) }
                        .disabled(!bluetooth.readyForMotion || !bluetooth.canSendIncline)

                    Text("本验证版不发送启动指令。先在跑步机面板上以最低速度启动，确认周围无人站上跑带后再点调速或调坡。实体停止键和安全夹始终优先。")
                        .font(.footnote)
                }

                Section("麦瑞克手动测试") {
                    Text("每秒查询状态以保持通信。自动训练时手动测试不会执行。")
                        .font(.footnote)
                    Button("刷新麦瑞克状态") { bluetooth.refreshVendorStatus() }
                        .disabled(!bluetooth.canRefreshVendorStatus)
                    Button("私有协议：速度 1.0 km/h") { bluetooth.setVendorSpeed(1.0) }
                        .disabled(!bluetooth.canSendVendorMotion)
                    Button("私有协议：速度 1.5 km/h") { bluetooth.setVendorSpeed(1.5) }
                        .disabled(!bluetooth.canSendVendorMotion)
                    Button("私有协议：速度 3.0 km/h") { bluetooth.setVendorSpeed(3.0) }
                        .disabled(!bluetooth.canSendVendorMotion)
                    Button("私有协议：速度 6.0 km/h") { bluetooth.setVendorSpeed(6.0) }
                        .disabled(!bluetooth.canSendVendorMotion)
                    Button("私有协议：坡度 0%") { bluetooth.setVendorIncline(0) }
                        .disabled(!bluetooth.canSendVendorMotion)
                    Button("私有协议：坡度 1%") { bluetooth.setVendorIncline(1) }
                        .disabled(!bluetooth.canSendVendorMotion)
                    Button("私有协议：坡度 2%") { bluetooth.setVendorIncline(2) }
                        .disabled(!bluetooth.canSendVendorMotion)
                }

                Section("通信记录") {
                    Button("复制通信记录") {
                        let text = bluetooth.logs.reversed().map(\.line).joined(separator: "\n")
                        #if os(iOS)
                        UIPasteboard.general.string = text
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        #endif
                    }
                    .disabled(bluetooth.logs.isEmpty)
                    ForEach(bluetooth.logs) { entry in
                        Text(entry.line).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
        }
        .navigationTitle("连接与诊断")
        .navigationBarTitleDisplayMode(.inline)
    }
}
