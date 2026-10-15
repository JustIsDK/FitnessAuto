import SwiftUI
import HealthKit

// HealthKit may finish after our timeout; resume the caller exactly once.
private final class HealthOperationResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

struct HealthDuplicateReview: Identifiable {
    let record: WorkoutRecord
    let sources: String
    var id: UUID { record.id }
}

final class WorkoutRecorder: ObservableObject {
    @Published private(set) var records: [WorkoutRecord] = []
    @Published private(set) var recording = false
    @Published private(set) var waitingForMotion = false
    @Published private(set) var seconds = 0
    @Published private(set) var distanceMeters: Double?
    @Published private(set) var energyKcal: Double?
    @Published var running = false {
        didSet { accumulator?.record.running = running }
    }
    @Published private(set) var status = "运动记录保存在本机，授权后自动同步苹果健康"
    @Published private(set) var saving = false
    @Published private(set) var savingRecordID: UUID?
    @Published private(set) var healthAuthorized = false
    @Published private(set) var healthPartiallyAuthorized = false
    @Published var duplicateReview: HealthDuplicateReview?
    private var accumulator: WorkoutAccumulator?
    private var lastPersistedSecond = -1
    private var automaticSyncRunning = false
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

    func finish(reason: String = "运动记录已结束，已保存到本机") {
        guard recording, let record = accumulator?.record else { return }
        if record.duration > 0, !records.contains(where: { $0.id == record.id }) { records.insert(record, at: 0) }
        recording = false
        waitingForMotion = false
        accumulator = nil
        status = reason
        if persist() { Task { @MainActor in await syncPendingRecords() } }
    }

    @MainActor func syncPendingRecords() async {
        let preference = UserDefaults.standard.object(forKey: "fitnessauto.workout.health.auto") as? Bool ?? true
        guard preference, !automaticSyncRunning, !saving, HKHealthStore.isHealthDataAvailable() else { return }
        automaticSyncRunning = true
        defer { automaticSyncRunning = false }
        var attempted = Set<UUID>()
        while let record = records.first(where: { !$0.healthSaved && !attempted.contains($0.id) && $0.id != duplicateReview?.id }) {
            guard UserDefaults.standard.object(forKey: "fitnessauto.workout.health.auto") as? Bool ?? true else { break }
            attempted.insert(record.id)
            await saveToHealth(record, requestPermission: false, automatic: true)
        }
    }

