import CoreBluetooth
import Foundation

struct DiscoveredTreadmill: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

struct CommunicationLog: Identifiable {
    let id = UUID()
    let line: String
}

struct WorkoutStep: Identifiable, Codable {
    var id: Int
    var start: Int
    var duration: Int
    var title: String
    var speed: Double
    var incline: Int
}

struct WorkoutPlan: Identifiable, Codable {
    var id: Int
    var title: String
    var steps: [WorkoutStep]
    var duration: Int { steps.reduce(0) { total, step in
        let sum = total.addingReportingOverflow(step.duration)
        return sum.overflow ? Int.max : sum.partialValue
    } }
    func stepIndex(at elapsed: Int) -> Int? {
        steps.firstIndex { elapsed >= $0.start && elapsed < $0.start + $0.duration }
    }
    func stageStart(at index: Int) -> Int? {
        guard validationError == nil, steps.indices.contains(index) else { return nil }
        return steps[index].start
    }
    var validationError: String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "请输入计划名称" }
        guard !steps.isEmpty, steps.count <= 100 else { return "计划需要 1–100 个阶段" }
        var expectedStart = 0
        var ids = Set<Int>()
        for step in steps {
            guard step.duration > 0, step.duration <= 3600 else { return "每个阶段需要 1–3600 秒" }
            guard step.start == expectedStart, ids.insert(step.id).inserted else { return "阶段顺序或编号无效" }
            guard step.speed.isFinite, (1...18).contains(step.speed),
                  abs(step.speed * 10 - (step.speed * 10).rounded()) < 0.0001 else { return "速度需要为 1–18 km/h，步进 0.1" }
            guard (0...25).contains(step.incline) else { return "坡度需要为 0–25%" }
            expectedStart += step.duration
        }
        return expectedStart <= 14400 ? nil : "计划总时长不能超过 4 小时"
    }
    static let presets: [WorkoutPlan] = {
        var first = [WorkoutStep(id: 0, start: 0, duration: 300, title: "热身", speed: 5, incline: 0)]
        for round in 0..<4 {
            for (minute, incline) in [8, 10, 12, 14, 6].enumerated() {
                first.append(WorkoutStep(id: first.count, start: 300 + round * 300 + minute * 60,
                                         duration: 60, title: "第\(round + 1)轮·第\(minute + 1)分钟",
                                         speed: 5.5, incline: incline))
            }
        }
        first.append(WorkoutStep(id: first.count, start: 1500, duration: 300, title: "冷身", speed: 4, incline: 0))
        var second = [WorkoutStep(id: 0, start: 0, duration: 600, title: "爬坡热身", speed: 4, incline: 15)]
        for round in 0..<4 {
            second.append(WorkoutStep(id: second.count, start: 600 + round * 420, duration: 240,
                                      title: "第\(round + 1)轮·跑", speed: 5, incline: 15))
            second.append(WorkoutStep(id: second.count, start: 840 + round * 420, duration: 180,
                                      title: "第\(round + 1)轮·走", speed: 4, incline: 15))
        }
        second.append(WorkoutStep(id: second.count, start: 2280, duration: 300, title: "放松", speed: 4, incline: 15))
        return [WorkoutPlan(id: 1, title: "方案一 · 30 分钟", steps: first),
                WorkoutPlan(id: 2, title: "方案二 · 43 分钟", steps: second)]
    }()
}

final class TreadmillBluetooth: NSObject, ObservableObject {
    let recorder = WorkoutRecorder()
    @Published private(set) var telemetryText = "运动数据尚未启用"
    @Published private(set) var deviceDistanceMeters: Double?
    @Published private(set) var deviceEnergyKcal: Double?
    @Published private(set) var deviceElapsedSeconds: Int?
    private var telemetryEnabled = false
    private var treadmillDataCharacteristic: CBCharacteristic?

    func enableTelemetry() {
        telemetryEnabled = true
        if let peripheral, let characteristic = treadmillDataCharacteristic, vendorAuthorized,
           characteristic.properties.contains(.notify) {
            if !characteristic.isNotifying { peripheral.setNotifyValue(true, for: characteristic) }
        } else { telemetryText = "等待设备提供标准运动数据 2ACD；可先记录已确认运行时长" }
    }

    var canStartRecording: Bool {
        appIsActive && connected && vendorAuthorized && vendorSubscribed && !recorder.recording && !workoutStopping
    }

    func startRecording() {
        guard canStartRecording else { return }
        autoRecordingSuppressed = false
        enableTelemetry()
        let runningNow = vendorRunning && lastVendorStatus.map({ Date().timeIntervalSince($0) < 3 }) == true
        recorder.start(title: workoutPlan?.title ?? "跑步机训练", waitingForMotion: !runningNow)
    }

    func finishRecording() {
        autoRecordingSuppressed = true
        recorder.finish(reason: recorder.waitingForMotion ? "已取消等待" : "记录已结束；本次运行不再自动创建记录，可点击开始记录恢复")
    }

