# Android 后台陪伴与通话静音

应用打开后启用后台陪伴前台服务。通知栏显示“莱莎一直陪在你的身边哦”，通知静音、不震动，点击回到应用。Android 13 及以上首次进入应用后会申请一次通知权限；拒绝后不会反复弹窗。

在 **设置 → 声音 → 后台陪伴与通话静音** 中可查看运行和静音状态、开启通知、授予可选的来电识别权限、打开厂商后台设置、恢复陪伴通知。电话权限只用于判断通话状态，不读取联系人、电话号码或录音。

## 通话期间的声音

- 使用系统通信音频模式、音频焦点和已授权时的电话状态识别通话。覆盖手机电话，以及通过这些标准信号工作的微信、QQ 等语音/视频通话。
- 普通 TTS、持续 ASMR、角色点击语音、音效、背景音乐、环境音、收藏音频及各服务试听均经过统一播放器。原生语音闹钟另有不依赖 Flutter 的相同保护。
- 通话开始时仅将本应用播放器静音；通话结束且系统重新允许播放后恢复用户最新设置的音量。通话期间新播放的内容同样静音，修改音量不会提前出声。
- 静音期间播放进度继续，不回放已过去的语音；用户已停止的内容不会在通话结束后重新启动。闹钟按当前淡入进度恢复，不修改系统闹钟/媒体音量。
- 通知中的“停止后台运行”会停止陪伴服务和当前应用音频；聊天回复文本可继续完成。重新启用请点击声音设置中的“恢复陪伴通知”。从最近任务中移除应用也停止陪伴服务，不自动复活。

第三方应用若完全不暴露通信音频模式和音频焦点，公开 Android API 无法可靠判断它的私有通话状态。常驻通知不能阻止系统强行停止、清理进程或限制后台；不使用静默音轨、强制重启或循环抢占音频焦点来保活。

## 厂商系统

后台设置入口适配小米/Redmi/POCO、华为/荣耀、OPPO/realme/一加、vivo/iQOO、三星、华硕、魅族；具体页面随 ROM 版本变化，无法打开时回退到标准应用设置。按手机提供的选项允许后台运行、关闭本应用电池限制；部分机型还需锁定最近任务。所有跳转只由用户点击触发。

使用标准前台服务和通知通道，Android 14+ 声明 `specialUse` 及用途说明；Android 15+ 在前台服务就绪后请求媒体焦点。Windows 的播放行为保持兼容，不启用安卓服务。

## 维护与验证

`AppAudioPlayer` 管理每个播放器的目标音量和活动状态，`AndroidCompanionRuntime` 与原生 `CallAudioGuard` 统一管理媒体焦点。不要新增绕开它的生产 `AudioPlayer()` 实例。

闹钟 Dart API 保持原依赖；Android 原生模块固定在 `packages/alarm_android`，由 `android/settings.gradle.kts` 选择，MIT 许可随源码保留。不能只修改 Pub 缓存。

```powershell
flutter analyze --no-pub
flutter test --no-pub test/app_audio_player_test.dart test/companion_notification_permission_test.dart test/continuous_asmr_companion_test.dart test/continuous_asmr_page_test.dart test/background_voice_test.dart test/speech_file_playback_test.dart
# 在 android 目录，用 Flutter 配置的 JDK：
.\gradlew.bat :alarm:testDebugUnitTest --offline --console=plain
# 项目根目录，加密构建：
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode release -Offline
```

自动测试覆盖多播放器静音/恢复、通话期间修改音量和新建播放器、焦点快照顺序、暂停/停止/销毁竞态、通知停止、循环完成、通知授权一次性逻辑，以及闹钟淡入恢复。模拟的焦点/通话状态不等于真实微信/QQ或各厂商 ROM 已验收；真实通话、锁屏和长时间后台仍需在对应手机上验证。
