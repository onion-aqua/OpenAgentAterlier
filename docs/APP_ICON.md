# 应用图标

当前图标来源：用户于 2026-09-09 提供的 `屏幕截图 2026-09-09 152318.png`。
用户明确允许此图片用于应用图标并随 GitHub 仓库提交；这项许可记录仅针对本图片及其生成的图标，不涉及原版游戏的其他资源，也不代表对第三方版权归属的认定。

- 原图：`assets/branding/app_icon_source.png`。
- Android：`android/app/src/main/res/mipmap-*/ic_launcher.png` 和 `drawable-*/ic_launcher_foreground.png`。
- Windows：本地工程的 `windows/runner/resources/app_icon.ico`。
- 开屏 Logo 独立使用 `agent_atelier_logo.png`，不随应用图标更换。

重新生成：安装 Pillow 后，在工程目录执行 `python scripts/generate_app_icons.py`。
脚本居中裁切为正方形，再生成多尺寸图标；Android 自适应图标由系统施加圆形或圆角遮罩。