    @Published private(set) var devices: [DiscoveredTreadmill] = []
    @Published private(set) var connectionText = "等待蓝牙启动"
    @Published private(set) var controlText = "尚未请求控制权"
    @Published private(set) var featureText = "功能：尚未读取"
    @Published private(set) var speedRangeText = "速度范围：尚未读取"
    @Published private(set) var inclineRangeText = "坡度范围：尚未读取"
    @Published private(set) var extensionText = "厂商扩展：尚未发现"
    @Published private(set) var vendorText = "麦瑞克协议：尚未发现"
    @Published private(set) var vendorStatusText = "设备状态：尚未读取"
    @Published private(set) var currentSpeedText = "暂不订阅（连接诊断）"
    @Published private(set) var logs: [CommunicationLog] = []
    @Published private(set) var bluetoothReady = false
    @Published private(set) var connected = false
    @Published private(set) var autoConnectText = "请手动扫描并选择跑步机"
    @Published private(set) var controlGranted = false
    @Published private(set) var controlSubscribed = false
    @Published private(set) var speedSupported = false
    @Published private(set) var inclineSupported = false
    @Published private(set) var commandPending = false
    private var vendorWritePending = false
    private var queuedVendorAction: (() -> Void)?
    @Published var readyForMotion = false
    @Published private(set) var workoutActive = false
    @Published private(set) var workoutPaused = false
    @Published private(set) var workoutMotion: WorkoutMotionTransition?
    @Published private(set) var stopNeedsRetry = false
    var workoutStarting: Bool { workoutMotion?.kind == .start }
    var workoutStopping: Bool { workoutMotion?.kind == .stop }
    var workoutBusy: Bool { workoutActive || workoutMotion != nil }
    private var vendorMotionWriteID: UUID?
    private var stopReason = "计划已结束"
    private var vendorMachineState: UInt8?
    private var lastVendorReportUptime: Double?
    private var autoRecordingSuppressed = false
    @Published private(set) var workoutElapsed = 0
    @Published private(set) var workoutMessage = "选择计划，预览后开始"
    @Published private(set) var liveSpeed: Double?
    @Published private(set) var liveIncline: Int?
    @Published private(set) var currentPlan: WorkoutPlan?
    private var workoutPlan: WorkoutPlan? {
        get { currentPlan }
        set { currentPlan = newValue }
    }
    var currentStep: WorkoutStep? {
        guard let plan = currentPlan, let index = plan.stepIndex(at: workoutElapsed) else { return nil }
        return plan.steps[index]
    }
    var currentStageIndex: Int? { currentPlan?.stepIndex(at: workoutElapsed) }
    var canJumpStage: Bool {
        workoutActive && workoutMotion == nil && appIsActive && readyForMotion && connected &&
            vendorAuthorized && vendorSubscribed && vendorRunning && !vendorWritePending &&
            workoutConfirmationDeadline == nil &&
            lastVendorStatus.map { Date().timeIntervalSince($0) < 3 } == true
    }
    var canJumpNextStage: Bool {
        guard canJumpStage, let plan = currentPlan, let index = currentStageIndex else { return false }
        return plan.steps.indices.contains(index + 1)
    }
    func jumpToNextStage() {
        guard let index = currentStageIndex else { return }
        jumpToStage(at: index + 1)
    }
    func jumpToStage(at index: Int) {
        guard canJumpStage, let plan = currentPlan, let start = plan.stageStart(at: index),
              speedRange?.contains(plan.steps[index].speed) == true,
              inclineRange?.contains(Double(plan.steps[index].incline)) == true else {
            workoutMessage = "暂时无法跳转，请等待设备确认当前目标并检查连接状态"
            return
        }
        queuedVendorAction = nil
        workoutAccumulated = TimeInterval(start)
        workoutElapsed = start
        workoutStartedAt = ProcessInfo.processInfo.systemUptime
        workoutStepIndex = nil
        workoutExpectedTarget = nil
        workoutConfirmationDeadline = nil
        saveCheckpoint()
        log("手动跳转至第\(index + 1)阶段：\(plan.steps[index].title)，从阶段开头计时")
        // Reuse normal range-checked writes and subsequent machine-state confirmation.
        tickWorkout()
    }
    private struct Checkpoint: Codable {
        let plan: WorkoutPlan
        let elapsed: Int
    }
    private func saveCheckpoint() {
        if let plan = workoutPlan, workoutElapsed < plan.duration,
           let data = try? JSONEncoder().encode(Checkpoint(plan: plan, elapsed: workoutElapsed)) {
            UserDefaults.standard.set(data, forKey: "workoutCheckpoint")
        } else { UserDefaults.standard.removeObject(forKey: "workoutCheckpoint") }
    }
    private var workoutStartedAt: TimeInterval?
    private var workoutAccumulated: TimeInterval = 0
    private var workoutStepIndex: Int?
    private var workoutExpectedTarget: (speed: UInt8, incline: UInt8)?
    private var workoutConfirmationDeadline: TimeInterval?

    var canStartWorkout: Bool {
        appIsActive && connected && vendorAuthorized && vendorSubscribed && readyForMotion &&
            !workoutActive && workoutMotion == nil &&
            lastVendorReportUptime.map { ProcessInfo.processInfo.systemUptime - $0 < 3 } == true &&
            (vendorMachineState == 0x0A || vendorMachineState == 0x03)
    }

    var canStopTreadmill: Bool { connected && vendorAuthorized && vendorSubscribed && !workoutStopping }

    func startWorkout(_ plan: WorkoutPlan) {
        guard !workoutPaused, plan.validationError == nil, canStartWorkout,
              plan.steps.allSatisfy({ speedRange?.contains($0.speed) == true &&
                  inclineRange?.contains(Double($0.incline)) == true }) else {
            workoutMessage = "请确认启动条件、设备状态和计划范围；暂停的计划请先继续或结束"
            return
        }
        queuedVendorAction = nil
        workoutPlan = plan
        workoutAccumulated = 0
        workoutElapsed = 0
        workoutStepIndex = nil
        stopNeedsRetry = false
        saveCheckpoint()
        startOrContinueWorkout()
    }

    private func startOrContinueWorkout() {
        if vendorRunning { beginWorkoutTiming() }
        else {
            workoutPaused = false
            requestMotion(.start)
            workoutMessage = "正在启动跑步机；等待倒计时和运行状态确认"
        }
    }

    private func beginWorkoutTiming() {
        guard appIsActive, readyForMotion, connected, vendorAuthorized, vendorRunning, workoutPlan != nil else {
            endWorkout(reason: "启动条件变化，已取消训练")
            return
        }
        workoutMotion = nil
        workoutActive = true
        workoutPaused = false
        workoutStepIndex = nil
        workoutStartedAt = ProcessInfo.processInfo.systemUptime
        startRecording()
        tickWorkout()
    }

