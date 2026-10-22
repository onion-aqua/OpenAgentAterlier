# 用户导入 Spine 场景与座椅

应用保留动作、表情与姿态的操纵模板，角色、场景和座椅的 Spine 模型不随安装包分发。角色模型由角色导入入口管理；场景与座椅由独立的 `LocalSceneStore` 管理，两类资源不会相互覆盖。

## ZIP 格式

一个 ZIP 可以包含多个场景和一个座椅。场景文件采用原路径，也可直接平铺在 ZIP 根目录：

```text
assets/scenes_runtime/stage_00_000_00_mor.atlas
assets/scenes_runtime/stage_00_000_00_mor.skel
assets/scenes_runtime/stage_00_000_00_mor.png

assets/spine/objects/obj_001/obj_001.atlas
assets/spine/objects/obj_001/obj_001.skel
assets/spine/objects/obj_001/obj_001.png
```

平铺示例：

```text
stage_00_000_00_mor.atlas
stage_00_000_00_mor.skel
stage_00_000_00_mor.png
```

场景 ID 必须是 `stage_XX_XXX_XX_mor`、`_aft`、`_eve` 或 `_ngt`，分别对应清晨、白天、傍晚和夜晚。每个场景以及座椅都必须包含同名的 `.atlas`、`.skel`、`.png` 三个文件。Atlas 只能引用同名的一张 PNG；骨架版本为 Spine 4.2。PNG 尺寸须与 Atlas 一致，单边不超过 8192 像素且总像素不超过 33,554,432。

导入器只接受上述文件，不接受角色文件、JSON、额外封面或其他文件。请将它们单独打包。ZIP 与展开后内容各不得超过 256 MB，最多 4096 个条目；不支持加密 ZIP、软链接、特殊文件、重复文件或路径穿越。ZIP CRC、实际展开长度、骨架版本、Atlas 页面和图片尺寸均会校验。

## 接入接口

```dart
final store = LocalSceneStore.instance;
await store.initialize();
final result = await store.importPackage(zipBytes);
// result.sceneIds: 本次导入的场景 ID
// result.importedSeat: 本次是否导入座椅

final sceneBundle = await store.bundleForScene(sceneId);
final chairBundle = await store.seatBundle();
```

`availableSceneIds` 为已导入场景列表，`hasSeat` 表示座椅是否存在；未知场景或未导入座椅返回 `null`。渲染时仍使用上面的原虚拟路径，将返回的 `AssetBundle` 交给 Spine 加载器。每个 Bundle 仅开放自身的三个文件，不能读取其他场景或角色。

Store 是 `ChangeNotifier`，首次初始化和每次成功导入都会通知监听者；`revision` 可用于重建渲染组件。导入已存在的 ID 会替换该 ID，其余场景和座椅保留。UI 应在未导入时显示静态背景与导入入口，并在通知后刷新；不要退回读取安装包中的旧模型。

资源保存在应用支持目录的 `imported_scenes/`。每次导入先写入临时目录，再整体提交；中断或校验失败不会改变之前可用的场景。已创建的旧 Bundle 继续读取其原来的包，避免正在显示的页面与新包混用；历史包保留在应用私有目录中。校验失败、文件缺失或损坏时，加载器会报告错误，页面应显示可恢复的导入提示。

## 构建

继续使用 `tool/build_protected.ps1` 和 `tool/run_protected.ps1`。脚本不再生成内置角色加密包，也不要求 `.asset_protection/character_assets.key`。私有 PC Agent 地址的加密准备与 release 代码混淆保持有效。

`pubspec.yaml` 已移除角色 `.aarpack`/`.aarpreview`、场景 Spine 和座椅的资源声明，只保留非 Spine 图片/JSON 及 `assets/data/spine_templates/` 操纵模板。Spine SDK 仍是运行时依赖，用户导入模型后需要它执行动画。
