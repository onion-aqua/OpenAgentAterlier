# OpenAgentAtelier

基于 Flutter 的 AI 角色互动框架。用户自行导入模型，将对话、记忆、语音、动作和表情接到同一角色档案。应用名称为 **AgentAtelier**，Android 包名为 `com.ateleragent.studio`；Dart 包名 `ryza_chat_mvp` 为兼容已有代码暂时保留。

**当前为早期开发测试版，版本 `1.0.0+1`。** 下载见 [Releases](https://github.com/onion-aqua/OpenAgentAterlier/releases)。本次提供 Android Debug APK，调试模式可能造成运行不流畅、耗电增加或不稳定，请先备份数据。Windows 共用源码仍在适配，本次没有提供新的 Windows 安装包。

## 当前功能

- 流式文字对话、旁白与台词分段、独立翻译及译文历史；支持 OpenAI 兼容接口和 Gemini Interactions，具体能力取决于所配置服务。
- 每个导入模型独立保存人物设定、用户设定、世界设定、对话、记忆、状态、音色和存档；切换模型会同步名称、头像、提示词与陪伴通知。
- 导入前扫描模型资源目录，使用用户配置的 LLM 生成动作与表情语义映射，经审阅和校验后接入播放器。映射只能使用模型已有能力，不能创造不存在的动作。
- 本地追加式记忆、召回和手动整理；模型与档案可导出为 ZIP，普通聊天备份不包含模型资源。
- 虚拟手机承载模型、状态、存档、设置与 PC Agent 等入口。没有配置世界内容时，不自动套用旧地图、商店、天气或 NPC。
- 可选在线 TTS、普通/ASMR 独立音色、固定位置立体声与持续 ASMR。Fish Audio 支持 REST 和 OAuth MCP；Drama 3 通过 Story Studio 路径配置。Android arm64 另有 CosyVoice 3 本地语音入口。
- PC Agent 扫码配对、问题审批、回答、任务和离线补拉；需自行配置受信任 HTTPS 中继及兼容的桌面端。后台推送还需要真实平台配置。

## 模型支持范围

| 格式 | 当前状态 |
| --- | --- |
| Spine 4.2 JSON / binary | 导入、映射与原生播放 |
| Spine 3.6 JSON | Android 离线 WebGL 播放；其他平台及 3.6 binary 暂不支持 |
| Live2D Cubism model3 | ZIP 导入、动作/表情映射和参数控制 |
| VRM 0.x / 1.0 | 仅资源目录分析及映射接口，尚无渲染器，不能作为可播放模型导入 |

安装包不内置 Spine 或 Live2D 人物模型。不同模型的动作、嘴型与物理效果取决于自身资源和映射；通用模型不会自动获得原有专用模板的全部演出能力。

## 开始使用

1. 从 Releases 下载 Debug APK，安装后打开 AgentAtelier。建议先备份已有模型和数据。
2. 在设置中填写 LLM 地址、模型和密钥，先测试文字对话。
3. 通过主界面导入入口、模型库或「设置 → 模型档案与数据」选择模型 ZIP。检查目录，生成并审阅语义映射，再确认导入。
4. 编辑该模型的人物、用户与世界设定。需要语音时自行配置 TTS 和音色，先用短句试听。
5. 使用「导出模型与数据 ZIP」迁移角色档案。服务密钥不会写入模型 ZIP；普通 JSON 导出若主动选择包含密钥，所得文件为明文，勿公开上传。

映射生成、在线对话、翻译和在线语音可能产生服务费用。导入分析发送资源目录及必要结构摘要，不发送贴图和完整网格；聊天与记忆会按请求发送至用户配置的服务。本地优先不代表全部离线。

## 开发与构建

```powershell
git clone https://github.com/onion-aqua/OpenAgentAterlier.git
cd OpenAgentAterlier
flutter doctor -v
```

Dart 约束为 `^3.13.2`。Android 需要相匹配的 Flutter、JDK、Android SDK/NDK；Windows 另需 Visual Studio C++ 桌面工具与 Windows SDK。

仓库不提供用户角色模型、私人服务配置、专有素材或完整 Spine Runtime。构建前需按各自许可在本项目 `packages/spine_flutter/` 准备兼容运行库及所需本地非模型资源，不能链接回旧工程。Live2D 补丁源码位于 `third_party/live2d_flutter/`，Core 由准备脚本校验并获取，不直接提交 Git。详见 [Live2D 运行库](docs/live2d_runtime_patch.md) 和 [资源边界](docs/PROTECTED_CHARACTER_ASSETS.md)。

统一使用项目脚本构建，脚本负责运行库准备和可选的本地私有配置：

```powershell
# Android Debug
pwsh -File .\tool\build_protected.ps1 -Target apk -Mode debug

# Android Release
pwsh -File .\tool\build_protected.ps1 -Target apk -Mode release

# Windows Release
pwsh -File .\tool\build_protected.ps1 -Target windows -Mode release
```

APK 输出在 `build/app/outputs/flutter-apk/`。`-Offline` 使用已准备好的本地依赖；默认不安装设备应用。调试签名仅用于当前测试，不是应用商店发布签名。

## 文档

- [模型导入与格式限制](docs/model_imports.md)
- [LLM 语义映射](docs/model_mapping.md)
- [模型独立档案与备份范围](docs/model_workspaces.md)
- [当前角色身份与兼容边界](docs/character_identity.md)
- [Live2D 接入](docs/live2d_integration.md) · [Spine 场景导入](docs/external_spine_scenes.md)
- [记忆框架](docs/memory_framework.md) · [语言与上下文](docs/chat_language_and_context.md)
- [Fish Audio MCP](docs/fish_mcp_integration.md) · [本地 TTS](docs/LOCAL_TTS_SETUP.md)
- [PC Agent 联动](docs/relay/PC-Agent联动使用说明.md)

历史文档可能仍描述旧人物与阶段性实现，以当前源码及以上模型文档为准。项目由 AgentAtelierR 演进，旧解析别名、存储 ID 和兼容模板仍保留；不批量改写用户的历史对话。

## 许可与反馈

本项目自有代码按根目录 [Apache-2.0](LICENSE) 发布；第三方文件保留各自许可和版权，根目录许可证不替代它们。Spine Runtime、Live2D Core/Framework、本地语音组件及用户模型分别适用各自条款。模型、贴图、声音及其他媒体需由使用者取得授权，仓库代码不授予原作品素材的再分发权。

反馈请附平台、版本、复现步骤与预期结果；接口日志应先脱敏，勿上传 API Key、私人聊天、录屏或未授权模型。早期版本建议在测试设备使用，并定期导出模型及数据。
