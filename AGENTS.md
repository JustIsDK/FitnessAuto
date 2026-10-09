# 项目约定

为本项目生成可导入的训练计划时，先阅读 `Docs/PlanImport.md`，按其中的 `fitnessauto.plan` v1 格式交付 UTF-8 JSON 文件。可参考 `Examples/plan-import.json`。展开全部循环阶段，核对来源、总时长、速度和坡度；不要擅自修改原计划。

计划模型和导入器分别位于 `TreadmillFTMSProbe/TreadmillBluetooth.swift` 与 `TreadmillFTMSProbe/PlanImport.swift`。修改格式或约束时同步更新文档、示例和 `Tests/verify_workout_data.py`，修改内置计划时验证 `Tests/verify_plans.py`。

蓝牙控制依赖已验证的麦瑞克私有报文。启停写入成功或回显不是动作完成，需检查设备状态；构建及代码测试不能代替真机验证。新增 Swift 源文件需加入 Xcode 项目的显式 Sources 引用。
