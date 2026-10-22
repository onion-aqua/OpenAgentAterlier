# 脸颊拉伸与触摸物理互动试验

## 操作

主聊天场景中，单指触摸人物并滑动，可以带动指尖实际碰到的原生物理部件晃动。触摸激励为最初版本的 10 倍，即此前 2.5 倍版本的 4 倍；点按、持续滑动和单帧输入上限共用同一强度倍率。慢慢移动时幅度较小，快速轻扫时更明显；停止移动后不再持续加力，抬手后由 Spine 自身的阻尼自然衰减。Windows 使用鼠标左键。

触摸头发只激发对应发束，触摸挂件只激发该挂件；脸或身体上没有原生物理的区域不带动远处部件。前景衣物或身体会挡住后面的部件，贴图透明区域和裁剪之外不算命中。滑出当前部件立即停止追加触摸输入，跨到另一个部件时重新计算输入；之前被碰过的部件仍会完成自然回弹。模型动画本身的摆动照常运行。

按住左右脸颊向外拖动，仍可使用已有的局部皮肤拉伸和松手回弹。眼眶、眼白、眼珠、睫毛、高光、眉毛及口鼻不参与脸颊变形。

上臂与手部的皮肤网格拉伸已撤掉。身体交互改为触发模型中已制作好的原生物理，包括头发、耳饰、挂件、衣摆及模型配置的其他可晃部件。没有物理约束的部位不会被强行加入摆动。静态苏菲立绘不支持这些效果。

普通点击仍保留原有语音/动作互动。双指缩放会结束单指激励；切人物、服装、存档、页面，暂停动画或切到后台时清除此次触摸输入。普通松手保留余振，避免突然停止。

## 实现

- `CharacterCamera` 独立采集按下、移动、结束。位置与点击共用场景逆变换，速度使用真实指针时间，以每秒场景宽高归一化；缩放和设备分辨率不影响速度判断。脸颊捕获拖动时仍继续采集物理输入。
- `CharacterTouchPhysicsDynamics` 平滑速度/方向，以速度软限幅控制每帧激励。30/60/120 FPS 累计激励一致；静止 80 ms 后停止持续加力，松手约 130 ms 内结束残余输入。渲染帧之间完成的快速轻扫保留一次有上限的末次移动样本，不因多次指针事件叠加爆发。
- `CharacterTouchHitMask` 在模型载入后一次性生成每页最大边 1024 的单字节透明度掩码，采样阈值为 24/255；异步读回前克隆图片，避免切服装时图片释放竞态。触摸过程中不做图片读回。
- `CharacterTouchPhysicsRig` 按实时 draw order、裁剪及透明度选择最上层命中三角形，通过重心坐标插值该处骨骼权重，再映射到最近的物理祖先骨骼。只向这些约束输入激励，已移除距离扩散和全身惯性；无物理的前景也会阻挡后景。网格拓扑权重按 attachment 缓存。
- 输入在动画应用和程序姿态调整之后、最终 `Physics.update` 之前送入当前骨架的 `PhysicsConstraint.translate`。只改变原生物理历史，不修改 root、局部动画、轨道、贴图、网格或约束的质量/阻尼参数。松手后回弹由原有 Spine 物理负责。
- 脸颊仍使用 26% 脸宽的局部影响半径、动态五官保护区和三角形面积安全限幅；每帧先恢复临时 deform，再执行原动画/物理，最后叠加脸颊皮肤变形。

## 本地运行时与构建

`packages/` 是本地单独取得的 Spine Flutter 运行时，不提交仓库。小型集成改动保存在 `tool/apply_spine_face_deform_patch.py`，包含脸颊 deform API、原生物理约束的 Dart wrapper 和重置符号映射。物理部分复用已有 C ABI，不增加原生导出。

该补丁以本项目已使用的定制 Spine 4.2 运行时为基础；已有的更新回调、`updateDelta`、绘制范围及单次物理更新基线须保留。补丁用于复现本轮集成变化，不是从官方原始运行时重建整个项目的安装器。

