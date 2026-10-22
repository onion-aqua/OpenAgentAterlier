# 独立项目迁移

项目根目录为 `D:\AgentAtelier`。此目录作为后续开发入口，不再依赖原工程的 Git worktree 或源码目录。

## 当前状态

D 盘独立项目已完成复制、逐文件校验和依赖重建。当前工具的自动审批拒绝了删除旧工作区以及把旧工作区移入回滚归档的操作，仅返回 `blocked by policy`；因此原 C 盘工作区副本尚未清理。它不是新项目的依赖，后续修改应全部在 D 盘进行。在确认 Codex/IDE 已切换到新目录后，可自行清理旧工作区。

## 已迁移的内容

- 当前源代码、全部未提交修改、未跟踪文件、本地资源、文档、测试和证据。
- 本地 Spine 和 Live2D 运行库。Spine 原来指向旧工程的目录链接已改为本项目内的实体文件。
- 独立 Git 对象库和历史，当前分支为 `codex/agent-atelier`，没有配置远程仓库。
- 迁移前的构建产物和缓存保存在 `.migration-cache/`，避免旧绝对路径参与后续构建。迁移前 APK 位于 `.migration-cache/build/app/outputs/flutter-apk/app-debug.apk`。
- 本次为隔离而调整的文件，其迁移前内容保存在 `.migration-cache/source-files/`。

迁移前副本共核对 **35,366 个实体文件、9,475,797,813 字节**，SHA-256 校验一致。生成的插件目录链接不作为资源复制，已根据新目录重新生成。完整清单与最终迁移校验在 `evidence/migration/`。

## 隔离处理

- Android 继续使用独立包名 `com.ateleragent.studio`。
- Windows 可执行文件改为 `AgentAtelier.exe`，公司与产品标识为 `com.ateleragent` / `AgentAtelier`。后续 Windows 构建使用 `%APPDATA%\com.ateleragent\AgentAtelier`，不读取旧应用的设置、凭据和模型数据。
- Fish MCP 使用 `agentatelier-fishmcp://oauth/callback`，避免与旧应用抢占授权链接。新应用首次使用时重新授权。
- 发布脚本必须明确提供仓库、Tag、发布标题和说明文件，取消旧项目的默认发布目标。
- Flutter、Android SDK、Java、Pub/Gradle 缓存属于开发工具，仍使用本机安装。它们不包含对旧工程源码的依赖。

## 后续操作

在 Codex 或 IDE 中打开 `D:\AgentAtelier`。构建示例：

```powershell
Set-Location D:\AgentAtelier
.\tool\build_protected.ps1 -Target apk -Mode release -Offline
```

迁移时未发布版本或安装设备应用。历史构建产物保留在迁移归档，新产物应从本目录重新构建。

## 独立公开仓库

2026-10-22 按用户要求将公开目标设为 `https://github.com/onion-aqua/OpenAgentAterlier`。首次公开提交接续新仓库已有的 Apache-2.0 许可证提交，只包含当前可公开源码，不将旧项目历史、迁移缓存、录屏、私密配置或用户模型资源上传。原有本地历史保留在独立工程内供恢复使用。

## 验证

- 35,366 个实体文件的 SHA-256 一致；为隔离而调整的 11 个文件，其原始内容也已归档并再次校验。
- `flutter pub get --offline` 完成；本地模型运行库解析到新目录内，没有指向旧工程的插件链接。
- `flutter analyze --no-pub` 无问题。
- 204 项 Fish MCP 测试、40 项模型档案/存储/聊天服务测试通过。测试没有调用真实语音生成服务。
- 独立 Git 对象库校验通过，无 remote、objects alternates 或外部 worktree 共用目录。
