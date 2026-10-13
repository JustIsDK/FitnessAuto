import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bluetooth: TreadmillBluetooth
    @EnvironmentObject private var library: PlanLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("fitnessauto.training.selectedPlanID") private var selectedPlanID = 1
    @State private var showingStagePicker = false
    @State private var showingTreadmillConnection = false
    private var selectedPlan: WorkoutPlan { library.plans.first { $0.id == selectedPlanID } ?? WorkoutPlan.presets[0] }
    private var displayPlan: WorkoutPlan { bluetooth.currentPlan ?? selectedPlan }
    private var availablePlanIDs: [Int] { library.plans.map(\.id) }

    private func validateSelectedPlan(_ ids: [Int]) {
        if !ids.contains(selectedPlanID) { selectedPlanID = ids.first ?? 1 }
    }

    var body: some View {
        TabView {
            NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label("跑步机", systemImage: "figure.run").font(.headline)
                            Spacer()
                            Button {
                                showingTreadmillConnection = true
                            } label: {
                                ConnectionBadge(title: bluetooth.connected ? "已连接" : bluetooth.isConnecting ? "连接中" : bluetooth.isScanning ? "扫描中" : "等待连接", connected: bluetooth.connected)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("treadmillConnection")
                            .accessibilityHint("打开跑步机设备列表")
                        }
                        HStack(spacing: 12) {
                            MetricTile(title: "当前速度", value: bluetooth.liveSpeed.map { String(format: "%.1f", $0) } ?? "—", unit: "km/h", icon: "speedometer")
                            MetricTile(title: "当前坡度", value: bluetooth.liveIncline.map(String.init) ?? "—", unit: "%", icon: "mountain.2")
                        }
                    }.padding(.vertical, 8)
                    Picker("选择计划", selection: $selectedPlanID) {
                        ForEach(library.plans) { Text($0.title).tag($0.id) }
                    }.disabled(bluetooth.workoutBusy || bluetooth.workoutPaused)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayPlan.title).font(.title3.weight(.semibold))
                        Text("按阶段自动调整速度与坡度").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                    HStack {
                        Label("\(displayPlan.duration / 60) 分钟", systemImage: "clock")
                        Spacer()
                        Text("\(displayPlan.steps.count) 个阶段")
                    }.foregroundStyle(.secondary)
                    if bluetooth.currentPlan != nil {
                        ProgressView(value: Double(bluetooth.workoutElapsed), total: Double(displayPlan.duration))
                        HStack {
                            Text("计划进度 \(clock(bluetooth.workoutElapsed))")
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
                    Text(bluetooth.workoutMessage).font(.subheadline).foregroundStyle(.secondary)
                    Text("检查安全夹后点击开始训练，跑步机会自动启动；倒计时结束并确认运行后开始计划计时。")
                        .font(.caption).foregroundStyle(.secondary)
                    if bluetooth.workoutStarting {
                        ProgressView("正在启动跑步机…")
                    } else if bluetooth.workoutStopping {
                        ProgressView("正在确认停机…")
                    } else if bluetooth.workoutActive {
                        Button("暂停自动调节", systemImage: "pause.fill") { bluetooth.pauseWorkout() }
                        Button("下一阶段", systemImage: "forward.end.fill") { bluetooth.jumpToNextStage() }
                            .disabled(!bluetooth.canJumpNextStage)
                        Button("跳转到指定阶段", systemImage: "list.number") { showingStagePicker = true }
                            .disabled(!bluetooth.canJumpStage)
                        Text("跳转会立即调整速度和坡度，从目标阶段开头计时；运动记录仍按实际运动累计。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if bluetooth.workoutPaused {
                        Button("继续训练", systemImage: "play.fill") { bluetooth.resumeWorkout() }
                            .buttonStyle(AppPrimaryButtonStyle())
                            .disabled(!bluetooth.canStartWorkout)
                    } else {
                        Button("开始训练", systemImage: "play.fill") {
                            bluetooth.startWorkout(selectedPlan)
                        }.buttonStyle(AppPrimaryButtonStyle())
                            .disabled(!bluetooth.canStartWorkout)
                    }
                    if !bluetooth.workoutBusy, let reason = bluetooth.workoutStartBlockReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if bluetooth.workoutActive || bluetooth.workoutPaused || bluetooth.workoutStarting {
                        Button("结束计划并停止跑步机", role: .destructive) { bluetooth.endWorkout() }
                    }
                    if bluetooth.stopNeedsRetry || (!bluetooth.workoutBusy && !bluetooth.workoutPaused && bluetooth.liveSpeed != nil) {
                        Button(bluetooth.stopNeedsRetry ? "重试停止跑步机" : "停止跑步机", role: .destructive) {
                            bluetooth.endWorkout(reason: "已请求停止")
                        }.disabled(!bluetooth.canStopTreadmill)
                    }
                    DisclosureGroup("查看完整阶段表") {
                        ForEach(displayPlan.steps) { step in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(clock(step.start))–\(clock(step.start + step.duration)) · \(step.title)")
                                Text(String(format: "%.1f km/h · 坡度 %d%%", step.speed, step.incline)).foregroundStyle(.secondary)
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }
            }
            .appListStyle()
            .navigationTitle("训练")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingTreadmillConnection) {
                TreadmillConnectionView()
            }
            .sheet(isPresented: $showingStagePicker) {
                NavigationStack {
                    List {
                        Section {
                            Text("选择后立即应用该阶段的参数，并从阶段开头重新计时。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(Array(displayPlan.steps.enumerated()), id: \.element.id) { index, step in
                            Button {
                                bluetooth.jumpToStage(at: index)
                                showingStagePicker = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("第\(index + 1)阶段 · \(step.title)")
                                        if bluetooth.currentStageIndex == index {
                                            Text("当前").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(String(format: "%.1f km/h · 坡度 %d%% · %@", step.speed, step.incline, clock(step.duration)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(!bluetooth.canJumpStage)
                        }
                    }
                    .appListStyle()
                    .navigationTitle("跳转阶段")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingStagePicker = false }
                        }
                    }
                }
            }
            .onChange(of: availablePlanIDs, initial: true) { _, ids in
                validateSelectedPlan(ids)
            }
            .onChange(of: scenePhase) { _, phase in
                bluetooth.setAppActive(phase == .active, background: phase == .background)
            }
            .onChange(of: bluetooth.workoutBusy) { _, busy in UIApplication.shared.isIdleTimerDisabled = busy }
            }
            .tabItem { Label("训练", systemImage: "figure.run") }

            NavigationStack {
                PlanLibraryView()
            }
            .tabItem { Label("计划库", systemImage: "list.bullet.rectangle") }

            NavigationStack {
                WeightView()
            }
            .tabItem { Label("体重管理", systemImage: "scalemass") }

            NavigationStack {
                WorkoutRecordsView()
            }
            .tabItem { Label("运动记录", systemImage: "heart.text.square") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }

}

private struct TreadmillConnectionView: View {
    @EnvironmentObject private var bluetooth: TreadmillBluetooth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        if bluetooth.isScanning || bluetooth.isConnecting { ProgressView() }
                        Text(bluetooth.connectionText)
                    }
                    if bluetooth.connected {
                        Button("断开连接", role: .destructive) { bluetooth.disconnect() }
                    } else if !bluetooth.isConnecting {
                        Button(bluetooth.isScanning ? "重新扫描" : "扫描跑步机") { bluetooth.scan() }
                            .disabled(!bluetooth.bluetoothReady)
                    }
                }
                if !bluetooth.connected && !bluetooth.devices.isEmpty {
                    Section("选择跑步机") {
                        ForEach(bluetooth.devices) { device in
                            Button { bluetooth.connect(device.id) } label: {
                                Label(device.name, systemImage: "figure.run")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .disabled(!bluetooth.bluetoothReady || bluetooth.isConnecting)
                        }
                    }
                }
            }
            .appListStyle()
            .navigationTitle("连接跑步机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if !bluetooth.connected && !bluetooth.isScanning && !bluetooth.isConnecting { bluetooth.scan() }
        }
        .onDisappear { bluetooth.stopScanning() }
        .onChange(of: bluetooth.connected) { _, connected in
            if connected { dismiss() }
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
                        .disabled(bluetooth.workoutBusy)

                    Button("② 目标速度 1.0 km/h") { bluetooth.setSpeed(1.0) }
                        .disabled(!bluetooth.readyForMotion || !bluetooth.canSendSpeed)
                    Button("目标速度 1.5 km/h") { bluetooth.setSpeed(1.5) }
                        .disabled(!bluetooth.readyForMotion || !bluetooth.canSendSpeed)
                    Button("③ 目标坡度 1%") { bluetooth.setIncline(1) }
                        .disabled(!bluetooth.readyForMotion || !bluetooth.canSendIncline)
                    Button("目标坡度 0%") { bluetooth.setIncline(0) }
                        .disabled(!bluetooth.readyForMotion || !bluetooth.canSendIncline)

                    Text("本页手动调速测试需要先在面板上以最低速度启动跑带，再测试调速或调坡。首页的开始计划支持自动启动。实体停止键和安全夹始终优先。")
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
        .appListStyle()
        .navigationTitle("连接与诊断")
        .navigationBarTitleDisplayMode(.inline)
    }
}
