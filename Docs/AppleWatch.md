# Apple Watch 心率记录

## 安装和首次授权

- iPhone target：`TreadmillFTMSProbe`；Watch target：`FitnessAutoWatch Watch App`，watchOS 10 或更高。
- iPhone 构建会嵌入 Watch APP。若手表未自动安装，在 iPhone 的 Watch APP 中找到 FitnessAuto 并安装，或在 Xcode 选择 Watch scheme 与已配对手表运行。
- 第一次先打开手表上的 FitnessAuto，点击「授权并等待训练」，允许运动和心率健康权限。戴好并解锁手表。
- 此版本只在手表显示实时心率；iPhone 展示唤起/同步状态。

## 唤起与生命周期

iPhone 使用 HealthKit `HKHealthStore.startWatchApp(with:completion:)` 请求系统唤起配对手表的伴侣 APP。手表 `WKApplicationDelegate.handle(_:)` 接收运动配置。这个接口是运动 APP 自动打开手表的系统实现途径；官方麦瑞克内部实现未核实。

收到跑步机确认运行状态后启动，包括面板手动开机，不限于计划。运动类型使用记录里的室内步行/跑步选择。计划暂停只暂停自动调节，不会停止心率采集，因为跑带可能仍在运行。已确认停机、结束计划或点击结束运动记录时通知手表结束。点击手表「结束心率记录」只停止手表采集，不控制跑带。

iPhone 被电话打断、锁屏或蓝牙断开时，手表依靠 `HKWorkoutSession` 和 `workout-processing` 后台模式独立继续采集。断线期间无法判断实体停机，需在手表结束记录，或恢复 iPhone 连接后同步停机状态。iPhone 原有计划恢复和计时策略保持不变。

系统是否唤起取决于配对、安装、解锁、连接和健康权限；启动请求成功不代表传感器已经产生心率。首次权限弹窗需用户操作。应用被终止后的 Watch 运动恢复尚未实现。

## 通信与重复数据

使用 WatchConnectivity 的最新 application context 和即时消息，不使用排队的 `transferUserInfo` 播放开始/暂停命令。每段运动有独立 ID 和递增时间版本；手表唤起与重新可达时主动向 iPhone 查询当前状态，忽略旧消息。本地手表结束后，同一个运动 ID 不会再次启动。

手表用 `HKLiveWorkoutDataSource` 获取心率，以样本时间和运动 ID 生成同步标识，写入心率 `HKQuantitySample`。结束时 `discardWorkout()` 丢弃采集 builder，**不调用 `finishWorkout()` 保存第二条运动**。iPhone 仍按原有方式保存含跑步机距离/热量的唯一运动记录。两者通过健康里的时间范围共同展示，未实现将心率样本显式关联到 iPhone workout。

本功能不解决其他第三方 APP 同时写入心率；运动记录原有的重叠检查保持有效。

## 真机验收

1. 首次安装与健康授权，检查手表出现 FitnessAuto 图标和心率页面。
2. 从 iPhone 开始计划及面板手动开机，分别检查自动唤起、真实心率变化。
3. 暂停计划、锁屏、接电话，确认手表继续采集；恢复后确认不会重复启动。
4. 正常结束计划、实体停机、手表手动结束，验证结束行为。
5. 开始后立即结束、连接暂不可达再恢复，确认不会播放过时的开始命令。
6. 在苹果健康「心率」检查 FitnessAuto 来源的样本；保存 iPhone 记录后确认运动列表只新增一条运动。

构建成功只验证代码与签名，不代表已验证自动唤起、传感器采集、后台持续运行和健康同步。
