import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bluetooth: TreadmillBluetooth
    @EnvironmentObject private var recorder: WorkoutRecorder
    @EnvironmentObject private var library: PlanLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedPlanID = 1
    @State private var workoutConfirmed = false
    @State private var showingStagePicker = false
    private var selectedPlan: WorkoutPlan { library.plans.first { $0.id == selectedPlanID } ?? WorkoutPlan.presets[0] }
    private var displayPlan: WorkoutPlan { bluetooth.currentPlan ?? selectedPlan }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PageIntro(eyebrow: "FITNESSAUTO", title: "每一步，都有节奏。", subtitle: "连接跑步机，让计划带着你向前。")
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label("跑步机", systemImage: "figure.run").font(.headline)
                            Spacer()
                            ConnectionBadge(title: bluetooth.connected ? "已连接" : "等待连接", connected: bluetooth.connected)
                        }
                        HStack(spacing: 12) {
                            MetricTile(title: "当前速度", value: bluetooth.liveSpeed.map { String(format: "%.1f", $0) } ?? "—", unit: "km/h", icon: "speedometer")
                            MetricTile(title: "当前坡度", value: bluetooth.liveIncline.map(String.init) ?? "—", unit: "%", icon: "mountain.2")
                        }
                        Text(bluetooth.connectionText).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section {
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
                    Toggle("已准备好开始训练", isOn: $workoutConfirmed)
                        .disabled(bluetooth.workoutBusy)
                    Text("请先查看计划并检查安全夹，开始训练会自动启动跑步机。")
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
                            .disabled(!workoutConfirmed || !bluetooth.canStartWorkout)
                    } else {
                        Button("开始训练", systemImage: "play.fill") {
                            bluetooth.readyForMotion = workoutConfirmed
                            bluetooth.startWorkout(selectedPlan)
                        }.buttonStyle(AppPrimaryButtonStyle())
                            .disabled(!workoutConfirmed || !bluetooth.canStartWorkout)
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
                } header: { AppSectionTitle(title: "训练计划", icon: "list.bullet.rectangle") }
                Section {
                    Picker("运动类型", selection: $recorder.running) {
                        Text("室内步行").tag(false)
                        Text("室内跑步").tag(true)
                    }.pickerStyle(.segmented)
                    Text("用于苹果健康的运动分类，可按本次运动调整。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if recorder.recording {
                        Label(recorder.waitingForMotion ? "等待跑步机启动" : "记录中 · \(clock(recorder.seconds))", systemImage: "record.circle")
                        Text(recorder.distanceMeters.map { String(format: "本次距离 %.2f km", $0 / 1000) } ?? "本次距离 —")
                        Text(recorder.energyKcal.map { String(format: "消耗热量 %.0f kcal", $0) } ?? "消耗热量 —")
                        Button(recorder.waitingForMotion ? "取消等待" : "结束记录（不停止跑带）") { bluetooth.finishRecording() }
                    } else {
                        Button { bluetooth.startRecording() } label: {
                            Text("开始记录").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!bluetooth.canStartRecording)
                        Text(!bluetooth.connected ? "连接跑步机后，启动跑带会自动记录。"
                             : !bluetooth.canStartRecording ? "正在准备连接，请稍候。"
                             : "检测到跑步机运行时自动记录。手动结束记录后，可点击开始记录恢复。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(bluetooth.telemetryText).font(.caption).foregroundStyle(.secondary)
                    NavigationLink("运动记录与苹果健康", destination: WorkoutRecordsView())
                    Text("不执行计划也会记录面板启动的运动。停止后保存记录，可选择写入苹果健康。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { AppSectionTitle(title: "运动记录", icon: "heart.text.square") }
                Section {
                    NavigationLink(destination: WeightView()) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("体重测量").font(.headline)
                                Text("记录体重与 BMI，同步苹果健康").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "scalemass").foregroundStyle(AppDesign.accent) }
                    }.padding(.vertical, 4)
                } header: { AppSectionTitle(title: "身体数据", icon: "figure.stand") }
                Section {
                    DisclosureGroup("训练须知") {
                    Text("开始计划会启动跑步机；结束或完成计划会发送停止指令。暂停仅暂停自动调节。启停以设备状态确认为准，异常时请使用实体停止键。训练期间保持 APP 在前台；方案二放松阶段保留坡度 15%。")
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .appListStyle()
            .navigationTitle("训练")
            .navigationBarTitleDisplayMode(.inline)
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
            .onChange(of: library.plans.map(\.id)) { _, ids in
                if !ids.contains(selectedPlanID) { selectedPlanID = 1 }
            }
            .toolbar {
                NavigationLink(destination: PlanLibraryView()) { Image(systemName: "list.bullet.rectangle") }.accessibilityLabel("计划库")
                NavigationLink(destination: DiagnosticsView()) { Image(systemName: "wrench.and.screwdriver") }.accessibilityLabel("连接与诊断")
            }
            .onChange(of: workoutConfirmed) { _, confirmed in bluetooth.readyForMotion = confirmed }
            .onChange(of: scenePhase) { _, phase in
                bluetooth.setAppActive(phase == .active, background: phase == .background)
                if phase == .background { workoutConfirmed = false }
            }
            .onChange(of: bluetooth.connected) { _, connected in
                if !connected { workoutConfirmed = false }
            }
            .onChange(of: bluetooth.workoutBusy) { _, busy in UIApplication.shared.isIdleTimerDisabled = busy }
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
