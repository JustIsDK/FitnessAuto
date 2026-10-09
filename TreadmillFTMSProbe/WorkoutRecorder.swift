import SwiftUI
import HealthKit

final class WorkoutRecorder: ObservableObject {
    @Published private(set) var records: [WorkoutRecord] = []
    @Published private(set) var recording = false
    @Published private(set) var waitingForMotion = false
    @Published private(set) var seconds = 0
    @Published private(set) var distanceMeters: Double?
    @Published private(set) var energyKcal: Double?
    @Published var running = false
    @Published private(set) var status = "运动记录保存在本机；写入苹果健康需要单独授权"
    @Published private(set) var saving = false
    @Published private(set) var healthAuthorized = false
    @Published private(set) var healthPartiallyAuthorized = false
    private var accumulator: WorkoutAccumulator?
    private var lastPersistedSecond = -1
    private let health = HKHealthStore()
    private let url = URL.applicationSupportDirectory.appending(path: "FitnessAuto/workouts.json")
    private struct Archive: Codable {
        var records: [WorkoutRecord]
        var draft: WorkoutRecord?
    }

    init() {
        refreshHealthAuthorization()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            records = archive.records
            if var draft = archive.draft, draft.duration > 0, !records.contains(where: { $0.id == draft.id }) {
                draft.title += " · 恢复记录"
                records.insert(draft, at: 0)
            }
        } catch { status = "运动记录读取失败：\(error.localizedDescription)" }
    }

    func start(title: String = "跑步机训练", waitingForMotion: Bool = false) {
        guard !recording else { return }
        accumulator = WorkoutAccumulator(record: WorkoutRecord(title: title, running: running))
        recording = true
        self.waitingForMotion = waitingForMotion
        seconds = 0; distanceMeters = nil; energyKcal = nil
        lastPersistedSecond = -1
        status = waitingForMotion ? "等待跑步机启动；启动后自动记录" : "记录中：只计入收到跑步机运行状态的时段"
    }

    func observeRunning() {
        guard recording else { return }
        if waitingForMotion {
            waitingForMotion = false
            status = "记录中：只计入收到跑步机运行状态的时段"
        }
        accumulator?.observe(date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        publishMetrics()
        if seconds / 5 != lastPersistedSecond / 5 || lastPersistedSecond < 0 {
            if persist() { lastPersistedSecond = seconds }
        }
    }

    func ingest(_ metrics: TreadmillMetrics) {
        guard recording else { return }
        accumulator?.metrics(metrics, uptime: ProcessInfo.processInfo.systemUptime)
        publishMetrics()
    }

    private func publishMetrics() {
        guard let record = accumulator?.record else { return }
        let elapsed = Int(record.duration)
        if seconds != elapsed { seconds = elapsed }
        if distanceMeters != record.distanceMeters { distanceMeters = record.distanceMeters }
        if energyKcal != record.energyKcal { energyKcal = record.energyKcal }
    }

    func finish(reason: String = "运动记录已结束，可在记录页写入苹果健康") {
        guard recording, let record = accumulator?.record else { return }
        if record.duration > 0, !records.contains(where: { $0.id == record.id }) { records.insert(record, at: 0) }
        recording = false
        waitingForMotion = false
        accumulator = nil
        status = reason
        _ = persist()
    }

    @discardableResult private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Archive(records: records, draft: accumulator?.record)).write(to: url, options: .atomic)
            return true
        } catch { status = "本机保存失败，请保留 APP 并重试：\(error.localizedDescription)"; return false }
    }

    private var distanceType: HKQuantityType { HKQuantityType(.distanceWalkingRunning) }
    private var energyType: HKQuantityType { HKQuantityType(.activeEnergyBurned) }
    private var shareTypes: Set<HKSampleType> { [HKObjectType.workoutType(), distanceType, energyType] }

    func refreshHealthAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthAuthorized = false
            healthPartiallyAuthorized = false
            return
        }
        let permissions = shareTypes.map { health.authorizationStatus(for: $0) == .sharingAuthorized }
        let all = permissions.allSatisfy { $0 }
        let partial = !all && permissions.contains(true)
        if healthAuthorized != all { healthAuthorized = all }
        if healthPartiallyAuthorized != partial { healthPartiallyAuthorized = partial }
    }

    @MainActor func authorize() async {
        guard HKHealthStore.isHealthDataAvailable() else { status = "此设备不支持苹果健康"; return }
        refreshHealthAuthorization()
        guard !saving, !healthAuthorized else { return }
        saving = true
        defer { refreshHealthAuthorization(); saving = false }
        do {
            try await health.requestAuthorization(toShare: shareTypes, read: [])
            refreshHealthAuthorization()
            status = healthAuthorized ? "已授权苹果健康；结束后可选择写入"
                : healthPartiallyAuthorized ? "部分权限已授权，请在健康 APP 中开启其余写入权限"
                : "未允许写入，请在健康 APP 中开启写入权限"
        } catch { status = "健康授权失败：\(error.localizedDescription)" }
    }

    @MainActor func saveToHealth(_ record: WorkoutRecord) async {
        guard !saving, !record.healthSaved, let start = record.start, let end = record.end, end > start else { return }
        guard HKHealthStore.isHealthDataAvailable() else { status = "此设备不支持苹果健康"; return }
        saving = true
        defer { refreshHealthAuthorization(); saving = false }
        do {
            try await health.requestAuthorization(toShare: shareTypes, read: [])
            var needed: [HKSampleType] = [HKObjectType.workoutType()]
            if record.distanceMeters != nil { needed.append(distanceType) }
            if record.energyKcal != nil { needed.append(energyType) }
            guard needed.allSatisfy({ health.authorizationStatus(for: $0) == .sharingAuthorized }) else {
                status = "未获得所需写入权限。请在健康 APP 的应用权限中允许运动、距离和热量后重试"
                return
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = record.running ? .running : .walking
            configuration.locationType = .indoor
            let device = HKDevice(name: "麦瑞克 X5 Ultra", manufacturer: "MERACH", model: "MRK-T10-D59A",
                                  hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                                  localIdentifier: nil, udiDeviceIdentifier: nil)
            let builder = HKWorkoutBuilder(healthStore: health, configuration: configuration, device: device)
            try await builder.beginCollection(at: start)
            try await builder.addMetadata([
                HKMetadataKeyIndoorWorkout: true,
                HKMetadataKeySyncIdentifier: "FitnessAuto.\(record.id.uuidString)",
                HKMetadataKeySyncVersion: 1,
                "FitnessAutoPlan": record.title,
                "FitnessAutoDurationSource": "Confirmed running BLE observations",
                "FitnessAutoMetricsSource": "FTMS 2ACD cumulative counter differences"
            ])
            var events: [HKWorkoutEvent] = []
            for (previous, next) in zip(record.intervals, record.intervals.dropFirst()) where next.start > previous.end {
                events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: previous.end, duration: 0), metadata: nil))
                events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: next.start, duration: 0), metadata: nil))
            }
            if !events.isEmpty { try await builder.addWorkoutEvents(events) }
            var samples: [HKQuantitySample] = []
            if let distance = record.distanceMeters, distance > 0 {
                samples.append(HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: distance),
                                                start: start, end: end, device: device,
                                                metadata: [HKMetadataKeySyncIdentifier: "\(record.id).distance", HKMetadataKeySyncVersion: 1]))
            }
            if let energy = record.energyKcal, energy > 0 {
                samples.append(HKQuantitySample(type: energyType, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: energy),
                                                start: start, end: end, device: device,
                                                metadata: [HKMetadataKeySyncIdentifier: "\(record.id).energy", HKMetadataKeySyncVersion: 1]))
            }
            if !samples.isEmpty { try await builder.addSamples(samples) }
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].healthSaved = true }
            status = "已写入苹果健康：\(record.running ? "室内跑步" : "室内步行") · \(clock(Int(record.duration)))"
            _ = persist()
        } catch { status = "写入失败，记录仍在本机，可重试：\(error.localizedDescription)" }
    }
}

