# 应用名称与图标

当前提纯版本的显示名称为 **OpenAgentAtelier**。2026-10-24 起移除原有定制应用图标和 Android 启动页角色图片。

Flutter 的固定三秒 Logo 覆盖页也已移除，启动直接进入按当前模型名称显示的加载流程。`assets/branding/` 中的旧 Logo、图标源图和 6 帧角色加载图已归档到 `.project-migration/branding-backup/2026-10-24-flutter-branding/`，8 个文件均通过 SHA-256 比对；`pubspec.yaml` 不再打包该目录。

## 系统入口

- Android 的 `AndroidManifest.xml` 不再声明 `android:icon` 或 `android:roundIcon`；保留主 Activity 的 `MAIN` / `LAUNCHER` 入口。系统桌面可能显示 Android 默认应用占位图，具体外观由桌面实现决定。
- Android 12 及以上的 `LaunchTheme` 使用透明的 `windowSplashScreenAnimatedIcon` 和纯白背景；较早系统使用纯白 `launch_background.xml`。
- Windows 不再在 `Runner.rc` 嵌入 `.ico`，窗口使用 Win32 的系统默认应用图标 `IDI_APPLICATION`，生成的程序名为 `OpenAgentAtelier.exe`。
- Android 陪伴服务继续保留中性的 `ic_companion_notification.xml`。前台服务通知需要有效的小图标，它与桌面应用图标分开管理；通知标题为 `OpenAgentAtelier`，正文由当前模型信息生成。

本次移除的是定制图片。系统仍保留正常的应用启动入口及必要通知，并可能显示自己的占位图标。

## 显示名称与数据身份

Android 显示名称修改为 `OpenAgentAtelier`，`applicationId` / namespace 继续使用 `com.ateleragent.studio`，所以在签名兼容的前提下仍属于同一应用数据空间。

Windows 的窗口标题、CMake target / EXE 文件名、`FileDescription`、`InternalName`、`OriginalFilename` 使用 `OpenAgentAtelier`。`CompanyName=com.ateleragent` 与 `ProductName=AgentAtelier` 特意保留：当前 `path_provider_windows` 和 `shared_preferences_windows` 根据这两个版本资源字段推导 `%APPDATA%\com.ateleragent\AgentAtelier` 和 `%LOCALAPPDATA%\com.ateleragent\AgentAtelier`。仅改显示名称不应让已导入模型、聊天或设置消失。此处没有实现自动搬移或读取旧 RyzaChat 应用数据。

Fish MCP URL scheme 仍为 `agentatelier-fishmcp://oauth/callback`，原生 MethodChannel 及服务协议标识保持稳定。

## 旧文件与本地备份

移出的资源先逐文件复制并通过 SHA-256 比对，随后才从活动资源目录移除。原文件和带哈希的清单位于本地归档 `.project-migration/branding-backup/2026-10-24-app-icons/`；该目录受 `.gitignore` 排除，不随源码发布。

| 原活动文件 | 数量 | 当前处理 |
| --- | ---: | --- |
| `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` | 5 | 移至本地归档 |
| `android/app/src/main/res/drawable-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_foreground.png` | 5 | 移至本地归档 |
| `android/app/src/main/res/drawable-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/launch_logo.png` | 5 | 移至本地归档 |
| `android/app/src/main/res/drawable-nodpi/launch_logo_android12.png` | 1 | 移至本地归档 |
| `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher{,_round}.xml` | 2 | 移至本地归档 |
| `android/app/src/main/res/values/colors.xml`（仅有 launcher_background） | 1 | 移至本地归档 |
| `windows/runner/resources/app_icon.ico` | 0 | 此文件原本不存在；移除残留资源引用与 ID |

此次平台改造没有增加替代品牌图片。历史原图是用户于 2026-09-09 提供的 `屏幕截图 2026-09-09 152318.png`，原文记录的使用许可仅涉及该图片及其派生图标，不延伸到其他游戏资源。备份只保留历史来源，不代表重新启用这些图片。

将来需要自定义图标时，应先确定新的中性或授权品牌素材。`scripts/generate_app_icons.py` 现在要求显式提供 `--source 新图片路径`，不会默认使用历史角色图；它只生成图片，不自动启用 Manifest / Windows resource 引用。接入时需同时维护 Android 的各密度 / 自适应图标、Manifest 引用、Windows `.ico` / resource 引用以及本文。角色头像与应用品牌图标分开，角色头像应来自当前选中模型。

## 本次验证范围

检查 Android XML 可解析、活动资源不再引用移出的图标 / 启动图片、启动入口与回调声明保留、Windows 不再引用 `IDI_APP_ICON` 或 `app_icon.ico`、19 个归档文件与哈希清单一致。未构建、启动或安装应用；桌面占位图和真实设备启动画面仍需在下次获准构建后观察。