    @discardableResult private func persist(records updated: [WorkoutRecord]? = nil) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Archive(records: updated ?? records, draft: accumulator?.record)).write(to: url, options: .atomic)
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
        status = "等待苹果健康授权…"
        defer {
            refreshHealthAuthorization(); saving = false
            Task { await syncPendingRecords() }
        }
        do {
            try await health.requestAuthorization(toShare: shareTypes, read: [HKObjectType.workoutType()])
            refreshHealthAuthorization()
            status = healthAuthorized ? "已授权苹果健康；运动记录将自动同步"
                : healthPartiallyAuthorized ? "部分权限已授权，请在健康 APP 中开启其余写入权限"
                : "未允许写入，请在健康 APP 中开启写入权限"
        } catch { status = "健康授权失败：\(error.localizedDescription)" }
    }

    @MainActor private func healthOperation<Value>(_ message: String,
        onTimeout: @escaping () -> Void = {},
        start: @escaping (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        status = message
        return try await withCheckedThrowingContinuation { continuation in
            let result = HealthOperationResult(continuation)
            let timeout = DispatchWorkItem {
                onTimeout()
                result.finish(.failure(NSError(domain: "FitnessAuto.Health", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(message)超时，请稍后重试"])))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
            start {
                timeout.cancel()
                result.finish($0)
            }
        }
    }

    @MainActor private func healthStep(_ message: String,
        start: @escaping (@escaping @Sendable (Bool, Error?) -> Void) -> Void) async throws {
        let _: Void = try await healthOperation(message) { finish in
            start { success, error in
                if let error { finish(.failure(error)) }
                else if success { finish(.success(())) }
                else { finish(.failure(NSError(domain: "FitnessAuto.Health", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(message)未完成"]))) }
            }
        }
    }

    @MainActor private func overlappingWorkouts(start: Date, end: Date) async throws -> [HKWorkout] {
        var query: HKSampleQuery?
        return try await healthOperation("正在检查重复运动…", onTimeout: { [health] in
            if let query { health.stop(query) }
        }) { [health] finish in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let request = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { finish(.failure(error)) }
                else { finish(.success(samples as? [HKWorkout] ?? [])) }
            }
            query = request
            health.execute(request)
        }
    }

    @MainActor func saveToHealth(_ record: WorkoutRecord, allowDuplicate: Bool = false,
                                 requestPermission: Bool = true, automatic: Bool = false) async {
        guard !saving, let record = records.first(where: { $0.id == record.id }),
              !record.healthSaved, let start = record.start, let end = record.end, end > start else { return }
        guard HKHealthStore.isHealthDataAvailable() else { status = "此设备不支持苹果健康"; return }
        saving = true
        savingRecordID = record.id
        var pendingBuilder: HKWorkoutBuilder?
        defer {
            refreshHealthAuthorization(); saving = false; savingRecordID = nil
            if !automatic { Task { await syncPendingRecords() } }
        }
        do {
            if requestPermission {
                status = "等待苹果健康授权…"
                try await health.requestAuthorization(toShare: shareTypes, read: [HKObjectType.workoutType()])
            }
            var needed: [HKSampleType] = [HKObjectType.workoutType()]
            if record.distanceMeters != nil { needed.append(distanceType) }
            if record.energyKcal != nil { needed.append(energyType) }
            guard needed.allSatisfy({ health.authorizationStatus(for: $0) == .sharingAuthorized }) else {
                status = "记录已保存在本机；请在设置中授权苹果健康以自动同步运动、距离和热量"
                return
            }
            let syncID = "FitnessAuto.\(record.id.uuidString)"
            if !allowDuplicate {
                let existing = try await overlappingWorkouts(start: start, end: end)
                if existing.contains(where: { $0.metadata?[HKMetadataKeySyncIdentifier] as? String == syncID }) {
                    if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].healthSaved = true }
                    status = "这条记录已存在于苹果健康，不再重复写入"
                    _ = persist()
                    return
                }
                let candidates = existing.filter {
                    [.walking, .running, .hiking].contains($0.workoutActivityType) &&
                    record.mayDuplicate(start: $0.startDate, end: $0.endDate)
                }
                if !candidates.isEmpty {
                    if automatic {
                        status = "可能已有同一次运动，已保留本机记录；可在运动记录中核对后重试同步"
                        return
                    }
                    let sources = Set(candidates.map { $0.sourceRevision.source.name }).sorted().joined(separator: "、")
                    duplicateReview = HealthDuplicateReview(record: record, sources: sources)
                    status = "发现时间重叠的运动记录，尚未写入；请确认是否重复"
                    return
                }
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = record.running ? .running : .walking
            configuration.locationType = .indoor
            let device = HKDevice(name: "麦瑞克 X5 Ultra", manufacturer: "MERACH", model: "MRK-T10-D59A",
                                  hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                                  localIdentifier: nil, udiDeviceIdentifier: nil)
            let builder = HKWorkoutBuilder(healthStore: health, configuration: configuration, device: device)
            pendingBuilder = builder
            try await healthStep("正在准备运动记录…") { builder.beginCollection(withStart: start, completion: $0) }
            try await healthStep("正在写入运动信息…") { completion in builder.addMetadata([
                HKMetadataKeyIndoorWorkout: true,
                HKMetadataKeySyncIdentifier: syncID,
                HKMetadataKeySyncVersion: 1,
                "FitnessAutoPlan": record.title,
                "FitnessAutoDurationSource": "Confirmed running BLE observations",
                "FitnessAutoMetricsSource": "FTMS 2ACD cumulative counter differences"
            ], completion: completion) }
            var events: [HKWorkoutEvent] = []
            for (previous, next) in zip(record.intervals, record.intervals.dropFirst()) where next.start > previous.end {
                events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: previous.end, duration: 0), metadata: nil))
                events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: next.start, duration: 0), metadata: nil))
            }
            if !events.isEmpty {
                let workoutEvents = events
                try await healthStep("正在写入暂停时段…") { builder.addWorkoutEvents(workoutEvents, completion: $0) }
            }
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
            if !samples.isEmpty {
                let quantities = samples
                try await healthStep("正在写入距离和热量…") { builder.add(quantities, completion: $0) }
            }
            try await healthStep("正在结束运动记录…") { builder.endCollection(withEnd: end, completion: $0) }
            try await healthStep("正在保存到苹果健康…") { completion in
                builder.finishWorkout { workout, error in completion(workout != nil, error) }
            }
            pendingBuilder = nil
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].healthSaved = true }
            status = "已写入苹果健康：\(record.running ? "室内跑步" : "室内步行") · \(clock(Int(record.duration)))"
            _ = persist()
        } catch {
            pendingBuilder?.discardWorkout()
            status = "写入未完成，记录仍在本机，可重试：\(error.localizedDescription)"
        }
    }

    @MainActor func delete(_ record: WorkoutRecord) async {
        guard !saving, records.contains(where: { $0.id == record.id }) else { return }
        saving = true
        savingRecordID = record.id
        defer {
            saving = false; savingRecordID = nil
            Task { await syncPendingRecords() }
        }
        do {
            if record.healthSaved {
                guard HKHealthStore.isHealthDataAvailable() else {
                    status = "苹果健康暂不可用，记录已保留，请稍后重试删除"; return
                }
                // Deleting by sync ID also works when HealthKit read access is denied.
                // HealthKit only permits deleting objects written by this app.
                let targets: [(HKObjectType, String)] = [
                    (distanceType, "\(record.id).distance"),
                    (energyType, "\(record.id).energy"),
                    (HKObjectType.workoutType(), "FitnessAuto.\(record.id.uuidString)")
                ]
                for (type, syncID) in targets {
                    let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                                                               operatorType: .equalTo, value: syncID)
                    try await healthStep("正在删除对应的健康数据…") { [health] completion in
                        health.deleteObjects(of: type, predicate: predicate) { success, _, error in completion(success, error) }
                    }
                }
            }
            let updated = records.filter { $0.id != record.id }
            guard persist(records: updated) else { return }
            records = updated
            if duplicateReview?.id == record.id { duplicateReview = nil }
            status = record.healthSaved ? "已删除运动记录及对应的苹果健康数据" : "已删除运动记录"
        } catch { status = "删除未完成，记录已保留，可重试：\(error.localizedDescription)" }
    }
}

