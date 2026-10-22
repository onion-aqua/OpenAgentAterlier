# 当前资源策略（2026-10-19）

当前源码已改为用户导入 Spine / Live2D 模型，安装包只保留操纵模板和运行库；不再生成角色 `.aarpack` 或注入角色资源密钥。继续使用 build/run 脚本准备运行库、私有服务配置和混淆。当前步骤以 [模型导入说明](model_imports.md) 和 [Live2D 运行时准备](live2d_runtime_patch.md) 为准。

以下内容记录旧版内置加密人物资源流程。

# Protected character assets (historical)

Character outfits are encrypted before packaging. The APK contains only
`.aarpack` and `.aarpreview` ciphertext files. Raw Spine and preview files are
kept locally and are excluded from Git.

## Local source layout

For every outfit named `<assetName>`, provide:

```text
assets/character/ryza/<assetName>/<assetName>.atlas
assets/character/ryza/<assetName>/<assetName>.png
assets/character/ryza/<assetName>/<assetName>.skel
assets/character/ryza/<assetName>/<assetName>_gesture.json
assets/images/skins/<assetName>.png  # optional independent preview
```

If the preview is missing or is byte-identical to the Spine atlas texture, the
packer skips it. Mark that appearance with `hasPreview: false`; the picker then
shows an empty preview area instead of exposing the atlas sheet.

## Build

Do not use `flutter build` directly. The wrapper generates or reuses the local
key, refreshes every encrypted pack, injects the key at compile time, and then
builds Flutter:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode debug
powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode debug -Install
powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target appbundle -Mode release
powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target windows -Mode release
```

For development on an emulator:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\run_protected.ps1 -Device emulator-5554
```

The key is stored at `.asset_protection/character_assets.key`. Back it up
privately if installed builds must continue using the same encrypted packs.
Never commit the key, raw resources, generated packs, APKs, or symbol files.

This protection prevents direct APK extraction of usable character files. It
does not claim to prevent runtime memory inspection or a determined reverse
engineer.
