# 启动图片（2026-10-15）

- 来源：用户提供的 `Downloads/treadmill.svg`，1536×2730 SVG。项目将其等比栅格化为 PNG 供系统启动 storyboard 使用，图稿内容保持不变。
- 资源：`FitnessAuto/Assets.xcassets/LaunchIllustration.imageset/LaunchIllustration.png`。
- 系统启动页：`FitnessAuto/LaunchScreen.storyboard`；由现有 `UILaunchStoryboardName = LaunchScreen` 引用。
- 图片视图覆盖根视图，使用 `scaleAspectFit` 完整等比显示；不同屏幕比例的空余区域使用 `LaunchBackground` 米白色，浅色和深色一致。
- 启动页只有原图；旧标题、副标题及旧插图比例约束已移除。
- 由系统控制显示时长，不额外增加业务加载页或延时。应用内训练、蓝牙和健康权限流程沿用原逻辑。

源 SVG SHA-256：`92ec855afa54b954bf8f673a18cd6345c6c918330072e84813373332baaedfe7`。生成 PNG 使用透明背景，启动页根视图负责米白色底色。

## 验收范围

1. 构建能够编译真实启动页和新图资源；打包配置仍指向此启动页。
2. 不同屏幕比例下完整显示人物、跑步机和原图文字，图片不变形、不裁切。
3. 浅／深色补边一致，没有旧标题或旧插图。
4. pytest 全绿，功能与 UI 子代理分别给出结果。

系统启动页短暂显示，局部 UI 预览可将真实编译的 storyboard 和资源加载到独立测试 harness 中；不得通过延长生产启动时间来方便截图。预览截图与真机启动验证需要区分。

## 验证记录

- 构建号：`20261015.2`。
- 功能子代理：完整 pytest **5 passed**；iPhone 与内嵌 Watch 模拟器构建通过。
- 打包后 `UILaunchStoryboardName` 指向 `LaunchScreen`，启动 PNG 按源 SVG 渲染后保持视觉与尺寸一致。既有 JSON 文件导入声明和原位置打开标志保持正常。
- 构建日志：`/private/tmp/fitnessauto-launch-20261015-build.log`、`/private/tmp/fitnessauto-launch-20261015-build-incremental.log`。
- UI 局部实绘：加载真实编译后的 `LaunchScreen.storyboardc` 和 `Assets.car`（17:51:20 构建），393×852、375×667 及深色模式通过；只有一幅等比图片，无约束歧义和旧版标题，当前 treadmill.svg 图稿完整显示。
- 效果图：[长屏](Design/launch/launch-tall.png)、[短屏](Design/launch/launch-compact.png)、[深色](Design/launch/launch-dark.png)。这些是当前编译资源的独立预览，不代表真机启动停留时长。
- 同一构建在专用模拟器冷启动后正常进入训练页：[进入训练页](Design/launch/launch-to-training.png)。UI 报告：`/private/tmp/fitnessauto-launch-ui-20261015/report.json`。
- 功能和 UI 子代理均通过并已结束；临时测试模拟器已关闭并删除。尚未验证真机启动缓存或逐帧系统过渡。