    private func requestMotion(_ kind: WorkoutMotionTransition.Kind) {
        let transition = WorkoutMotionTransition(kind: kind, deadline: ProcessInfo.processInfo.systemUptime + 15)
        workoutMotion = transition
        queuedVendorAction = nil
        sendMotionWhenReady(transition)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let pending = self.workoutMotion, pending.id == transition.id,
                  pending.timedOut(at: ProcessInfo.processInfo.systemUptime) else { return }
            if kind == .start {
                self.endWorkout(reason: "启动未确认，已取消计划")
            } else {
                self.workoutMotion = nil
                self.stopNeedsRetry = true
                self.recorder.finish(reason: "停止未确认；已保存观测到的运动数据")
                self.workoutMessage = "\(self.stopReason)；未确认停机，请立即使用实体停止键"
                self.log(self.workoutMessage)
            }
        }
    }

    private func sendMotionWhenReady(_ transition: WorkoutMotionTransition) {
        guard workoutMotion?.id == transition.id else { return }
        guard connected, vendorAuthorized, vendorSubscribed,
              transition.kind == .stop || (appIsActive && readyForMotion) else {
            if transition.kind == .start { endWorkout(reason: "启动条件失效，已取消计划") }
            else { workoutMotion = nil; stopNeedsRetry = true; workoutMessage = "\(stopReason)；停止指令无法发送，请使用实体停止键" }
            return
        }
        if vendorWritePending {
            // A stop replaces all queued adjustment/start actions.
            queuedVendorAction = { [weak self] in self?.sendMotionWhenReady(transition) }
            return
        }
        vendorMotionWriteID = transition.id
        writeVendor(transition.kind == .start ? MerachMotionCommand.start : MerachMotionCommand.stop,
                    label: transition.kind == .start ? "启动跑步机" : "停止跑步机")
    }

    func pauseWorkout(_ reason: String = "计时已暂停；跑带继续运行，请用面板停止键停机") {
        if workoutStarting {
            endWorkout(reason: "启动过程已取消")
            return
        }
        guard workoutActive else { return }
        if let started = workoutStartedAt {
            workoutAccumulated += ProcessInfo.processInfo.systemUptime - started
        }
        workoutElapsed = Int(workoutAccumulated)
        workoutStartedAt = nil
        workoutActive = false
        workoutPaused = true
        workoutExpectedTarget = nil
        workoutConfirmationDeadline = nil
        queuedVendorAction = nil
        workoutMessage = reason
        saveCheckpoint()
        log("训练计划暂停：\(reason)")
    }

    func resumeWorkout() {
        guard workoutPaused, canStartWorkout, let plan = workoutPlan,
              plan.validationError == nil, plan.steps.allSatisfy({ speedRange?.contains($0.speed) == true &&
                  inclineRange?.contains(Double($0.incline)) == true }) else { return }
        startOrContinueWorkout()
    }

    func endWorkout(reason: String = "计划已结束") {
        queuedVendorAction = nil
        // Clear a pending start before pausing, to avoid recursive cancellation.
        workoutMotion = nil
        pauseWorkout()
        workoutPaused = false
        workoutPlan = nil
        workoutExpectedTarget = nil
        workoutConfirmationDeadline = nil
        saveCheckpoint()
        stopReason = reason
        stopNeedsRetry = false
        if connected && vendorAuthorized && vendorSubscribed {
            requestMotion(.stop)
            workoutMessage = "\(reason)；正在停止跑步机，等待状态确认"
        } else {
            stopNeedsRetry = true
            recorder.finish(reason: "连接不可用；已保存有效运动记录")
            workoutMessage = "\(reason)；连接不可用，请使用实体停止键停机"
        }
    }

    private func tickWorkout() {
        guard appIsActive, workoutActive, let plan = workoutPlan, let started = workoutStartedAt else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard readyForMotion, connected, vendorRunning, vendorAuthorized,
              lastVendorStatus.map({ Date().timeIntervalSince($0) < 5 }) == true else {
            pauseWorkout("设备停止、连接或状态异常；计划已暂停，请检查面板")
            return
        }
        if let deadline = workoutConfirmationDeadline, now > deadline {
            pauseWorkout("设备未确认阶段目标；计划已暂停，请检查面板")
            return
        }
        let elapsed = Int(workoutAccumulated + now - started)
        guard let index = plan.stepIndex(at: elapsed) else {
            workoutElapsed = plan.duration
            endWorkout(reason: "计划完成")
            return
        }
        workoutElapsed = elapsed
        if elapsed % 5 == 0 { saveCheckpoint() }
        let step = plan.steps[index]
        if workoutStepIndex != index {
            // Leave this transition pending until the previous write completes.
            guard !vendorWritePending, workoutConfirmationDeadline == nil else { return }
            workoutStepIndex = index
            workoutExpectedTarget = (UInt8((step.speed * 10).rounded()), UInt8(step.incline))
            workoutConfirmationDeadline = now + 5
            sendVendorTarget(speed: workoutExpectedTarget!.speed, incline: workoutExpectedTarget!.incline)
            saveCheckpoint()
            log("训练阶段：\(step.title)")
        }
        workoutMessage = String(format: "%@ · %.1f km/h · 坡度 %d%% · 本阶段剩余 %d 秒",
                                step.title, step.speed, step.incline, step.start + step.duration - elapsed)
    }

    private let serviceUUID = CBUUID(string: "1826")
    private let featureUUID = CBUUID(string: "2ACC")
    private let speedRangeUUID = CBUUID(string: "2AD4")
    private let inclineRangeUUID = CBUUID(string: "2AD5")
    private let controlUUID = CBUUID(string: "2AD9")
    private let statusUUID = CBUUID(string: "2ADA")
    private let treadmillDataUUID = CBUUID(string: "2ACD")
    private let extensionUUID = CBUUID(string: "D18D2C10-C44C-11E8-A355-529269FB1459")
    // PacketLogger shows these 16-bit UUIDs in little-endian ATT bytes (f0 ff,
    // f1 ff, f2 ff); CoreBluetooth UUID strings are written as FFF0/FFF1/FFF2.
    private let vendorServiceUUID = CBUUID(string: "FFF0")
    private let vendorNotifyUUID = CBUUID(string: "FFF1")
    private let vendorWriteUUID = CBUUID(string: "FFF2")
    // Exact UUIDs verified on MRK-T10-D59A through CoreBluetooth.
    private let handshakeServiceUUID = CBUUID(string: "59554C55-8000-6666-8888-4D4552414348")
    private let handshakeUUID = CBUUID(string: "59554C55-0000-6666-8888-4D4552414348")

    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    // The user chooses when this app may claim the treadmill.
    private var autoConnectEnabled = false
    private var autoConnectAttempted = false
    private var controlCharacteristic: CBCharacteristic?
    private var vendorWriteCharacteristic: CBCharacteristic?
    private var handshakeCharacteristic: CBCharacteristic?
    private var handshakeSubscribed = false
    private var vendorSubscribed = false
    private var vendorAuthorized = false
    private var vendorHandshakePending = false
    private var vendorTargetPending = false
    private var vendorStatusTimer: Timer?
    private var vendorRunning = false
    private var vendorSpeedTenths: UInt8?
    private var vendorIncline: UInt8?
    private var lastVendorStatus: Date?
    private var lastVendorResponseUptime: Double?
    private var vendorInitialQueryPending = false
    private var pendingOpcode: UInt8?
    private var controlDenied = false
    private var pendingToken = UUID()
    private var speedRange: ClosedRange<Double>?
    private var inclineRange: ClosedRange<Double>?
    private var pendingReads: [CBCharacteristic] = []

    var canRequestControl: Bool {
        connected && controlSubscribed && !commandPending && !controlDenied && !controlGranted
    }

    var canSendSpeed: Bool {
        connected && controlSubscribed && !commandPending && controlGranted && speedSupported
    }

    var canSendIncline: Bool {
        connected && controlSubscribed && !commandPending && controlGranted && inclineSupported
    }

    var canRefreshVendorStatus: Bool {
        connected && vendorSubscribed && vendorWriteCharacteristic != nil
    }

    var canSendVendorMotion: Bool {
        appIsActive && canRefreshVendorStatus && workoutMotion == nil && vendorAuthorized && vendorRunning && vendorSpeedTenths != nil &&
            vendorIncline != nil && readyForMotion
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        if let data = UserDefaults.standard.data(forKey: "workoutCheckpoint"),
           let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
           checkpoint.plan.validationError == nil, (0..<checkpoint.plan.duration).contains(checkpoint.elapsed) {
            workoutPlan = checkpoint.plan
            workoutElapsed = checkpoint.elapsed
            workoutAccumulated = Double(checkpoint.elapsed)
            workoutPaused = true
            workoutMessage = "已恢复上次进度；检查面板并重新确认后继续"
        }
    }

    private var appIsActive = true
    private var userDisconnected = false
    private var retryCount = 0
    private var retryWork: DispatchWorkItem?
    private var connectionToken = UUID()
    private var writeToken = UUID()

    func setAppActive(_ active: Bool, background: Bool = false) {
        appIsActive = active
        if !active {
            if !workoutStopping { queuedVendorAction = nil }
            // Cancelling a pending start may enqueue a stop; retain that stop.
            pauseWorkout(background ? "锁屏或进入后台，进度已保存；请检查跑步机面板" : "系统打断了 APP，计划已暂停；回到 APP 后可手动继续")
        }
        if background {
            pauseWorkout("锁屏或进入后台，进度已保存；跑带仍会运行，请检查面板")
            readyForMotion = false
            retryWork?.cancel()
            central.stopScan()
            let old = peripheral
            resetConnection()
            if let old { central.cancelPeripheralConnection(old) }
            connectionText = "后台已暂停连接，回到 APP 后重新连接"
        } else if active, !userDisconnected {
            if connected { refreshVendorStatus() }
            // Reconnection remains manual after returning to the foreground.
        }
    }

    private func scheduleReconnect() {
        guard autoConnectEnabled, appIsActive, !userDisconnected, bluetoothReady else { return }
        retryWork?.cancel()
        let delay = min(30, pow(2, Double(min(retryCount, 5))))
        retryCount += 1
        autoConnectText = "连接已断开，请手动扫描并重新连接"
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.appIsActive, !self.userDisconnected, !self.connected else { return }
            self.scan()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func watchPrivateWrite() {
        let token = UUID()
        writeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.writeToken == token, self.vendorWritePending else { return }
            self.log("麦瑞克写入确认超时，断开并重新连接")
            self.pauseWorkout("通信确认超时，计划已暂停")
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
        }
    }

    func scan() {
        guard bluetoothReady, appIsActive, peripheral == nil else { return }
        userDisconnected = false
        autoConnectAttempted = false
        retryWork?.cancel()
        devices = []
        discovered = [:]
        connectionText = "正在扫描 FTMS 设备…"
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        log("扫描服务 1826")
        let token = UUID()
        connectionToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.connectionToken == token, self.peripheral == nil else { return }
            self.central.stopScan()
            self.connectionText = "未发现跑步机"
            self.scheduleReconnect()
        }
    }

    func connect(_ id: UUID) {
        guard appIsActive, peripheral == nil, let device = discovered[id] else { return }
        userDisconnected = false
        retryWork?.cancel()
        central.stopScan()
        peripheral = device
        device.delegate = self
        connectionText = "正在连接 \(device.name ?? id.uuidString)…"
        central.connect(device, options: nil)
        let token = UUID()
        connectionToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.connectionToken == token, self.peripheral === device,
                  !self.vendorAuthorized else { return }
            self.log("连接或握手超时，重新连接")
            self.central.cancelPeripheralConnection(device)
        }
    }

    func disconnect() {
        userDisconnected = true
        retryWork?.cancel()
        central.stopScan()
        let old = peripheral
        resetConnection()
        if let old { central.cancelPeripheralConnection(old) }
        connectionText = "已手动断开，点击扫描可重新连接"
        autoConnectText = "自动重连已停止"
    }

    func requestControl() {
        guard appIsActive, canRequestControl else { return }
        send([0x00], label: "请求控制权")
    }

    func setSpeed(_ kmh: Double) {
        guard appIsActive && !workoutActive && readyForMotion && canSendSpeed else { return }
        if let speedRange, !speedRange.contains(kmh) {
            log("速度 \(kmh) km/h 超出设备范围")
            return
        }
        let raw = UInt16((kmh * 100).rounded())
        send([0x02, UInt8(raw & 0xff), UInt8(raw >> 8)],
             label: String(format: "目标速度 %.1f km/h", kmh))
    }

    func setIncline(_ percent: Double) {
        guard appIsActive && !workoutActive && readyForMotion && canSendIncline else { return }
        if let inclineRange, !inclineRange.contains(percent) {
            log("坡度 \(percent)% 超出设备范围")
            return
        }
        let raw = Int16((percent * 10).rounded())
        let bits = UInt16(bitPattern: raw)
        send([0x03, UInt8(bits & 0xff), UInt8(bits >> 8)],
             label: String(format: "目标坡度 %.0f%%", percent))
    }

    func refreshVendorStatus() {
        guard appIsActive, canRefreshVendorStatus, !vendorWritePending else { return }
        writeVendor([0x02, 0x51, 0x51, 0x03], label: "读取麦瑞克设备状态")
    }

    private func startVendorStatusPolling() {
        guard vendorStatusTimer == nil else { return }
        log("已开启每秒自动查询麦瑞克状态")
        vendorStatusTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.appIsActive, self.connected, self.vendorAuthorized else { return }
            if let last = self.lastVendorResponseUptime,
               ProcessInfo.processInfo.systemUptime - last > 5 {
                self.pauseWorkout("设备状态超时，计划已暂停；正在重新连接")
                self.recorder.finish(reason: "设备状态超时；记录已保存在本机")
                self.log("设备超过 5 秒未返回有效状态，重新连接")
                if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
                self.lastVendorResponseUptime = nil
                return
            }
            if let last = self.lastVendorStatus, Date().timeIntervalSince(last) > 5 {
                self.vendorRunning = false
                self.liveSpeed = nil
                self.liveIncline = nil
                self.lastVendorStatus = nil
                self.vendorStatusText = "运行状态已过期，等待设备刷新"
                self.pauseWorkout("运行状态已过期，计划已暂停")
                self.recorder.finish(reason: "运行状态已过期；已保存有效运动记录")
            }
            self.tickWorkout()
            // Skip this tick if another write is awaiting its ATT confirmation.
            self.refreshVendorStatus()
        }
        RunLoop.main.add(vendorStatusTimer!, forMode: .common)
        lastVendorResponseUptime = ProcessInfo.processInfo.systemUptime
        refreshVendorStatus()
    }

    func setVendorSpeed(_ kmh: Double) {
        guard !workoutActive else { return }
        guard canSendVendorMotion, let incline = vendorIncline else { return }
        if vendorWritePending {
            queuedVendorAction = { [weak self] in self?.setVendorSpeed(kmh) }
            return
        }
        guard let lastVendorStatus, Date().timeIntervalSince(lastVendorStatus) < 10 else {
            log("设备状态已过期；请先刷新状态")
            return
        }
        guard (1.0...6.0).contains(kmh), speedRange?.contains(kmh) ?? false else { return }
        let speed = UInt8((kmh * 10).rounded())
        sendVendorTarget(speed: speed, incline: incline)
    }

    func setVendorIncline(_ percent: Int) {
        guard !workoutActive else { return }
        guard canSendVendorMotion, let speed = vendorSpeedTenths else { return }
        if vendorWritePending {
            queuedVendorAction = { [weak self] in self?.setVendorIncline(percent) }
            return
        }
        guard let lastVendorStatus, Date().timeIntervalSince(lastVendorStatus) < 10 else {
            log("设备状态已过期；请先刷新状态")
            return
        }
        guard (0...2).contains(percent), inclineRange?.contains(Double(percent)) ?? false else { return }
        sendVendorTarget(speed: speed, incline: UInt8(percent))
    }

    private func sendVendorTarget(speed: UInt8, incline: UInt8) {
        // Official-app capture: 02 53 02 1E 03 4C 03 set 3.0 km/h and 3%.
        let body: [UInt8] = [0x53, 0x02, speed, incline]
        // XOR of the payload, confirmed across captured speed/incline frames.
        let checksum = body.reduce(UInt8(0), ^)
        writeVendor([0x02] + body + [checksum, 0x03],
                    label: String(format: "麦瑞克目标 %.1f km/h、%d%%", Double(speed) / 10, incline))
        vendorTargetPending = true
    }

    private func writeVendor(_ bytes: [UInt8], label: String) {
        guard let peripheral, let vendorWriteCharacteristic, canRefreshVendorStatus,
              !vendorWritePending else { return }
        vendorWritePending = true
        watchPrivateWrite()
        log("发送 \(label)：\(hex(Data(bytes)))")
        peripheral.writeValue(Data(bytes), for: vendorWriteCharacteristic, type: .withResponse)
    }

    private func startVendorHandshakeIfReady() {
        guard vendorSubscribed, handshakeCharacteristic != nil,
              handshakeSubscribed, !vendorAuthorized, !vendorHandshakePending,
              !vendorWritePending else { return }
        vendorHandshakePending = true
        guard let peripheral, let handshakeCharacteristic else { return }
        vendorWritePending = true
        watchPrivateWrite()
        log("发送 麦瑞克私有控制握手：AA 01 00 01 55")
        peripheral.writeValue(Data([0xAA, 0x01, 0x00, 0x01, 0x55]),
                              for: handshakeCharacteristic, type: .withResponse)
    }

    private func isHandshakeService(_ service: CBService) -> Bool {
        service.uuid == handshakeServiceUUID
    }

    private func handleVendorNotification(_ data: Data) {
        let bytes = [UInt8](data)
        log("麦瑞克状态返回：\(hex(data))")
        if bytes == [0xAA, 0x01, 0x00, 0x01, 0x55] {
            log("麦瑞克私有控制握手已回显")
            return
        }
        guard bytes.count >= 5, bytes.first == 0x02, bytes.last == 0x03 else { return }
        let checksum = bytes[1..<(bytes.count - 2)].reduce(UInt8(0), ^)
        guard checksum == bytes[bytes.count - 2] else {
            log("麦瑞克状态校验失败")
            return
        }
        if bytes[1] == 0x51 {
            lastVendorResponseUptime = ProcessInfo.processInfo.systemUptime
            // Short acknowledgements are not full state reports.
            guard bytes.count >= 17 else { return }
            vendorMachineState = bytes[2]
            lastVendorReportUptime = ProcessInfo.processInfo.systemUptime
            vendorRunning = bytes[2] == 0x03
            if vendorRunning {
                let speed = Double(bytes[3]) / 10
                if liveSpeed != speed { liveSpeed = speed }
                if liveIncline != Int(bytes[4]) { liveIncline = Int(bytes[4]) }
                vendorSpeedTenths = bytes[3]
                vendorIncline = bytes[4]
                lastVendorStatus = Date()
                if appIsActive {
                    if !recorder.recording && !autoRecordingSuppressed && !workoutStopping { startRecording() }
                    recorder.observeRunning()
                }
                if let expected = workoutExpectedTarget,
                   bytes[3] == expected.speed, bytes[4] == expected.incline {
                    workoutExpectedTarget = nil
                    workoutConfirmationDeadline = nil
                    log("设备状态已确认训练阶段目标")
                }
                let text = String(format: "运行中：%.1f km/h，坡度 %d%%",
                                  Double(bytes[3]) / 10, bytes[4])
                if vendorStatusText != text { vendorStatusText = text }
            } else {
                if bytes[2] == 0x0A { autoRecordingSuppressed = false }
                liveSpeed = nil
                liveIncline = nil
                vendorSpeedTenths = nil
                if !recorder.waitingForMotion && !workoutStarting {
                    recorder.finish(reason: "跑步机已停止或倒计时；记录已保存在本机")
                }
                if !workoutStarting { pauseWorkout("跑步机已停止或处于倒计时，计划已暂停") }
                vendorIncline = nil
                lastVendorStatus = nil
                let text = bytes[2] == 0x0A ? "跑步机已停止" : bytes[2] == 0x02 ? "跑步机启动倒计时" : String(format: "未运行（状态 0x%02X）", bytes[2])
                if vendorStatusText != text { vendorStatusText = text }
            }
            if var transition = workoutMotion {
                let confirmed = transition.observe(machineState: bytes[2])
                workoutMotion = transition
                if confirmed {
                    workoutMotion = nil
                    if transition.kind == .start {
                        log("设备运行状态已确认，开始计划计时")
                        beginWorkoutTiming()
                    } else {
                        stopNeedsRetry = false
                        recorder.finish()
                        workoutMessage = "\(stopReason)；设备已确认停止"
                        log(workoutMessage)
                    }
                }
            }
        } else if bytes[1] == 0x53 {
            log("麦瑞克设置命令已回显；请核对面板实际变化")
        }
    }

    private func send(_ bytes: [UInt8], label: String) {
        guard let peripheral, let controlCharacteristic, controlSubscribed,
              !commandPending else { return }
        let opcode = bytes[0]
        pendingOpcode = opcode
        commandPending = true
        controlText = "等待回应：\(label)"
        log("发送 \(label)：\(hex(Data(bytes)))")
        peripheral.writeValue(Data(bytes), for: controlCharacteristic, type: .withResponse)

        let token = UUID()
        pendingToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.pendingToken == token, self.commandPending else { return }
            self.log("等待控制点回应超时；暂不发送下一条指令")
            self.controlText = "回应超时，请断开后重连"
            // 保持锁定，避免迟到的回应与下一条指令混淆。
        }
    }

    private func handleControlResponse(_ data: Data) {
        let bytes = [UInt8](data)
        log("控制点返回：\(hex(data))")
        guard bytes.count >= 3, bytes[0] == 0x80 else { return }
        let request = bytes[1]
        let result = bytes[2]
        guard request == pendingOpcode else {
            log("返回指令与等待中的指令不一致")
            return
        }
        pendingToken = UUID()
        pendingOpcode = nil
        commandPending = false

        let description: String
        switch result {
        case 0x01: description = "成功"
        case 0x02: description = "设备不支持此指令"
        case 0x03: description = "参数无效"
        case 0x04: description = "操作失败"
        case 0x05: description = "没有控制权限"
        default: description = String(format: "未知结果 0x%02X", result)
        }
        if request == 0x00 { controlGranted = result == 0x01 }
        if result == 0x05 {
            controlGranted = false
            if request == 0x00 { controlDenied = true }
        }
        controlText = String(format: "指令 0x%02X：%@", request, description)
        if request == 0x00 && result == 0x05 {
            log("设备拒绝 FTMS 控制权；本次连接不再重复请求。需核实厂商解锁流程")
        }
    }

    private func resetConnection() {
        let motionWasPending = workoutMotion != nil
        workoutMotion = nil
        vendorMotionWriteID = nil
        vendorMachineState = nil
        lastVendorReportUptime = nil
        autoRecordingSuppressed = false
        if motionWasPending {
            workoutPaused = workoutPlan != nil
            stopNeedsRetry = true
            workoutMessage = "启动或停机过程中连接中断，无法确认停机；请使用实体停止键"
            saveCheckpoint()
        }
        recorder.finish(reason: "连接结束；已保存观测到的运动数据，重连后可重新记录")
        treadmillDataCharacteristic = nil
        deviceDistanceMeters = nil
        deviceEnergyKcal = nil
        deviceElapsedSeconds = nil
        telemetryText = "等待运动数据连接"
        pauseWorkout("蓝牙连接中断，计划已暂停；重连后需手动继续")
        queuedVendorAction = nil
        connectionToken = UUID()
        writeToken = UUID()
        vendorStatusTimer?.invalidate()
        vendorStatusTimer = nil
        connected = false
        liveSpeed = nil
        liveIncline = nil
        controlGranted = false
        controlDenied = false
        controlSubscribed = false
        speedSupported = false
        inclineSupported = false
        commandPending = false
        pendingOpcode = nil
        pendingToken = UUID()
        controlCharacteristic = nil
        vendorWriteCharacteristic = nil
        handshakeCharacteristic = nil
        handshakeSubscribed = false
        vendorSubscribed = false
        vendorAuthorized = false
        vendorHandshakePending = false
        vendorTargetPending = false
        vendorRunning = false
        vendorSpeedTenths = nil
        vendorIncline = nil
        lastVendorStatus = nil
        lastVendorResponseUptime = nil
        vendorInitialQueryPending = false
        vendorWritePending = false
        speedRange = nil
        inclineRange = nil
        pendingReads = []
        featureText = "功能：尚未读取"
        speedRangeText = "速度范围：尚未读取"
        inclineRangeText = "坡度范围：尚未读取"
        extensionText = "厂商扩展：尚未发现"
        vendorText = "麦瑞克协议：尚未发现"
        vendorStatusText = "设备状态：尚未读取"
        currentSpeedText = "暂不订阅（连接诊断）"
        controlText = "尚未请求控制权"
        readyForMotion = false
        peripheral = nil
    }

    private func log(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.insert(CommunicationLog(line: "\(time) \(message)"), at: 0)
        if logs.count > 100 { logs.removeLast() }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func readNextCharacteristic() {
        guard let peripheral, !pendingReads.isEmpty else {
            log("设备能力读取完成")
            return
        }
        let characteristic = pendingReads.removeFirst()
        log("读取 \(characteristic.uuid)")
        peripheral.readValue(for: characteristic)
    }

    private func errorDetails(_ error: Error?) -> String {
        guard let error else { return "设备主动断开或蓝牙链路中断（系统未提供错误码）" }
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]"
    }
}

