import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject private var bluetooth: TreadmillBluetooth

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    Text("连接诊断版 2 · 控制点优先，逐项读取")
                        .font(.footnote)
                    Text(bluetooth.connectionText)
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
                    Text(bluetooth.featureText)
                    Text(bluetooth.speedRangeText)
                    Text(bluetooth.inclineRangeText)
                    Text("当前跑带速度：\(bluetooth.currentSpeedText)")
                }

                Section("控制测试") {
                    Text(bluetooth.controlText)
                    Button("① 请求控制权（不会启动跑带）") {
                        bluetooth.requestControl()
                    }
                    .disabled(!bluetooth.canRequestControl)

                    Toggle("已确认跑带无人，并已在面板上手动启动", isOn: $bluetooth.readyForMotion)

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

                Section("通信记录") {
                    Button("复制通信记录") {
                        let text = bluetooth.logs.reversed().joined(separator: "\n")
                        #if os(iOS)
                        UIPasteboard.general.string = text
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        #endif
                    }
                    .disabled(bluetooth.logs.isEmpty)
                    ForEach(Array(bluetooth.logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("跑步机 FTMS 验证")
        }
    }
}
