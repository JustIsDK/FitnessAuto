# 局部 UI 检查

使用已经启动且尚未授权本 APP 写入苹果健康的专用 iPhone 模拟器，不要选择正在开发或有待恢复训练的模拟器：

```sh
python3 Tests/run_changed_ui.py SIMULATOR_UUID
```

脚本构建并安装 APP，再检查训练状态按钮、阶段倒计时／实际计时、下一阶段／阶段表跳转、记录删除取消／确认、外部文件冷启动解析、导入取消／保存／重启持久化和无效文件提示。测试使用模拟器本机记录，不应授权健康写入，避免示例记录自动同步；测试前备份模拟器内计划和运动记录，结束后恢复；不操作真机。

自动同步开关的局部检查为 `EditorChecks/EditorChecks/testWorkoutAutomaticSyncSetting`，在没有运动记录的专用模拟器上单独运行。检查默认开启、关闭后重启保持关闭、重新开启；结束时恢复开启状态，不验收 HealthKit 写入。批量脚本跳过此项，避免开启开关时同步示例记录。

日志和 xcresult 保留在脚本输出的 `/private/tmp/fitnessauto-changed-ui-时间戳/`。训练状态截图来自 Debug 模拟器示例；文件导入使用真实 `onOpenURL` 路由，仍不能替代 AirDrop／文件分享菜单真机验收。无需执行其他 Tab 的全量 UI 检查。
