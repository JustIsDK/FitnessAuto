import Foundation
import CoreBluetooth
import Combine

final class ScaleBluetooth: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum ConnectionState { case idle, scanning, connecting, connected, notFound, failed }
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var status = "未连接" {
        didSet {
            switch status {
            case "已断开", "未连接", "体脂秤已断开，请重新连接": connectionState = .idle
            case "连接超时，请唤醒秤后重试": connectionState = .notFound
            case "寻找 AFU-WL-TZ-A1，请踩秤唤醒": connectionState = .scanning
            case "正在连接体脂秤", "正在订阅测量数据", "等待蓝牙开启": connectionState = .connecting
            case "已连接，请站稳等待测量": connectionState = .connected
            case "请在设置中允许蓝牙访问", "蓝牙不可用", "连接失败，请重试", "服务发现失败", "特征发现失败", "测量订阅失败", "未发现专用秤服务 FFB0", "未发现测量通知 FFB2": connectionState = .failed
            default: break
            }
        }
    }
    var connectionButtonTitle: String {
        switch connectionState {
        case .idle: return "连接"
        case .scanning: return "等待上秤"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .notFound: return "找不到设备 · 重试"
        case .failed: return "连接失败 · 重试"
        }
    }
    @Published private(set) var reading: ScaleReading?
    @Published private(set) var records: [WeightRecord] = []
    @Published private(set) var logs: [String] = []
    @Published private(set) var active = false
    @Published private(set) var saved = false
    @Published private(set) var compositionStatus = "未启用体脂测量"
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var wanted = false
    private var automaticScanning = false
    private var retryWork: DispatchWorkItem?

    func setAppActive(_ active: Bool) {
        automaticScanning = active
        retryWork?.cancel()
        if active {
            if !wanted { wanted = true; scanIfReady() }
        } else { stop() }
    }

    private func resumeAutomaticScan() {
        guard automaticScanning else { return }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.automaticScanning, !self.active else { return }
            self.wanted = true
            self.scanIfReady()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    private var timeout: Timer?
    private var initializationTimeout: Timer?
    private var lastReading: Date?
    private var measurementDate: Date?
    private var acknowledgedFinal = false
    private var savedRecordID: UUID?
    private var profile: ScaleProfile?
    private var pendingWrites: [(Data, String)] = []
    private var reportRequested = false
    private var reportChunks: Set<Int> = []
    private let storageKey = "fitnessauto.weight.records.v1"
    var canSave: Bool {
        active && !saved && reading?.stable == true && lastReading.map { Date().timeIntervalSince($0) < 30 } == true
    }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([WeightRecord].self, from: data) { records = decoded }
        central = CBCentralManager(delegate: self, queue: .main)
    }
    private func log(_ text: String) {
        logs.append(Date().formatted(date: .omitted, time: .standard) + " " + text)
        if logs.count > 120 { logs.removeFirst(logs.count - 120) }
    }
    func start(profile: ScaleProfile? = nil) {
        guard !wanted else { return }
        wanted = true
        connectionState = .connecting
        self.profile = profile?.valid == true ? profile : nil
        compositionStatus = "未启用体脂测量"
        reportRequested = false; reportChunks.removeAll(); pendingWrites.removeAll()
        reading = nil; saved = false; savedRecordID = nil; lastReading = nil; measurementDate = nil; acknowledgedFinal = false
        scanIfReady()
    }
    func stop() {
        wanted = false; active = false
        initializationTimeout?.invalidate(); initializationTimeout = nil
        central.stopScan(); timeout?.invalidate(); timeout = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        writer = nil; pendingWrites.removeAll(); reportRequested = false; profile = nil
        compositionStatus = "已断开"; status = "已断开"
        resumeAutomaticScan()
    }
    private func scanIfReady() {
        guard wanted else { return }
        guard !active, peripheral?.state != .connecting, peripheral?.state != .connected else { return }
        guard central.state == .poweredOn else {
            status = central.state == .unauthorized ? "请在设置中允许蓝牙访问" : "等待蓝牙开启"
            return
        }
        status = "寻找 AFU-WL-TZ-A1，请踩秤唤醒"
        log("扫描体脂秤；按设备名称匹配，不要求系统配对")
        central.scanForPeripherals(withServices: nil, options: nil)
        timeout?.invalidate()
        // In automatic mode keep waiting for a sleeping scale to advertise.
        // Only the actual connection/subscription attempt has a deadline.
        if automaticScanning { return }
        timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.stop(); self.status = "连接超时，请唤醒秤后重试"
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scanIfReady() }
        else { active = false; status = central.state == .unauthorized ? "请在设置中允许蓝牙访问" : "蓝牙不可用" }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard wanted, name.uppercased() == "AFU-WL-TZ-A1", self.peripheral?.state != .connecting else { return }
        central.stopScan(); self.peripheral = peripheral; peripheral.delegate = self
        status = "正在连接体脂秤"; log("发现 \(name)"); central.connect(peripheral)
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, !self.active else { return }
            self.stop(); self.status = "连接超时，请唤醒秤后重试"
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard wanted, self.peripheral === peripheral else { central.cancelPeripheralConnection(peripheral); return }
        reading = nil; saved = false; savedRecordID = nil; lastReading = nil
        measurementDate = nil; acknowledgedFinal = false
        status = "正在订阅测量数据"; log("已连接，发现 FFB0")
        peripheral.discoverServices([CBUUID(string: "FFB0")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        self.peripheral = nil
        stop(); status = "连接失败，请重试"; log(error?.localizedDescription ?? "连接失败")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        self.peripheral = nil
        active = false; writer = nil; pendingWrites.removeAll(); reportRequested = false; timeout?.invalidate()
        initializationTimeout?.invalidate(); initializationTimeout = nil
        compositionStatus = "已断开"
        if wanted { wanted = false; status = "体脂秤已断开，请重新连接" }
        log("连接断开：\(error?.localizedDescription ?? "设备断开")")
        resumeAutomaticScan()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { stop(); status = "服务发现失败"; log(error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "FFB0") }) else {
            stop(); status = "未发现专用秤服务 FFB0"; return
        }
        peripheral.discoverCharacteristics([CBUUID(string: "FFB1"), CBUUID(string: "FFB2")], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { stop(); status = "特征发现失败"; log(error.localizedDescription); return }
        writer = service.characteristics?.first { $0.uuid == CBUUID(string: "FFB1") }
        guard let notify = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "FFB2") }),
              notify.properties.contains(.notify) else { stop(); status = "未发现测量通知 FFB2"; return }
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard wanted else { return }
        guard error == nil, characteristic.isNotifying else { stop(); status = "测量订阅失败"; return }
        timeout?.invalidate(); active = true; status = "已连接，请站稳等待测量"; log("FFB2 通知已订阅")
        if let profile { prepareComposition(profile) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard wanted, characteristic.uuid == CBUUID(string: "FFB2"), let data = characteristic.value else { return }
        guard error == nil else { log(error!.localizedDescription); return }
        if let index = ScaleProfile.reportChunkIndex(data), reportRequested {
            reportChunks.insert(index); log("收到初始化报告分片 \(index + 1)/5")
            log("报告分片报文：" + data.map { String(format: "%02X", $0) }.joined(separator: " "))
            if reportChunks.count == 5 {
                reportRequested = false; initializationTimeout?.invalidate()
                compositionStatus = "初始化报告已接收，请离秤再裸脚站秤测量"
                enqueue(ScaleProfile.closeReport, label: "结束初始化报告")
            }
            return
        }
        guard let value = ScaleReading.decode(data) else {
            log("未解析通知：" + data.map { String(format: "%02X", $0) }.joined(separator: " ")); return
        }
        if !value.stable && reading?.stable == true { saved = false; savedRecordID = nil; acknowledgedFinal = false; measurementDate = nil }
        if value.stable && measurementDate == nil { measurementDate = Date() }
        // Keep final impedance when repeated weight notifications arrive afterwards.
        let keepImpedance = value.stable && reading?.stable == true && reading?.kilograms == value.kilograms
        let merged = ScaleReading(kilograms: value.kilograms, stable: value.stable,
                                  resistance1: value.resistance1 ?? (keepImpedance ? reading?.resistance1 : nil),
                                  resistance2: value.resistance2 ?? (keepImpedance ? reading?.resistance2 : nil))
        if reading != merged { reading = merged }
        lastReading = Date(); status = value.stable ? "体重已稳定" : "测量中，请站稳"
        if value.resistance1 != nil {
            compositionStatus = value.hasImpedance ? "已收到阻抗测量；体脂算法待验证" : "最终测量已返回，但没有有效阻抗"
            log("收到最终测量，体重 \(value.kilograms) kg；阻抗字段 \(value.resistance1 ?? 0)、\(value.resistance2 ?? 0)")
            log("最终测量报文：" + data.map { String(format: "%02X", $0) }.joined(separator: " "))
            if !acknowledgedFinal {
                acknowledgedFinal = true
                enqueue(ScaleReading.finalAcknowledgement, label: "最终测量确认")
            }
            if saved, let index = records.firstIndex(where: { $0.id == savedRecordID }),
               records[index].kilograms == value.kilograms {
                let first = records[index]
                records[index] = WeightRecord(id: first.id, date: first.date, kilograms: first.kilograms,
                                             heightCm: first.heightCm, resistance1: value.resistance1, resistance2: value.resistance2)
                persist()
            }
        }
    }
    func prepareComposition(_ profile: ScaleProfile) {
        guard active, profile.valid, let writer, writer.properties.contains(.writeWithoutResponse) else {
            compositionStatus = "请先连接，并填写完整资料"; return
        }
        guard pendingWrites.isEmpty, !reportRequested else {
            compositionStatus = "初始化进行中，请稍候"; return
        }
        self.profile = profile
        reportChunks.removeAll(); reportRequested = true; acknowledgedFinal = false
        compositionStatus = "初始化已发送后，请离秤再裸脚站秤测量"
        let labels = ["同步秤时间", "应用测量资料", "准备测量", "请求初始化报告"]
        for (index, packet) in profile.initialization().enumerated() {
            pendingWrites.append((packet, labels[index]))
        }
        drainWrites()
        initializationTimeout?.invalidate()
        initializationTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.reportRequested else { return }
            self.reportRequested = false
            self.compositionStatus = self.reading?.hasImpedance == true
                ? "已收到阻抗测量；体脂算法待验证" : "未收到完整初始化报告；可重试应用资料或导出日志"
            self.log("初始化报告等待超时")
        }
    }
    private func enqueue(_ data: Data, label: String) {
        pendingWrites.append((data, label)); drainWrites()
    }
    private func drainWrites() {
        guard wanted, active, let peripheral, let writer,
              writer.properties.contains(.writeWithoutResponse) else { return }
        while !pendingWrites.isEmpty && peripheral.canSendWriteWithoutResponse {
            let (packet, label) = pendingWrites.removeFirst()
            peripheral.writeValue(packet, for: writer, type: .withoutResponse)
            // Personal details are deliberately omitted from exported diagnostics.
            log("发送 " + label + "（20 字节）")
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { drainWrites() }
    func save(heightCm: Double?) {
        guard canSave, let reading else { status = "请等待稳定的新测量结果再保存"; return }
        records.insert(WeightRecord(date: measurementDate ?? Date(), kilograms: reading.kilograms, heightCm: heightCm,
                                   resistance1: reading.resistance1, resistance2: reading.resistance2), at: 0)
        savedRecordID = records.first?.id
        saved = true; persist(); status = "本次测量已保存"
    }
    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { records.remove(at: index) }
        persist()
    }
    func delete(ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
}
