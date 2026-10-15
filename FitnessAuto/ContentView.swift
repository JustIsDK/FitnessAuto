import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bluetooth: TreadmillBluetooth
    @EnvironmentObject private var library: PlanLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("fitnessauto.training.selectedPlanID") private var selectedPlanID = 1
    @State private var selectedTab = 0
    @State private var trainingError: String?
    @State private var showingTreadmillConnection = false
    private var selectedPlan: WorkoutPlan { library.plans.first { $0.id == selectedPlanID } ?? WorkoutPlan.presets[0] }
    private var displayPlan: WorkoutPlan { bluetooth.currentPlan ?? selectedPlan }
    private var availablePlanIDs: [Int] { library.plans.map(\.id) }
    private var importBlocked: Bool { bluetooth.workoutBusy || bluetooth.workoutPaused || bluetooth.stopNeedsRetry }
    private var actionState: TrainingActionState {
        TrainingActionState(active: bluetooth.workoutActive, starting: bluetooth.workoutStarting,
                            paused: bluetooth.workoutPaused, stopping: bluetooth.workoutStopping,
                            stopNeedsRetry: bluetooth.stopNeedsRetry)
    }
    private var trainingMessage: String? {
        switch actionState {
        case .starting: return nil
        case .paused, .stopUnconfirmed: return bluetooth.workoutMessage
        case .idle:
            guard let reason = bluetooth.workoutStartBlockReason else { return nil }
            if reason == "正在准备跑步机控制连接，请稍候" || reason == "跑步机正在倒计时，请等待启动完成" { return nil }
            return reason
        case .running, .stopping: return nil
        }
    }
    private func routePendingImport() {
        guard !library.pendingImports.isEmpty, !importBlocked, !showingTreadmillConnection,
              trainingError == nil else { return }
        selectedTab = 1
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { trainingContent }
                .tabItem { Label("训练", systemImage: "figure.run") }.tag(0)
            NavigationStack { PlanLibraryView(isSelected: selectedTab == 1, presentationBlocked: showingTreadmillConnection || trainingError != nil) }
                .tabItem { Label("计划库", systemImage: "list.bullet.rectangle") }.tag(1)
            NavigationStack { WeightView() }
                .tabItem { Label("体重管理", systemImage: "scalemass") }.tag(2)
            NavigationStack { WorkoutRecordsView() }
                .tabItem { Label("运动记录", systemImage: "heart.text.square") }.tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(4)
        }
        .onOpenURL { file in library.receiveImport(file) }
        .onChange(of: library.pendingImports.map(\.id), initial: true) { _, _ in routePendingImport() }
        .onChange(of: importBlocked) { _, _ in routePendingImport() }
        .onChange(of: showingTreadmillConnection) { _, shown in if !shown { routePendingImport() } }
        .onChange(of: trainingError) { _, error in if error == nil { routePendingImport() } }
        .onChange(of: availablePlanIDs, initial: true) { _, ids in
            if !ids.contains(selectedPlanID) { selectedPlanID = ids.first ?? 1 }
        }
        .onChange(of: scenePhase) { _, phase in
            bluetooth.setAppActive(phase == .active, background: phase == .background)
        }
        .onChange(of: bluetooth.workoutBusy) { _, busy in UIApplication.shared.isIdleTimerDisabled = busy }
    }

    @ViewBuilder private var trainingContent: some View {
#if DEBUG && targetEnvironment(simulator)
        if let state = TrainingDesignPreview.requestedState { TrainingDesignPreview(state: state) }
        else { trainingList }
#else
        trainingList
#endif
    }

    private var trainingList: some View {
        List {
            Section {
                TreadmillStatusCard(speed: bluetooth.liveSpeed, incline: bluetooth.liveIncline,
                    connected: bluetooth.connected,
                    connectionTitle: bluetooth.connected ? "已连接" : bluetooth.isConnecting ? "连接中" : bluetooth.isScanning ? "扫描中" : "等待连接") {
                        showingTreadmillConnection = true
                    }
                Picker("选择计划", selection: Binding(
                    get: { displayPlan.id }, set: { selectedPlanID = $0 })) {
                    ForEach(library.plans) { Text($0.title).tag($0.id) }
                    if let current = bluetooth.currentPlan, !availablePlanIDs.contains(current.id) {
                        Text(current.title).tag(current.id)
                    }
                }.disabled(actionState.usesStopAction)
                TrainingPlanControls(plan: displayPlan, state: actionState,
                    elapsed: bluetooth.currentPlan == nil ? nil : bluetooth.workoutElapsed,
                    activeSeconds: bluetooth.workoutActiveSeconds,
                    message: trainingMessage,
                    primaryEnabled: actionState.usesStopAction ? bluetooth.canStopTreadmill : bluetooth.canStartWorkout,
                    canResume: bluetooth.canStartWorkout,
                    canJumpNext: bluetooth.canJumpNextStage, canJumpStage: bluetooth.canJumpStage,
                    onPrimary: {
                        if actionState.usesStopAction { bluetooth.endWorkout() }
                        else {
                            bluetooth.startWorkout(selectedPlan)
                            if !bluetooth.workoutBusy { trainingError = bluetooth.workoutMessage }
                        }
                    }, onResume: { bluetooth.resumeWorkout() },
                    onNext: { bluetooth.jumpToNextStage() }, onStage: { bluetooth.jumpToStage(at: $0) })
            }
            if importBlocked && !library.pendingImports.isEmpty {
                Section {
                    Text("文件已接收，训练结束后可导入（\(library.pendingImports.count) 个）")
                        .font(.footnote).accessibilityIdentifier("pendingImportNotice")
                }
            }
        }
        .appListStyle()
        .navigationTitle("训练")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingTreadmillConnection) { TreadmillConnectionView() }
        .alert("无法开始训练", isPresented: Binding(
            get: { trainingError != nil }, set: { if !$0 { trainingError = nil } })) {
                Button("知道了") { trainingError = nil }
            } message: { Text(trainingError ?? "") }
    }
}

