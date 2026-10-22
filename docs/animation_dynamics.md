# 场景风与动作惯性

参考代码：<https://github.com/zeroa234/ryza-ai-revive>，提交
`fbac9d21a809b4ed8436364b4c9449eedf8945c6`，`web/js/avatar.js`。

本次移植了姿态距离混合、手臂等级距离混合的思路，并参考其物理更新顺序、
表情稳定策略及资源风力动画接入方式。未复制该仓库的图片、模型、音频。
MIT 许可见 `third_party/ryza-ai-revive-LICENSE.txt`；原始人物资源仍独立受其许可约束。

## 实际接入

- `lib/src/character_motion_dynamics.dart`：解析资源的 `MixDurationPoses.animPoses`
  与 `armInOutPartConfig`。姿态差距越大过渡越长；缺少映射时使用保守时长。
  近距离过渡下限为 0.12 秒，避免照搬极短混合造成跳动。
- `lib/src/chat_screen.dart`：同一占用轨直接混合新旧动作；只淡出不再占用的轨道。
  保留资源编排的动作幅度、速度、坐姿兼容规则，以及基础姿势固定规则。
- 六套本地骨骼均含 `effect_wind_001`，检查到的是 `PhysicsConstraintWindTimeline`，
  不会直接位移人物根骨骼。约束数量为 47、69、48、48、45、52。
- 风占用独立轨道 17，与动作 2–10、面部 11–16 分离。采用 `MixBlend.replace`
  按 setup 值混合风力，避免照搬叠加轨导致某些运行时不断累加。
- 森林/广场风力 0.24，峡谷/山道 0.4，灯塔/海岸/风鸣谷 0.5；
  室内及未确认地点为 0。强度缓变，关闭时轨道淡出。上述数值是本 demo 的
  场景表现选择，不是原版资源提供的天气映射。修改入口：`characterWindForStage`。
- 保留骨骼现有的惯性、弹性和阻尼，让头发、衣饰响应动作和视线移动；
  不额外给头部、手臂或根骨添加振荡，不统一放大身体软组织物理。
- 风不依赖 BGM/环境音开关，也不增加 LLM 提示词或模型调用。

## 每帧执行顺序

1. 恢复上一帧的程序控制骨骼偏移，平滑更新风力。
2. 推进动画轨道，用当前语音采样设置口型时间，再应用动画。
3. 计算不含物理的世界坐标用于视线定位，叠加头部/视线局部控制。
4. 更新骨骼时间，执行且仅执行一次 `Physics.update`，随后渲染。

人物帧间隔上限 0.05 秒，避免切回前台时将长时间差一次性送入物理模拟。
这一上限只对人物控制器启用，背景和其他使用者维持原有行为。

## 检查与构建

```powershell
flutter analyze --no-pub
flutter test --no-pub
# 可选原生回归：需本地 Spine DLL 可被系统加载，以及已准备的人物资源。
$env:AAR_SPINE_NATIVE_TEST = '1'
flutter test --no-pub test/character_spine_native_test.dart
Remove-Item Env:AAR_SPINE_NATIVE_TEST
# 交付仍使用加密资源构建入口，不能改用普通 flutter build。
powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode debug
```

`tool/inspect_character_physics.cjs` 可接收 Spine 4.2 JS 文件路径和本地角色目录，
只输出约束和风时间线信息，不读取贴图。原生回归验证有限坐标、根骨无额外漂移、
回调顺序及风轨释放；这些不能代替真机视觉验收。

建议视觉验收：工坊→森林→海岸→工坊；连续切换动作组；播放长句 TTS；
触碰及视线跟随结束；切换六套服装；24/30/120 FPS；后台恢复。

## 待机调度（2026-09-15）

本轮对照参考仓库提交 `6b3a902` 的 `web/js/avatar.js`，接入低/中/高活跃度的
`ambientBindings` 权重与重复次数、眼睛模式权重、闭眼停留时间和动作组权重。
待机也会自然眨眼、转移视线并带动头部和身体；同一种视线驱动可以保持多个周期，
不会每次都随机换方向。说话与安静之间平滑过渡，语音音量峰值不驱动头部震动。
触碰、手指追踪及指定动作优先，待机动作不会强行打断。明确的零权重/空绑定不会
被随机探索重新启用，服装与坐姿的兼容过滤仍然有效。

当前本地六套服装缺少 `DriverDefs`，加密构建时仅补齐缺失部分，不替换服装的
表情和动作组。补充来源为用户本地原版手势文件，分别放在：

- `assets/character/ryza/idle_references/seated.json`：原版 `_0001_01_gesture.json`。
- `assets/character/ryza/idle_references/standing.json`：原版 `_0001_99_gesture.json`。

其他电脑如有合法准备的同版资源，可按上述位置放入，再运行保护构建脚本。
缺少补充文件时仍可构建，沿用保守的备用待机；已有 `DriverDefs` 的自定义配置
不被覆盖。补充 JSON 不进入 Git，也不以明文随 APK 分发；仅合并后的配置进入
对应的加密人物包。具体实现见 `character_idle_behavior.dart`、
`character_speech_driver.dart` 和 `tool/protect_character_assets.dart`。

## 设置导航

设置首页整理为界面与场景、声音与语音、用户设定、AI 接口、角色与世界、
数据管理、关于七个分类，具体选项进入二级页。系统返回键优先返回分类，
分类切换保留各自滚动位置；沿用原有玻璃材质和全局菜单，主页人物仍在后方运行。
设置打开时暂时隐藏后方聊天控件，避免文字与按钮透过面板干扰阅读；聊天控制器、
草稿及语音播放状态保留。
