# Live2D 运行时固定补丁与构建依赖

## 已修复的发布包问题

`live2d_flutter 1.0.3` 在 `pubspec.yaml` 声明了 `assets/web/flutter_live2d_web.js` 和 Shader 目录，但其官方 pub.dev 发布归档没有这些文件。Flutter 会在 Android、Windows 和普通单元测试中统一打包依赖资产，因此即使没有使用 Web，也会因缺文件失败。

本项目改用 `third_party/live2d_flutter/` 固定源码补丁。来源是：

- 归档：`https://pub.dev/api/archives/live2d_flutter-1.0.3.tar.gz`
- SHA-256：`b16d5d861661427609a692e311f469941526d33a32912616191b8ca5efc84332`
- 实际下载体积：30,530,438 字节。

保留原插件 `lib/`、Android/iOS/macOS/Windows 插件源码、Cubism Framework 源码，以及 `web_runtime/` 的原始构建脚本、TypeScript、Framework 与 Shader 源文件；不复制 example、任何模型/立绘、上游测试、native_smoke、node_modules 或 build 产物。原始许可证、NOTICES、源文件版权说明均保留。

使用原 `web_runtime/build.mjs` 与锁文件中的 `esbuild 0.28.2`，生成真实的 642,128 字节 JavaScript 和 13 个 Shader 文件并保存到依赖声明的 `assets/web/`。这些不是占位资源；`node --check` 已通过。普通项目测试不再需要 Node，也没有关闭资产打包。

`UPSTREAM_FILES.json` 记录保留源码的本地与上游哈希。两项上游配置补丁为 `pubspec.yaml` 增加 `publish_to: none`，以及 Android 插件 NDK 与 app 对齐到 `28.2.13676358`。`RUNTIME_FILES.json` 记录生成 Web 资源及本地 Core 的精确大小和 SHA-256。`PATCHES.md` 说明完整变更。

Android 原生参数控制另有两项运行修复：嘴型等外部参数保存在当前模型的覆盖表，每帧在动作、表情、物理和姿态之后应用，避免被 `LoadParameters()` 恢复掉；关闭嘴型时明确写入 0，卸载或更换模型会清空覆盖值。待机和手动动作复用已经预加载的动作缓存，队列只借用对象，模型销毁时先停止队列再统一释放，避免每次循环重新分配且无人释放。

Windows 原生参数控制同步采用同一覆盖时序，避免桌面端嘴型同样被保存参数或动画层覆盖；本项源码修改与 Android 模拟器验收独立，仍需 Windows 原生构建与实际播放验证。

Android 与 Windows 的待机动作不再固定为 `Idle[0]`。Dart 控制器可设置模型实际存在的 group/index（包括空字符串组名）；设置只改变前台动作结束后的回落目标，不会抢占当前动作。Android 临时重建 Surface 后会恢复同一待机设置，主动加载其他模型时回到默认值并由模型映射重新设置。

Android 原生 Shader 必须从 `Shaders/StandardES` 打包到 `assets/FrameworkShaders/`（共 36 个，含 Tegra 变体）。相邻 `Shaders/Standard` 目录使用桌面 GLSL 1.20，不能用于应用创建的 OpenGL ES2 上下文；错误打包时即使 MOC 加载成功也会出现透明画面。

## 本地准备和检查

```powershell
# 准备 Android/Windows 的本地 Core，再检查真实 Web 资源
.\tool\prepare_live2d_runtime.ps1 -Platform android
.\tool\prepare_live2d_runtime.ps1 -Platform windows

# 只检查，不下载、不复制、不重新生成
.\tool\prepare_live2d_runtime.ps1 -Platform all -CheckOnly

# 可选：从已解开的精确 pub.dev 包复制 Core
.\tool\prepare_live2d_runtime.ps1 -Platform all -PublishedPackageRoot C:\path\to\live2d_flutter-1.0.3

# 可选：从原始源码重新生成 Web 资源，仍按记录哈希校验
.\tool\prepare_live2d_runtime.ps1 -Platform web -RebuildWebAssets
```