```powershell
python tool/apply_spine_face_deform_patch.py --check
python tool/apply_spine_face_deform_patch.py
.\tool\build_protected.ps1 -Target windows -Mode release
.\tool\build_protected.ps1 -Target apk -Mode release
```

加密构建脚本会检查并补齐这些 API，需要 Python 3。补丁先检查所有修改位置，不兼容时停止且不写入；保留运行时的其他本地改动。使用 `run_protected.ps1` 前也应先执行补丁检查/应用。

## 验证

当前七套真实 Spine 模型均有物理约束，数量分别为 47、69、48、48、45、52、68。本轮正式发布完整常规测试 1267 项通过、61 项按环境条件跳过；另启用原生运行时，30 项接口/脸颊回归及 16 项局部触摸物理回归全部通过，`flutter analyze --no-pub` 无问题。发布日志：`build/release-1.0.4-44-tests.log`、`build/release-1.0.4-44-native.log`、`build/release-1.0.4-44-analyze.log`。10 倍强度的单独数学及渲染记录见 `build/touch-tenfold-math.log`、`build/touch-tenfold-native.log`。

物理回归覆盖慢/快输入、空白区域不施力、自然阻尼、重置清理、重绑隔离，以及不改变局部骨骼、root、轨道、deform 和共享源数据。局部命中集成验证左部件受触时右约束无输入、加权网格的物理祖先映射、前景遮挡、真实贴图透明区域、动态绘制顺序、Spine 裁剪及终点、滑出停止施力、跨部件不继承旧力、初始化与同指划入。10 倍强度下，以同一动画时刻的未触摸模型为基准，快速滑动响应为慢速的约 3.37–4.96 倍，可见网格峰值位移约 35.99–86.86 模型单位；4 秒后差异低于 0.00008 模型单位。

脸颊回归覆盖七套模型、114 种眼部姿态、不同抓点和八方向大幅拖动；非皮肤五官不被变形器带动，主脸网格不翻面。对比图在 `build/face_pull_visual/`。触摸物理对比图在 `build/touch_physics_visual/`，以同一时刻的未触摸模型为基准。

复现真实原生回归（需要新运行时 Dart API、可用 DLL 和本地资源）：

```powershell
$env:PATH = "$PWD\build\windows\x64\plugins\spine_flutter\shared\Release;$env:PATH"
$env:AAR_SPINE_NATIVE_TEST = '1'
$env:AAR_FACE_PULL_RENDER = '1'
$env:AAR_TOUCH_PHYSICS_RENDER = '1'
flutter test --no-pub test/character_face_deform_native_test.dart test/character_face_pull_rig_native_test.dart test/character_touch_physics_rig_native_test.dart
```

本次未安装或操作手机，真机触摸手感和帧率尚未验证。

Android 与 Windows 的本轮 10 倍强度加密 release 均已构建成功。两个产物各含 7 个 `.aarpack` 和 7 个 `.aarpreview`，均通过 `AARENCR1` 文件头检查，没有明文角色 skel、atlas 或贴图。相关记录：`build/release-1.0.4-44-{windows,android}-audit.json`；构建日志：`build/release-1.0.4-44-{windows,android}-build.log`。

## 发布产物

- Android：`build/app/outputs/flutter-apk/app-release.apk`，包含脸颊拉伸及触摸物理。
- Windows：`build/releases/AgentAtelierR-1.0.4-windows-release-final.zip`，解压后运行 `AgentAtelierR.exe`，保留同目录 DLL 和 `data/`。

当前 APK 大小为 646220292 字节，SHA-256：`f8e71e7070c4f33727ec1d00cc9821d6467a2bb847092268d3d4c0eaf152c98a`。

本轮 Android / Windows 发布版本为 `1.0.4+44`，覆盖 GitHub 的 `v1.0.4` 正式版；发布附件与校验值见 [正式版发布说明](CHANGELOG_1.0.4.md)。