extension TreadmillBluetooth: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        connectionText = bluetoothReady ? "蓝牙已就绪" : "蓝牙不可用：\(central.state.rawValue)"
        if !bluetoothReady {
            retryWork?.cancel()
            resetConnection()
            return
        }
        // Do not scan on launch; avoid competing with the official app.
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "FTMS 设备"
        discovered[peripheral.identifier] = peripheral
        let item = DiscoveredTreadmill(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == item.id }) {
            devices[index] = item
        } else {
            devices.append(item)
        }
        if autoConnectEnabled && !autoConnectAttempted && !connected &&
            (name.caseInsensitiveCompare("MRK-T10-D59A") == .orderedSame ||
             name.uppercased().hasPrefix("MRK-T10-D59A")) {
            autoConnectAttempted = true
            autoConnectText = "已发现跑步机，正在自动连接…"
            connect(peripheral.identifier)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, appIsActive, !userDisconnected else { central.cancelPeripheralConnection(peripheral); return }
        connected = true
        connectionText = "已连接 \(peripheral.name ?? peripheral.identifier.uuidString)"
        autoConnectText = "已连接跑步机"
        log("已连接，发现服务")
        // Enumerate all services once. The handshake UUID is 128-bit and
        // appears byte-swapped in some PacketLogger views, so filtering it at
        // the discovery call would hide the actual CoreBluetooth UUID.
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        log("连接失败：\(errorDetails(error))")
        resetConnection()
        connectionText = "连接失败"
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        log("连接已断开：\(errorDetails(error))")
        resetConnection()
        connectionText = "已断开"
        scheduleReconnect()
    }
}