准备脚本首先校验项目内源码。缺少 Core 时，优先只读查找现有 Pub 缓存并逐文件校验；找不到符合精确指纹的文件时，从上面的固定地址下载归档到项目 `build/vendor_upstream/`，校验归档哈希之后解开。仅将需要的、逐文件哈希一致的 Core 复制到项目内忽略目录。不会修改全局 Pub 缓存，不会启动应用、编译 Android/Windows 应用或操作设备。

`-Offline` 禁止为 Core 下载归档；缺少已验证的本地文件时会明确报错。构建脚本的同名选项会传递给准备脚本。

`build_protected.ps1` 和 `run_protected.ps1` 会为对应目标调用准备脚本。私有 PC Agent 配置仍按原流程加密，release 混淆保留；内置角色模型与角色密钥不再是构建条件。

## Native 依赖与授权边界

精确 1.0.3 发布归档确实包含可用的 Core 静态库，不是 Git LFS 文本：Android 三个 ABI 的 `.a`、Windows x86_64 MSVC 143 的 MD/MDd `.lib` 和 iOS XCFramework。这里共有 12 个 Core 头文件/库/框架元数据文件，均由依赖内 `.gitignore` 排除，不上传 Git。Core 与 Framework 的 `Live2DCubismCore.hpp` 包装源码是不同文件；后者属于保留的 Framework 源码。

| 目标 | 插件声明的构建依赖 |
| --- | --- |
| Android | minSdk 24、compileSdk 36、Java 17、AGP 8.11.1、Kotlin 2.2.20、NDK 对齐到 app 的 28.2.13676358、CMake 3.22.1；原插件构建 ABI 为 arm64-v8a/x86_64 |
| Windows | Visual Studio 2022 的 MSVC 143、Windows SDK、CMake 与 Flutter Windows 工具链；D3D11/D3DCompiler/DXGI；Core MD/MDd 库 |
| Web | 已生成的 JS/Shaders；运行时仍需访问官方 `https://cubism.live2d.com/sdk-web/core/06/live2dcubismcore.min.js` |

Core 使用 Live2D Proprietary Software License；Framework/样例派生代码适用 Live2D Open Software License。BSD 插件许可不替代 Core 的许可、发行许可或用户模型授权，原 `NOTICES`、`windows/LICENSE.core.md`、`web_runtime/LICENSE.framework.md`、`LICENSE.samples.md` 提供官方条款链接。准备脚本只核对文件来源和完整性，不能认定某种商业发行已经取得许可。

app 的 minSdk 使用 `maxOf(24, flutter.minSdkVersion)`；compileSdk 37 不低于插件的 36，Java 17 一致。app 与保护构建脚本均限制为 arm64-v8a/x86_64，避免产生缺少 Live2D native 库的 32 位 APK。`android/gradle.properties` 设置 `disable-abi-filtering=true` 保留 app 自己的过滤配置，避免 Flutter 3.47 再覆盖回含 armeabi-v7a 的默认列表。Windows-only 准备会同时复制 Windows 静态库及 CMake 引用的共用 Android 目录 Core 头文件，不要求先构建 Android。

## 已验证范围

- 精确归档 SHA-256、保留源码哈希与本地 Core 文件完整性通过。
- 原 Web 构建脚本成功生成 14 个真实资产，JS 语法检查通过。
- Android/Windows 运行时只读完整性检查通过。
- 普通 `flutter test --no-pub test/local_scene_store_test.dart` 的 7 项测试通过；当前工作树缺少部分原有可选媒体目录时仍会输出对应目录提示，Live2D 缺 JS 的失败已消除。
- 没有执行 Native 应用构建、真机/模拟器安装或实际 Live2D 模型播放；这些不能由文件完整性检查或单元测试替代。
