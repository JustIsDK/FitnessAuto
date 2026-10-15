# 项目约定

为本项目生成可导入的训练计划时，先阅读 `Docs/PlanImport.md`，按其中的 `fitnessauto.plan` v1 格式交付 UTF-8 JSON 文件。可参考 `Examples/plan-import.json`。展开全部循环阶段，核对来源、总时长、速度和坡度；不要擅自修改原计划。

计划模型和导入器分别位于 `FitnessAuto/TreadmillBluetooth.swift` 与 `FitnessAuto/PlanImport.swift`。修改格式或约束时同步更新文档、示例和 `Tests/verify_workout_data.py`，修改内置计划时验证 `Tests/verify_plans.py`。

蓝牙控制依赖已验证的麦瑞克私有报文。启动需检查设备运行状态；按用户约定，停止在对应 BLE 写入成功后结束流程，不等待或额外查询停机状态。命令已发送不代表物理停机；构建及代码测试不能代替真机验证。新增 Swift 源文件需加入 Xcode 项目的显式 Sources 引用。

修改训练页布局、启停按钮或运动记录删除交互前，先阅读 `Docs/TrainingPage.md`，并同步更新 `Docs/Design/training/` 效果图与对应验收项。仅审查本次修改区域；不得把示例状态截图当作真机启停验证。

外部 JSON 文件打开与分享导入的行为及边界见 `Docs/FileImport.md`。功能验收项需按实际证据更新，不能因存在效果图而标记完成。局部 UI 检查可运行 `python3 Tests/run_changed_ui.py SIMULATOR_UUID`，仅使用专用测试模拟器。

训练进度节点、下一阶段目标卡和运动记录图片分享规范见 `Docs/Design/TrainingAndWorkoutShare-20261015.md`。后续修改或排查均使用当前模型级别的子代理；修改后分别创建功能和 UI 测试子代理，仅验本次改动及周边约 10%，收到两者结果后才能汇报完成，结束后关闭，下次重新创建。

pytest 使用项目独立环境：`.venv/bin/python -m pytest -q`。重建方式为 `python3 -m venv .venv`、`.venv/bin/python -m pip install -r requirements-dev.txt`。pytest 必须全绿，不能把没有收集到测试当作通过；pytest 不代替局部 XCTest 和真机 BLE/健康验收。
