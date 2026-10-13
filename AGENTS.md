# 项目约定

为本项目生成可导入的训练计划时，先阅读 `Docs/PlanImport.md`，按其中的 `fitnessauto.plan` v1 格式交付 UTF-8 JSON 文件。可参考 `Examples/plan-import.json`。展开全部循环阶段，核对来源、总时长、速度和坡度；不要擅自修改原计划。

计划模型和导入器分别位于 `FitnessAuto/TreadmillBluetooth.swift` 与 `FitnessAuto/PlanImport.swift`。修改格式或约束时同步更新文档、示例和 `Tests/verify_workout_data.py`，修改内置计划时验证 `Tests/verify_plans.py`。

蓝牙控制依赖已验证的麦瑞克私有报文。启停写入成功或回显不是动作完成，需检查设备状态；构建及代码测试不能代替真机验证。新增 Swift 源文件需加入 Xcode 项目的显式 Sources 引用。

修改训练页布局、启停按钮或运动记录删除交互前，先阅读 `Docs/TrainingPage.md`，并同步更新 `Docs/Design/training/` 效果图与对应验收项。仅审查本次修改区域；不得把示例状态截图当作真机启停验证。

外部 JSON 文件打开与分享导入的行为及边界见 `Docs/FileImport.md`。功能验收项需按实际证据更新，不能因存在效果图而标记完成。局部 UI 检查可运行 `python3 Tests/run_changed_ui.py SIMULATOR_UUID`，仅使用专用测试模拟器。
