import CoreBluetooth
import Foundation

struct DiscoveredTreadmill: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

final class TreadmillBluetooth: NSObject, ObservableObject {
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
    @Published private(set) var logs: [String] = []
    @Published private(set) var bluetoothReady = false
    @Published private(set) var connected = false
    @Published private(set) var autoConnectText = "启动后自动连接已开启"
    @Published private(set) var controlGranted = false
    @Published private(set) var controlSubscribed = false
    @Published private(set) var speedSupported = false
    @Published private(set) var inclineSupported = false
    @Published private(set) var commandPending = false
    @Published private(set) var vendorWritePending = false
    @Published var readyForMotion = false

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

    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var autoConnectEnabled = true
    private var autoConnectAttempted = false
    private var controlCharacteristic: CBCharacteristic?
    private var vendorWriteCharacteristic: CBCharacteristic?
    private var vendorSubscribed = false
    private var vendorAuthorized = false
    private var vendorHandshakePending = false
    private var vendorRunning = false
    private var vendorSpeedTenths: UInt8?
    private var vendorIncline: UInt8?
    private var lastVendorStatus: Date?
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
        canRequestControl && controlGranted && speedSupported
    }

    var canSendIncline: Bool {
        canRequestControl && controlGranted && inclineSupported
    }

    var canRefreshVendorStatus: Bool {
        connected && vendorSubscribed && vendorWriteCharacteristic != nil && !vendorWritePending
    }

    var canSendVendorMotion: Bool {
        canRefreshVendorStatus && vendorAuthorized && vendorRunning && vendorSpeedTenths != nil &&
            vendorIncline != nil && readyForMotion
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scan() {
        guard bluetoothReady else { return }
        devices = []
        discovered = [:]
        connectionText = "正在扫描 FTMS 设备…"
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        log("扫描服务 1826")
    }

    func connect(_ id: UUID) {
        guard let device = discovered[id] else { return }
        central.stopScan()
        peripheral = device
        device.delegate = self
        connectionText = "正在连接 \(device.name ?? id.uuidString)…"
        central.connect(device, options: nil)
    }

    func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func requestControl() {
        guard canRequestControl else { return }
        send([0x00], label: "请求控制权")
    }

    func setSpeed(_ kmh: Double) {
        guard readyForMotion && canSendSpeed else { return }
        if let speedRange, !speedRange.contains(kmh) {
            log("速度 \(kmh) km/h 超出设备范围")
            return
        }
        let raw = UInt16((kmh * 100).rounded())
        send([0x02, UInt8(raw & 0xff), UInt8(raw >> 8)],
             label: String(format: "目标速度 %.1f km/h", kmh))
    }

    func setIncline(_ percent: Double) {
        guard readyForMotion && canSendIncline else { return }
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
        guard canRefreshVendorStatus else { return }
        writeVendor([0x02, 0x51, 0x51, 0x03], label: "读取麦瑞克设备状态")
    }

    func setVendorSpeed(_ kmh: Double) {
        guard canSendVendorMotion, let incline = vendorIncline else { return }
        guard let lastVendorStatus, Date().timeIntervalSince(lastVendorStatus) < 10 else {
            log("设备状态已过期；请先刷新状态")
            return
        }
        guard (1.0...1.5).contains(kmh), speedRange?.contains(kmh) ?? false else { return }
        let speed = UInt8((kmh * 10).rounded())
        sendVendorTarget(speed: speed, incline: incline)
    }

    func setVendorIncline(_ percent: Int) {
        guard canSendVendorMotion, let speed = vendorSpeedTenths else { return }
        guard let lastVendorStatus, Date().timeIntervalSince(lastVendorStatus) < 10 else {
            log("设备状态已过期；请先刷新状态")
            return
        }
        guard (0...1).contains(percent), inclineRange?.contains(Double(percent)) ?? false else { return }
        sendVendorTarget(speed: speed, incline: UInt8(percent))
    }

    private func sendVendorTarget(speed: UInt8, incline: UInt8) {
        // Official-app capture: 02 53 02 1E 03 4C 03 set 3.0 km/h and 3%.
        let body: [UInt8] = [0x53, 0x02, speed, incline]
        // Checksum observed in the official-app capture: (0xC2 - sum(body)) & 0xFF.
        let checksum = UInt8(truncatingIfNeeded: 0xC2 - Int(body.reduce(0) { $0 + Int($1) }))
        writeVendor([0x02] + body + [checksum, 0x03],
                    label: String(format: "麦瑞克目标 %.1f km/h、%d%%", Double(speed) / 10, incline))
        lastVendorStatus = nil
    }

    private func writeVendor(_ bytes: [UInt8], label: String) {
        guard let peripheral, let vendorWriteCharacteristic, canRefreshVendorStatus else { return }
        vendorWritePending = true
        log("发送 \(label)：\(hex(Data(bytes)))")
        peripheral.writeValue(Data(bytes), for: vendorWriteCharacteristic, type: .withResponse)
    }

    private func handleVendorNotification(_ data: Data) {
        let bytes = [UInt8](data)
        log("麦瑞克状态返回：\(hex(data))")
        if bytes == [0xAA, 0x01, 0x00, 0x01, 0x55] {
            vendorHandshakePending = false
            vendorAuthorized = true
            vendorText = "麦瑞克协议 FFF0：已握手"
            log("麦瑞克私有控制握手已回显")
            refreshVendorStatus()
            return
        }
        guard bytes.count >= 5, bytes.first == 0x02, bytes.last == 0x03 else { return }
        let checksum = bytes[1..<(bytes.count - 2)].reduce(UInt8(0), ^)
        guard checksum == bytes[bytes.count - 2] else {
            log("麦瑞克状态校验失败")
            return
        }
        if bytes[1] == 0x51, bytes.count >= 7 {
            vendorRunning = bytes[2] == 0x03
            if vendorRunning {
                vendorSpeedTenths = bytes[3]
                vendorIncline = bytes[4]
                lastVendorStatus = Date()
                vendorStatusText = String(format: "运行中：%.1f km/h，坡度 %d%%",
                                          Double(bytes[3]) / 10, bytes[4])
            } else {
                vendorSpeedTenths = nil
                vendorIncline = nil
                lastVendorStatus = nil
                vendorStatusText = String(format: "未运行（状态 0x%02X）", bytes[2])
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
        connected = false
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
        vendorSubscribed = false
        vendorAuthorized = false
        vendorHandshakePending = false
        vendorRunning = false
        vendorSpeedTenths = nil
        vendorIncline = nil
        lastVendorStatus = nil
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
        logs.insert("\(time) \(message)", at: 0)
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
        if bluetoothReady && autoConnectEnabled && !connected {
            autoConnectAttempted = false
            autoConnectText = "正在自动扫描 MRK-T10-D59A…"
            scan()
        }
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
        connected = true
        connectionText = "已连接 \(peripheral.name ?? peripheral.identifier.uuidString)"
        autoConnectText = "已自动连接跑步机"
        log("已连接，发现服务")
        peripheral.discoverServices([serviceUUID, vendorServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("连接失败：\(errorDetails(error))")
        resetConnection()
        connectionText = "连接失败"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("连接已断开：\(errorDetails(error))")
        resetConnection()
        connectionText = "已断开"
    }
}

extension TreadmillBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("发现服务失败：\(error.localizedDescription)"); return }
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
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("发现特征失败：\(error.localizedDescription)"); return }
        let characteristics = service.characteristics ?? []
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
        if let error { log("订阅 \(characteristic.uuid) 失败：\(error.localizedDescription)"); return }
        if characteristic.uuid == controlUUID {
            controlSubscribed = characteristic.isNotifying
            log(controlSubscribed ? "控制点返回已订阅" : "控制点返回未订阅")
            if controlSubscribed { readNextCharacteristic() }
        } else if characteristic.uuid == vendorNotifyUUID {
            vendorSubscribed = characteristic.isNotifying
            log(vendorSubscribed ? "麦瑞克状态通知已订阅" : "麦瑞克状态通知未订阅")
            if vendorSubscribed {
                // Captured official-app sequence: establish private control
                // handshake before querying status or sending target values.
                vendorHandshakePending = true
                writeVendor([0xAA, 0x01, 0x00, 0x01, 0x55], label: "麦瑞克私有控制握手")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
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
            if bytes.count >= 4, bytes[0] & 0x01 == 0 {
                let speed = Double(uint16(bytes, 2)) / 100
                currentSpeedText = String(format: "%.2f km/h", speed)
            }
        case statusUUID:
            log("设备状态：\(hex(value))")
        case vendorNotifyUUID:
            handleVendorNotification(value)
        default: break
        }
        if [featureUUID, speedRangeUUID, inclineRangeUUID].contains(characteristic.uuid) {
            readNextCharacteristic()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == vendorWriteUUID {
            vendorWritePending = false
            if let error {
                vendorInitialQueryPending = false
                vendorHandshakePending = false
                vendorAuthorized = false
                log("麦瑞克写入失败：\(errorDetails(error))")
                return
            }
            if vendorInitialQueryPending {
                vendorInitialQueryPending = false
                refreshVendorStatus()
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