private struct TreadmillStatusCard: View {
    let speed: Double?
    let incline: Int?
    let connected: Bool
    let connectionTitle: String
    var onConnect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("跑步机", systemImage: "figure.run").font(.headline)
                Spacer()
                Button(action: onConnect) {
                    ConnectionBadge(title: connectionTitle, connected: connected)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("treadmillConnection")
                    .accessibilityHint("打开跑步机设备列表")
            }
            HStack(spacing: 12) {
                MetricTile(title: "当前速度", value: speed.map { String(format: "%.1f", $0) } ?? "—", unit: "km/h", icon: "speedometer")
                MetricTile(title: "当前坡度", value: incline.map(String.init) ?? "—", unit: "%", icon: "mountain.2")
            }
        }.padding(.vertical, 8)
    }
}

private struct TrainingPlanControls: View {
    let plan: WorkoutPlan
    let state: TrainingActionState
    let elapsed: Int?
    let activeSeconds: Int
    let message: String?
    let primaryEnabled: Bool
    let canResume: Bool
    let canJumpNext: Bool
    let canJumpStage: Bool
    var onPrimary: () -> Void
    var onResume: () -> Void
    var onNext: () -> Void
    var onStage: (Int) -> Void
    private var currentIndex: Int? { elapsed.flatMap { plan.stepIndex(at: $0) } }