struct WorkoutRecordsView: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var deletingRecord: WorkoutRecord?
    var body: some View {
        List {
            Section("运动趋势") {
                WorkoutTrendView(records: recorder.records)
            }
            Section("本机运动记录") {
                if recorder.saving { ProgressView(recorder.status) }
                else { Text(recorder.status).font(.footnote).foregroundStyle(.secondary) }
                if recorder.records.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("从第一次运动开始", systemImage: "figure.walk").font(.headline)
                        Text("跑步机停止后，本次运动记录会显示在这里。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                ForEach(recorder.records) { record in
                    HStack(alignment: .top, spacing: 10) {
                        NavigationLink(destination: WorkoutRecordDetailView(record: record)) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(record.title, systemImage: record.running ? "figure.run" : "figure.walk").font(.headline)
                                if let start = record.start { Text(start, format: .dateTime.month().day().hour().minute()).font(.caption) }
                                Text("\(record.running ? "室内跑步" : "室内步行") · \(clock(Int(record.duration)))").font(.subheadline).monospacedDigit()
                                Text(record.distanceMeters.map { String(format: "距离 %.2f km", $0 / 1000) } ?? "距离：设备未提供连续有效数据")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(record.energyKcal.map { String(format: "消耗热量 %.0f kcal", $0) } ?? "消耗热量：设备未提供连续有效数据")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button(recorder.savingRecordID == record.id ? "同步中…" : record.healthSaved ? "已同步苹果健康" : "重试同步苹果健康") {
                            Task { await recorder.saveToHealth(record) }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .disabled(record.healthSaved || recorder.saving)
                    }.padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", systemImage: "trash") { deletingRecord = record }
                            .tint(.red).disabled(recorder.saving)
                    }
                    .contextMenu {
                        Button("删除运动记录", systemImage: "trash", role: .destructive) { deletingRecord = record }
                            .disabled(recorder.saving)
                    }
                }
            }
        }.appListStyle()
            .navigationTitle("运动记录")
            .navigationBarTitleDisplayMode(.inline)
            .task { recorder.refreshHealthAuthorization(); await recorder.syncPendingRecords() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    recorder.refreshHealthAuthorization()
                    Task { await recorder.syncPendingRecords() }
                }
            }
            .alert(deletingRecord != nil ? "删除这条运动记录？" : "可能是同一段运动", isPresented: Binding(
                get: { deletingRecord != nil || recorder.duplicateReview != nil },
                set: { if !$0 { deletingRecord = nil; recorder.duplicateReview = nil } })) {
                    if let record = deletingRecord {
                        Button("取消", role: .cancel) { }
                        Button("删除", role: .destructive) { Task { await recorder.delete(record) } }
                    } else if let review = recorder.duplicateReview {
                        Button("取消写入", role: .cancel) { }
                        Button("仍然写入") { Task { await recorder.saveToHealth(review.record, allowDuplicate: true) } }
                    }
                } message: {
                    if let record = deletingRecord {
                        Text("\(record.title)\n\(record.start?.formatted(date: .abbreviated, time: .shortened) ?? "未知时间") · \(clock(Int(record.duration)))\n" +
                             (record.healthSaved ? "本机记录及本 APP 写入的对应苹果健康数据会一起删除。删除后无法恢复。" : "仅删除这条本机记录，删除后无法恢复。"))
                    } else if let review = recorder.duplicateReview {
                        Text("苹果健康中已有来自 \(review.sources) 的重叠运动记录。若是同一段运动，请取消写入，本机记录会保留。")
                    }
                }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var scale: ScaleBluetooth
    @EnvironmentObject private var recorder: WorkoutRecorder
    @EnvironmentObject private var weightHealth: WeightHealthStore
    @AppStorage("fitnessauto.weight.health.auto") private var autoWeightHealth = true
    @AppStorage("fitnessauto.workout.health.auto") private var autoWorkoutHealth = true
    @Environment(\.scenePhase) private var scenePhase
    private let unavailable = "暂无可读取数据"
    var body: some View {
        List {
            Section("开关与权限") {
                Toggle("自动同步运动到苹果健康", isOn: $autoWorkoutHealth)
                Button(recorder.healthAuthorized ? "苹果健康已授权" : "授权苹果健康") {
                    Task { await recorder.authorize() }
                }.disabled(recorder.saving || recorder.healthAuthorized)
                Text(recorder.status).font(.footnote).foregroundStyle(.secondary)

            }
            Section("个人信息") {
                LabeledContent("身高", value: weightHealth.profileHeight.map { String(format: "%.1f cm", $0) } ?? unavailable)
                LabeledContent("出生日期", value: weightHealth.profileBirthDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? unavailable)
                LabeledContent("当前年龄", value: weightHealth.profileBirthDate.map {
                    "\(Calendar.current.dateComponents([.year], from: $0, to: Date()).year ?? 0) 岁"
                } ?? unavailable)
                LabeledContent("性别", value: weightHealth.profileSex)
                LabeledContent("最近体重", value: weightHealth.profileWeight.map { String(format: "%.2f kg", $0) } ?? unavailable)
                Text(weightHealth.profileStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Section("体重管理") {
                Toggle("自动同步体重到苹果健康", isOn: $autoWeightHealth)
                Button(weightHealth.profileReadable ? "已授权" : weightHealth.profileLoading ? "正在读取…" : "允许读取健康个人资料") {
                    Task { await weightHealth.authorizeProfile() }
                }.disabled(!weightHealth.available || weightHealth.profileLoading || weightHealth.profileReadable)
                Button(weightHealth.fullyAuthorized ? "体重与 BMI 已授权" : "授权体重与 BMI") {
                    Task { await weightHealth.authorize() }
                }.disabled(weightHealth.busy || weightHealth.fullyAuthorized)
                Text(weightHealth.status).font(.footnote).foregroundStyle(.secondary)
                Text("读取不到资料时，请检查健康资料和读取权限。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("APP 信息") {
                LabeledContent("APP 构建", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")
            }
            Section("设备诊断") {
                NavigationLink(destination: DiagnosticsView()) {
                    Label("跑步机连接与诊断", systemImage: "figure.run.circle")
                }
                DisclosureGroup("体脂秤诊断日志") {
                    if scale.logs.isEmpty {
                        Text("暂无体脂秤日志").foregroundStyle(.secondary)
                    } else {
                        Text(scale.logs.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                        ShareLink(item: scale.logs.joined(separator: "\n")) {
                            Label("导出诊断日志", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .appListStyle()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await weightHealth.refreshProfile() }
        .onChange(of: autoWorkoutHealth) { _, enabled in
            if enabled { Task { await recorder.syncPendingRecords() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await weightHealth.refreshProfile() } }
        }
    }
}
