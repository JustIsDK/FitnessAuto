# 局部 UI 检查

使用已经启动的专用 iPhone 模拟器，不要选择正在开发或有待恢复训练的模拟器：

```sh
python3 Tests/run_changed_ui.py SIMULATOR_UUID
```

脚本构建并安装 APP，再检查训练状态按钮、下一阶段／阶段表跳转、记录删除取消／确认、外部文件冷启动解析、导入取消／保存／重启持久化和无效文件提示。测试使用模拟器本机记录，未写入苹果健康。测试前备份模拟器内计划和运动记录，结束后恢复；不操作真机。

日志和 xcresult 保留在脚本输出的 `/private/tmp/fitnessauto-changed-ui-时间戳/`。训练状态截图来自 Debug 模拟器示例；文件导入使用真实 `onOpenURL` 路由，仍不能替代 AirDrop／文件分享菜单真机验收。无需执行其他 Tab 的全量 UI 检查。