struct WorkoutRecordsView: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            Section("苹果健康") {
                Text(recorder.status).font(.subheadline)
                Button(recorder.healthAuthorized ? "已授权" : recorder.healthPartiallyAuthorized ? "补充健康授权" : "授权苹果健康") {
                    Task { await recorder.authorize() }
                }.disabled(recorder.saving || recorder.healthAuthorized)
                if recorder.healthPartiallyAuthorized {
                    Text("部分写入权限未开启，可在健康 APP 的应用权限中调整。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("时长来自已确认运行的蓝牙观测；距离和热量仅使用跑步机标准运动数据。缺失字段不会猜测或写入。锁屏、断线会结束当前记录；训练继续时创建新记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("本机运动记录") {
                if recorder.records.isEmpty { Text("结束一次记录后，会显示在这里").foregroundStyle(.secondary) }
                ForEach(recorder.records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.title).font(.headline)
                        if let start = record.start { Text(start, format: .dateTime.month().day().hour().minute()).font(.caption) }
                        Text("\(record.running ? "室内跑步" : "室内步行") · \(clock(Int(record.duration)))")
                        Text(record.distanceMeters.map { String(format: "距离 %.2f km", $0 / 1000) } ?? "距离：设备未提供连续有效数据")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(record.energyKcal.map { String(format: "消耗热量 %.0f kcal", $0) } ?? "消耗热量：设备未提供连续有效数据")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(record.healthSaved ? "已写入苹果健康" : "写入苹果健康") {
                            Task { await recorder.saveToHealth(record) }
                        }.disabled(record.healthSaved || recorder.saving)
                    }.padding(.vertical, 4)
                }
            }
        }.navigationTitle("运动记录")
            .onAppear { recorder.refreshHealthAuthorization() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { recorder.refreshHealthAuthorization() }
            }
    }
}
