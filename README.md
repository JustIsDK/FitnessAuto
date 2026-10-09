# 跑步机 FTMS 真机验证 APP

这是给麦瑞克 X5 Ultra / 蓝牙名 `MRK-T10-D59A` 制作的 iPhone 验证工程。它支持标准 FTMS 诊断，并根据官方 APP 抓包识别麦瑞克私有服务 `FFF0`（`FFF1` 通知、`FFF2` 写入）。**它不会自行启动跑带，也不会自动执行训练计划。**

## 安装到 iPhone

1. 用 Xcode 打开 `TreadmillFTMSProbe.xcodeproj`。Xcode 已完成首次启动组件安装，工程已通过 iPhone SDK 构建。
2. 选中工程目标 `TreadmillFTMSProbe` → **Signing & Capabilities** → 勾选 **Automatically manage signing**，选择自己的 Apple Account / Personal Team。如提示 Bundle Identifier 已被占用，改成自己的唯一名称，例如 `com.yourname.TreadmillFTMSProbe`。
3. 用线连接 iPhone，在 iPhone 上开启开发者模式并信任这台 Mac；在 Xcode 顶部选择 iPhone，点击 Run。
4. 首次打开时允许蓝牙权限。免费 Personal Team 的签名有效期为 7 天，到期后需重新从 Xcode 安装。

## 验证顺序

1. 先退出麦瑞克 APP，并在 nRF Connect 中断开该设备的连接。
   如之前出现 `80 00 05`，请在 iPhone 应用切换器中彻底关闭麦瑞克 APP 和 nRF Connect，再关闭并重新打开跑步机电源，随后只打开本测试 APP。
2. 打开本 APP，点“扫描 FTMS 跑步机”，选择 `MRK-T10-D59A`。确认读到速度范围约 1.0–18.0 km/h、坡度范围约 0–25%。
3. 查看“厂商扩展”一行，点“请求控制权（不会启动跑带）”。若返回 `80 00 05`，本次连接不会重复发送请求；复制通信记录即可。
4. 让跑带上无人站立，插好安全夹，保持实体停止键可用。在跑步机面板上以最低速度启动。
5. 打开“已确认跑带无人，并已在面板上手动启动”开关。点“目标速度 1.0 km/h”，随后点“目标速度 1.5 km/h”，观察面板速度是否变化，并看 APP 是否返回成功。
6. 点“目标坡度 1%”，再点“目标坡度 0%”，观察面板坡度是否变化。
7. 点“复制通信记录”，把内容发给我；即使指令显示成功，也请说明面板和跑台是否实际变化。

此测试 APP 会在收到设备的控制点回应后才能发送下一条命令；若 8 秒未收到回应，按钮保持锁定，需要断开后重连。离开 APP 前先用跑步机实体停止键停机。

如果回应为 `80 00 05`，其含义是跑步机拒绝授予标准 FTMS 控制权。写入已到达设备，反复发送 `00` 无法代替厂商解锁流程。华为的[扩展特征文档](https://developer.huawei.com/consumer/en/doc/hmscore-guides/extension-data-0000001050145332)说明 `D18D2C10-C44C-11E8-A355-529269FB1459` 可以承载厂商定义的 6 字节解锁码，但没有公开麦瑞克 X5 Ultra 的码或证明该机采用相同流程。本验证版仅识别并记录该特征，不向其发送猜测的报文。后续需要麦瑞克提供控制协议，或在获得授权的设备上记录官方 APP 的蓝牙通信，才能确认报文和时序。

## 麦瑞克私有协议实验

官方 APP 抓包显示，调速和调坡走 `FFF0/FFF2`，不是标准 `2AD9`。当前 APP 会读取 `FFF1` 状态；只有在状态显示“运行中”、状态未超过 10 秒且你打开“已确认跑带无人，并已在面板上手动启动”后，才开放 1.0/1.5 km/h 与 0/1% 的低风险测试按钮。它不会发送官方 APP 中的启动报文。私有协议校验和来自本机抓包中已核对的帧，其他型号不要直接套用。

## 技术说明

- 扫描标准 Fitness Machine Service `1826`。
- 读取 `2ACC`、`2AD4`、`2AD5`，订阅控制点 `2AD9` 的 Indicate；识别厂商扩展 `D18D2C10-C44C-11E8-A355-529269FB1459`。当前诊断版暂不订阅跑步机数据 `2ACD`。
- 请求控制权：`00`；目标速度：`02` + 0.01 km/h 单位的小端 UInt16；目标坡度：`03` + 0.1% 单位的小端 Int16。
- 解析标准回应 `80 <请求操作码> <结果码>`。不调用 `07`（启动）或 `08`（停止）。

蓝牙协议依据：[Bluetooth SIG Fitness Machine Service](https://www.bluetooth.com/specifications/specs/fitness-machine-service-1-0-1/)；安装签名依据：[Apple Developer Account](https://developer.apple.com/help/account/basics/about-your-developer-account)。