    var body: some View {
        Button(action: onPrimary) {
            HStack(spacing: 8) {
                if state == .stopping { ProgressView().tint(.white) }
                else { Image(systemName: state.usesStopAction ? "stop.fill" : "play.fill") }
                Text(state.primaryTitle)
            }
        }
        .buttonStyle(AppPrimaryButtonStyle(tint: state.usesStopAction ? AppDesign.destructive : AppDesign.accent,
                                          keepsTintWhenDisabled: state.usesStopAction))
        .disabled(!primaryEnabled || state == .stopping)
        .accessibilityIdentifier("trainingPrimaryAction")
        if let message {
            Text(message).font(.caption).foregroundStyle(state == .stopUnconfirmed ? Color.red : Color.secondary)
                .accessibilityIdentifier("trainingStatus")
        }
        if state == .paused {
            Button("继续训练", systemImage: "play.fill", action: onResume)
                .disabled(!canResume).accessibilityIdentifier("trainingResume")
        }
        if let elapsed {
            if let index = currentIndex {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        remainingTime(index: index, elapsed: elapsed).fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        activeTime
                    }
                    VStack(alignment: .leading, spacing: 8) { remainingTime(index: index, elapsed: elapsed); activeTime }
                }
                .transaction { $0.animation = nil }
            }
            VStack(alignment: .leading, spacing: 14) {
                StageProgressView(plan: plan, elapsed: elapsed)
                if let index = currentIndex {
                    let nextIndex = plan.steps.indices.contains(index + 1) ? index + 1 : nil
                    if let nextIndex, state == .running {
                        Button(action: onNext) {
                            targetRow(title: "下一阶段目标", step: plan.steps[nextIndex], action: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(state != .running || !canJumpNext)
                        .accessibilityIdentifier("trainingNextStageTarget")
                        .accessibilityLabel("跳到下一阶段，速度 \(String(format: "%.1f", plan.steps[nextIndex].speed)) km/h，坡度 \(plan.steps[nextIndex].incline)%")
                    } else {
                        targetRow(title: nextIndex == nil ? "最后阶段目标" : "当前阶段目标", step: plan.steps[index], action: false)
                    }
                }
            }.padding(.vertical, 6).transaction { $0.animation = nil }
        } else {
            Label(plan.duration % 60 == 0 ? "\(plan.duration / 60) 分钟" : "\(plan.duration / 60) 分 \(plan.duration % 60) 秒", systemImage: "clock")
                .foregroundStyle(.secondary)
        }
        DisclosureGroup("查看完整阶段表") {
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                if state == .running {
                    Button { onStage(index) } label: { stageRow(step, index: index) }
                        .disabled(!canJumpStage).accessibilityIdentifier("trainingStage-\(index)")
                        .accessibilityHint("从这个阶段开头继续训练，并立即调整速度和坡度")
                } else { stageRow(step, index: index) }
            }
        }.transaction { $0.animation = nil }
    }
    private func stageRow(_ step: WorkoutStep, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("第\(index + 1)阶段 · \(step.title)")
                if currentIndex == index { Text("当前").foregroundStyle(AppDesign.accent) }
            }
            Text("\(clock(step.start))–\(clock(step.start + step.duration)) · " + String(format: "%.1f km/h · 坡度 %d%%", step.speed, step.incline))
                .foregroundStyle(.secondary)
        }.font(.caption).monospacedDigit().foregroundStyle(.primary)
    }

    private func remainingTime(index: Int, elapsed: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").accessibilityHidden(true)
            Text("本阶段剩余 \(clock(max(0, plan.steps[index].start + plan.steps[index].duration - elapsed)))")
                .accessibilityIdentifier("trainingStageRemaining")
        }
        .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(AppDesign.accent)
    }

    private var activeTime: some View {
        HStack(spacing: 4) {
            Text("已进行").font(.caption).foregroundStyle(.secondary)
            Text(clock(activeSeconds)).font(.title2.weight(.semibold))
                .accessibilityIdentifier("trainingElapsed")
        }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
    }

    private func targetRow(title: String, step: WorkoutStep, action: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f km/h · 坡度 %d%%", step.speed, step.incline))
                    .font(.headline).monospacedDigit().accessibilityIdentifier("trainingTarget")
            }
            Spacer()
            if action { Image(systemName: "chevron.right").foregroundStyle(AppDesign.accent) }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct StageProgressView: View {
    let plan: WorkoutPlan
    let elapsed: Int

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let ratio = plan.progress(at: elapsed)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14)).frame(height: 8)
                Capsule().fill(AppDesign.accent).frame(width: width * ratio, height: 8)
                ForEach(plan.progressMarkers(width: width)) { step in
                    let position = width * CGFloat(step.start) / CGFloat(max(1, plan.duration))
                    Circle().fill(AppDesign.accent).frame(width: 9, height: 9)
                        .position(x: position, y: proxy.size.height / 2)
                        .accessibilityElement()
                        .accessibilityLabel("第\(plan.steps.firstIndex(where: { $0.id == step.id }).map { $0 + 1 } ?? 0) 阶段边界，计划时间 \(clock(step.start))")
                        .accessibilityIdentifier("trainingProgressStage-\(step.id)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 18)
        .accessibilityIdentifier("trainingProgress")
        .transaction { $0.animation = nil }
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

#if DEBUG && targetEnvironment(simulator)
// Fixtures reuse production controls; no Bluetooth actions are sent from this view.
private struct TrainingDesignPreview: View {
    static var requestedState: TrainingActionState? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--training-design"), args.indices.contains(index + 1) else { return nil }
        return TrainingActionState(rawValue: args[index + 1])
    }
    @State var state: TrainingActionState
    @State private var selectedID = 101
    @State private var elapsed = 19
    private let plan = WorkoutPlan(id: 101, title: "DXN M2", steps: [
        WorkoutStep(id: 0, start: 0, duration: 20, title: "阶段 01", speed: 5, incline: 0),
        WorkoutStep(id: 1, start: 20, duration: 40, title: "阶段 02", speed: 6, incline: 2),
        WorkoutStep(id: 2, start: 60, duration: 60, title: "阶段 03", speed: 5, incline: 6)
    ] + (3..<18).map { WorkoutStep(id: $0, start: 120 + ($0 - 3) * 72, duration: 72,
                                  title: String(format: "阶段 %02d", $0 + 1), speed: 5, incline: 4) })
    private var canJumpNext: Bool {
        guard let index = plan.stepIndex(at: elapsed) else { return false }
        return plan.steps.indices.contains(index + 1)
    }
    var body: some View {
        List {
            Section {
                TreadmillStatusCard(speed: state == .idle ? 0 : 5, incline: 0, connected: true,
                                    connectionTitle: "已连接", onConnect: {})
                Picker("选择计划", selection: $selectedID) { Text(plan.title).tag(plan.id) }
                    .disabled(state.usesStopAction)
                TrainingPlanControls(plan: plan, state: state,
                    elapsed: [.running, .paused, .starting].contains(state) ? elapsed : nil,
                    activeSeconds: 19,
                    message: state == .paused ? "连接中断，计划已暂停；检查面板后继续" :
                        state == .stopUnconfirmed ? "停止指令发送失败，请重试或使用实体停止键" :
                        nil,
                    primaryEnabled: true, canResume: true, canJumpNext: canJumpNext, canJumpStage: true,
                    onPrimary: { state = state == .idle ? .starting : .stopping },
                    onResume: { state = .running },
                    onNext: { if let index = plan.stepIndex(at: elapsed), plan.steps.indices.contains(index + 1) { elapsed = plan.steps[index + 1].start } },
                    onStage: { elapsed = plan.steps[$0].start })
            }
        }.appListStyle().navigationTitle("训练").navigationBarTitleDisplayMode(.inline)
    }
}
#endif
