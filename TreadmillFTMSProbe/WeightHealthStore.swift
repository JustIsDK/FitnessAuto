import Foundation
import Combine
import HealthKit

struct WeightDuplicateReview: Identifiable {
    let record: WeightRecord
    let sources: String
    var id: UUID { record.id }
}

@MainActor final class WeightHealthStore: ObservableObject {
    @Published private(set) var weightAuthorized = false
    @Published private(set) var bmiAuthorized = false
    @Published private(set) var busy = false
    @Published private(set) var status = "请授权体重和 BMI 写入苹果健康"
    @Published var duplicateReview: WeightDuplicateReview?
    @Published private var completed: Set<String> = []
    private let health = HKHealthStore()
    private let weightType = HKQuantityType(.bodyMass)
    private let bmiType = HKQuantityType(.bodyMassIndex)
    private let storageKey = "fitnessauto.weight.health.completed.v1"
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    var fullyAuthorized: Bool { weightAuthorized && bmiAuthorized }
    private var types: Set<HKSampleType> { [weightType, bmiType] }

    init() {
        completed = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
        refreshAuthorization()
    }
    func refreshAuthorization() {
        weightAuthorized = available && health.authorizationStatus(for: weightType) == .sharingAuthorized
        bmiAuthorized = available && health.authorizationStatus(for: bmiType) == .sharingAuthorized
    }
    private func key(_ record: WeightRecord, bmi: Bool) -> String {
        "FitnessAuto.Weight.\(record.id.uuidString).\(bmi ? "bmi" : "weight")"
    }
    func saved(_ record: WeightRecord) -> Bool {
        completed.contains(key(record, bmi: false)) && (record.bmi == nil || completed.contains(key(record, bmi: true)))
    }
    func savedText(_ record: WeightRecord) -> String {
        if saved(record) { return "已写入苹果健康" }
        if completed.contains(key(record, bmi: false)) { return "体重已写入，补写 BMI" }
        if completed.contains(key(record, bmi: true)) { return "BMI 已写入，补写体重" }
        return "写入苹果健康"
    }
    func authorize() async {
        guard available, !busy else { return }
        busy = true
        defer { busy = false; refreshAuthorization() }
        do {
            try await health.requestAuthorization(toShare: types, read: [weightType, bmiType])
            refreshAuthorization()
            status = fullyAuthorized ? "已授权体重与 BMI" : "部分权限未开启，可在健康 APP 的应用权限中调整"
        } catch { status = "健康授权失败：\(error.localizedDescription)" }
    }
    private func nearby(_ type: HKQuantityType, date: Date) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: date.addingTimeInterval(-120),
                                                       end: date.addingTimeInterval(120), options: [])
            health.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                         sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples as? [HKQuantitySample] ?? []) }
            })
        }
    }
    func save(_ record: WeightRecord, allowDuplicate: Bool = false, requestPermission: Bool = true) async {
        guard available, !busy, !saved(record), record.kilograms.isFinite,
              (1...250).contains(record.kilograms) else { return }
        busy = true
        defer { busy = false; refreshAuthorization() }
        do {
            if requestPermission { try await health.requestAuthorization(toShare: types, read: [weightType, bmiType]) }
            refreshAuthorization()
            var candidates: [(HKQuantityType, HKUnit, Double, String)] = []
            if weightAuthorized && !completed.contains(key(record, bmi: false)) {
                candidates.append((weightType, .gramUnit(with: .kilo), record.kilograms, key(record, bmi: false)))
            }
            if bmiAuthorized, let bmi = record.bmi, !completed.contains(key(record, bmi: true)) {
                candidates.append((bmiType, .count(), bmi, key(record, bmi: true)))
            }
            guard !candidates.isEmpty else {
                status = "所需健康写入权限未开启，记录仍保存在本机"; return
            }
            var duplicates: [HKQuantitySample] = []
            var toSave: [HKQuantitySample] = []
            var confirmedKeys: [String] = []
            let device = HKDevice(name: "沃莱 AFU-WL-TZ-A1", manufacturer: "ICOMON", model: "FG2313UWB-D",
                                  hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                                  localIdentifier: nil, udiDeviceIdentifier: nil)
            for (type, unit, value, syncID) in candidates {
                let existing = try await nearby(type, date: record.date)
                if existing.contains(where: { $0.metadata?[HKMetadataKeySyncIdentifier] as? String == syncID }) {
                    confirmedKeys.append(syncID); continue
                }
                duplicates.append(contentsOf: existing.filter { abs($0.quantity.doubleValue(for: unit) - value) <= 0.1 })
                toSave.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                                                start: record.date, end: record.date, device: device,
                                                metadata: [HKMetadataKeySyncIdentifier: syncID, HKMetadataKeySyncVersion: 1,
                                                           "FitnessAutoMetricSource": type == weightType ? "Scale BLE weight" : "BMI calculated from weight and recorded height"]))
            }
            remember(confirmedKeys)
            if !allowDuplicate && !duplicates.isEmpty {
                duplicateReview = WeightDuplicateReview(record: record,
                    sources: Set(duplicates.map { $0.sourceRevision.source.name }).sorted().joined(separator: "、"))
                status = "发现时间和数值接近的健康记录，尚未写入待确认的指标"
                return
            }
            if !toSave.isEmpty {
                try await health.save(toSave)
                remember(toSave.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
            }
            status = saved(record) ? (record.bmi == nil ? "体重已写入苹果健康；本条记录未填写身高，没有 BMI" : "体重和 BMI 已写入苹果健康")
                : "已写入获得授权的指标，其余指标可授权后重试"
        } catch { status = "健康写入失败，记录仍保存在本机：\(error.localizedDescription)" }
    }
    private func remember(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        completed.formUnion(keys)
        UserDefaults.standard.set(Array(completed), forKey: storageKey)
    }
}