extension TreadmillBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error { log("发现服务失败：\(error.localizedDescription)"); return }
        let discoveredServiceNames = (peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", ")
        log("已发现服务：\(discoveredServiceNames)")
        if let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
            peripheral.discoverCharacteristics(
                [featureUUID, speedRangeUUID, inclineRangeUUID, controlUUID, statusUUID,
                 treadmillDataUUID, extensionUUID],
                for: service
            )
        } else {
            log("未找到 FTMS 1826 服务")
        }
        if let service = peripheral.services?.first(where: { $0.uuid == vendorServiceUUID }) {
            peripheral.discoverCharacteristics([vendorNotifyUUID, vendorWriteUUID], for: service)
        } else {
            vendorText = "麦瑞克协议 FFF0：未发现"
            log("未找到麦瑞克私有服务 FFF0")
        }
        if let service = peripheral.services?.first(where: { isHandshakeService($0) }) {
            peripheral.discoverCharacteristics(nil, for: service)
        } else {
            log("未找到麦瑞克握手服务 \(handshakeServiceUUID)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error { log("发现特征失败：\(error.localizedDescription)"); return }
        let characteristics = service.characteristics ?? []
        if isHandshakeService(service) {
            log("握手服务特征：\(characteristics.map { $0.uuid.uuidString }.joined(separator: ", "))")
            guard let characteristic = characteristics.first(where: {
                $0.uuid == handshakeUUID && $0.properties.contains(.write) &&
                    ($0.properties.contains(.indicate) || $0.properties.contains(.notify))
            }) else {
                log("未找到麦瑞克握手特征")
                return
            }
            handshakeCharacteristic = characteristic
            log("发现麦瑞克握手特征 \(characteristic.uuid)")
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            } else {
                startVendorHandshakeIfReady()
            }
            return
        }
        if service.uuid == vendorServiceUUID {
            vendorWriteCharacteristic = characteristics.first { $0.uuid == vendorWriteUUID &&
                $0.properties.contains(.write) }
            guard let notify = characteristics.first(where: { $0.uuid == vendorNotifyUUID &&
                $0.properties.contains(.notify) }), vendorWriteCharacteristic != nil else {
                vendorText = "麦瑞克协议：缺少 FFF1 通知或 FFF2 写入"
                log(vendorText)
                return
            }
            vendorText = "麦瑞克协议 FFF0：已发现"
            log("发现 FFF0 / FFF1 通知 / FFF2 写入")
            peripheral.setNotifyValue(true, for: notify)
            return
        }
        guard service.uuid == serviceUUID else { return }
        if let extensionCharacteristic = characteristics.first(where: { $0.uuid == extensionUUID }) {
            let writable = extensionCharacteristic.properties.contains(.write)
            extensionText = writable ? "厂商扩展：已发现，可写；解锁码未知" : "厂商扩展：已发现，未声明 Write"
            log("发现厂商扩展 \(extensionUUID)：\(writable ? "可写" : "未声明 Write")；未发送未知报文")
        } else {
            extensionText = "厂商扩展：未发现"
            log("未发现厂商扩展 \(extensionUUID)")
        }
        pendingReads = [featureUUID, speedRangeUUID, inclineRangeUUID].compactMap { uuid in
            characteristics.first { $0.uuid == uuid }
        }
        treadmillDataCharacteristic = characteristics.first { $0.uuid == treadmillDataUUID }
        if telemetryEnabled { enableTelemetry() }
        controlCharacteristic = characteristics.first { $0.uuid == controlUUID }
        guard let controlCharacteristic else {
            log("未找到控制点 2AD9")
            return
        }
        log("FTMS 特征已发现；先只订阅控制点，随后逐项读取能力")
        peripheral.setNotifyValue(true, for: controlCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error {
            if characteristic.uuid == treadmillDataUUID { telemetryText = "标准运动数据订阅失败；可记录已确认运行时长" }
            log("订阅 \(characteristic.uuid) 失败：\(error.localizedDescription)")
            return
        }
        if characteristic.uuid == treadmillDataUUID {
            telemetryText = characteristic.isNotifying ? "已订阅标准运动数据，等待设备通知" : "标准运动数据未订阅"
            log(telemetryText)
        } else if characteristic.uuid == controlUUID {
            controlSubscribed = characteristic.isNotifying
            log(controlSubscribed ? "控制点返回已订阅" : "控制点返回未订阅")
            if controlSubscribed { readNextCharacteristic() }
        } else if characteristic.uuid == vendorNotifyUUID {
            vendorSubscribed = characteristic.isNotifying
            log(vendorSubscribed ? "麦瑞克状态通知已订阅" : "麦瑞克状态通知未订阅")
            startVendorHandshakeIfReady()
        } else if characteristic == handshakeCharacteristic || characteristic.uuid == handshakeUUID {
            handshakeSubscribed = characteristic.isNotifying
            log(handshakeSubscribed ? "麦瑞克握手返回已订阅" : "麦瑞克握手返回未订阅")
            startVendorHandshakeIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error {
            log("读取 \(characteristic.uuid) 失败：\(errorDetails(error))")
            if [featureUUID, speedRangeUUID, inclineRangeUUID].contains(characteristic.uuid) {
                readNextCharacteristic()
            }
            return
        }
        guard let value = characteristic.value else {
            log("读取 \(characteristic.uuid) 返回空值")
            if [featureUUID, speedRangeUUID, inclineRangeUUID].contains(characteristic.uuid) {
                readNextCharacteristic()
            }
            return
        }
        let bytes = [UInt8](value)
        switch characteristic.uuid {
        case featureUUID:
            if bytes.count >= 8 {
                let targetFlags = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 |
                    UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
                speedSupported = targetFlags & 0x01 != 0
                inclineSupported = targetFlags & 0x02 != 0
                featureText = "速度目标：\(speedSupported ? "支持" : "不支持")；坡度目标：\(inclineSupported ? "支持" : "不支持")"
                log("功能：\(hex(value))")
            } else { log("功能数据过短：\(hex(value))") }
        case speedRangeUUID:
            if bytes.count >= 6 {
                let minimum = Double(uint16(bytes, 0)) / 100
                let maximum = Double(uint16(bytes, 2)) / 100
                let step = Double(uint16(bytes, 4)) / 100
                if minimum <= maximum { speedRange = minimum...maximum }
                speedRangeText = String(format: "速度范围：%.1f–%.1f km/h，步进 %.1f", minimum, maximum, step)
                log("速度范围：\(hex(value))")
            } else { log("速度范围数据过短：\(hex(value))") }
        case inclineRangeUUID:
            if bytes.count >= 6 {
                let minimum = Double(Int16(bitPattern: uint16(bytes, 0))) / 10
                let maximum = Double(Int16(bitPattern: uint16(bytes, 2))) / 10
                let step = Double(uint16(bytes, 4)) / 10
                if minimum <= maximum { inclineRange = minimum...maximum }
                inclineRangeText = String(format: "坡度范围：%.0f–%.0f%%，步进 %.0f%%", minimum, maximum, step)
                log("坡度范围：\(hex(value))")
            } else { log("坡度范围数据过短：\(hex(value))") }
        case controlUUID:
            handleControlResponse(value)
        case treadmillDataUUID:
            guard let metrics = TreadmillMetrics.parse(value) else { log("标准运动数据不完整：\(hex(value))"); return }
            if telemetryText != "标准运动数据已收到；缺失字段显示为 —" { telemetryText = "标准运动数据已收到；缺失字段显示为 —" }
            if let distance = metrics.distanceMeters, deviceDistanceMeters != distance { deviceDistanceMeters = distance }
            if let energy = metrics.energyKcal, deviceEnergyKcal != energy { deviceEnergyKcal = energy }
            if let elapsed = metrics.elapsedSeconds, deviceElapsedSeconds != elapsed { deviceElapsedSeconds = elapsed }
            if let speed = metrics.speed { currentSpeedText = String(format: "%.2f km/h", speed) }
            if appIsActive, vendorRunning,
               lastVendorStatus.map({ Date().timeIntervalSince($0) < 3 }) == true { recorder.ingest(metrics) }
        case statusUUID:
            log("设备状态：\(hex(value))")
        case vendorNotifyUUID:
            handleVendorNotification(value)
        case handshakeUUID:
            handleVendorNotification(value)
        default: break
        }
        if [featureUUID, speedRangeUUID, inclineRangeUUID].contains(characteristic.uuid) {
            readNextCharacteristic()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if characteristic.uuid == vendorWriteUUID {
            vendorWritePending = false
            if let error {
                queuedVendorAction = nil
                let failedMotion = workoutMotion?.kind
                workoutMotion = nil
                vendorMotionWriteID = nil
                if failedMotion != nil {
                    workoutPaused = workoutPlan != nil
                    stopNeedsRetry = true
                    workoutMessage = "启动或停止写入失败，无法确认停机；请使用实体停止键"
                    saveCheckpoint()
                }
                pauseWorkout("设备写入失败，计划已暂停")
                vendorTargetPending = false
                vendorInitialQueryPending = false
                vendorHandshakePending = false
                vendorAuthorized = false
                log("麦瑞克写入失败：\(errorDetails(error))")
                return
            }
            if let motionID = vendorMotionWriteID {
                vendorMotionWriteID = nil
                if workoutMotion?.id == motionID {
                    workoutMotion?.writeConfirmed = true
                    log("启停写入已确认；等待两次设备状态确认")
                }
            }
            if vendorTargetPending {
                vendorTargetPending = false
                log("麦瑞克目标写入已确认；等待自动查询确认设备状态")
            }
            if vendorInitialQueryPending {
                vendorInitialQueryPending = false
                refreshVendorStatus()
            }
            let action = queuedVendorAction
            queuedVendorAction = nil
            action?()
            return
        }
        if characteristic == handshakeCharacteristic || characteristic.uuid == handshakeUUID {
            vendorWritePending = false
            if let error {
                vendorHandshakePending = false
                vendorAuthorized = false
                log("麦瑞克握手写入失败：\(errorDetails(error))")
            } else {
                // The official capture confirms the write at the ATT layer;
                // some iOS/device combinations do not surface the matching
                // indication through CoreBluetooth.
                vendorHandshakePending = false
                vendorAuthorized = true
                retryCount = 0
                connectionToken = UUID()
                vendorText = "麦瑞克协议 FFF0：握手写入已确认"
                log("麦瑞克私有控制握手写入已确认；未等待额外回显")
                startVendorStatusPolling()
                if telemetryEnabled { enableTelemetry() }
            }
            return
        }
        guard let error else { return }
        log("写入失败：\(error.localizedDescription)")
        pendingToken = UUID()
        pendingOpcode = nil
        commandPending = false
        controlText = "写入失败：\(error.localizedDescription)"
    }
}
