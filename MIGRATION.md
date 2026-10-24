# 提纯版本迁移记录

2026-10-24，按用户要求将“提纯版本”对话对应的独立项目，从 `D:\AgentAtelier` 整理至 **`D:\OpenAgentAtelier`**。新目录是后续开发入口。

- 对话：`codex://threads/01a14f38-a95d-76e1-8845-d95fef4eaab6`，标题“提纯版本”。
- 唯一主来源：`D:\AgentAtelier`，`main` 提交 `e442dd6e44c99ca70c5e3c29cca73df4157e1d74`。
- Android 包名 `com.ateleragent.studio`，版本 `1.0.0+1`；Dart 包名暂保留 `ryza_chat_mvp` 以兼容代码。
- 原始 `D:\Ryza_chat\ryza_chat_mvp` 不是本次迁移的源码来源，也不属于旧副本删除范围。

## 保留范围

保留当前源代码、测试、Android/Windows 工程、完整本地素材、文档、构建脚本、锁文件、本地配置、Spine/Live2D 实体运行库及独立 `.git` 对象库。1,372 个 Git 跟踪文件全部纳入复制。

共复制并逐文件 SHA-256 核对 **6,228 个文件、4,896,203,576 字节**。交付 APK、混淆符号、测试报告、历史测试输入移到 `.project-migration/preserved-builds/`，不放入新工程的活动 `build/`。

排除 55,689 个可重建的构建中间文件和缓存（11,805,580,133 字节）；旧绝对路径的 Flutter 元数据、Windows 插件链接不复制。在新目录重新解析依赖。

清单与复制证据：`.project-migration/migration-manifest.json`；完整缓存排除列表也保存在该文件。原迁移文档及这次更改的入口文档原件保存在 `.project-migration/source-before-relocation/`。

## 旧副本

`D:\AgentAtelier` 和 `C:\Users\cheny\.codex\worktrees\c7c4\ryza_chat_mvp` 保留在原处，通过醒目的说明文件标识。此次操作不删除、移动或重命名原目录。

旧 C 盘 worktree 仅供审计及历史差异备份，不覆盖提纯版。其 `packages/spine_flutter` 是指向原始工程的目录链接；新项目中该依赖为实体文件。删除旧副本时只针对列出的目录，不沿链接清理目标，也不清理 `D:\Ryza_chat`。

旧工作区的 62 个差异文件另存于 `.project-migration/legacy-differences/`；比较报告见 `.project-migration/legacy-worktree-audit.md`。所有本地迁移记录及构建归档均被 `.gitignore` 排除，不能公开提交。

## 后续开发

```powershell
Set-Location D:\OpenAgentAtelier
flutter pub get --offline
.\tool\build_protected.ps1 -Target apk -Mode release -Offline
```

构建、运行仍需使用受保护脚本。此次迁移不构建、安装或发布应用。

当前公共仓库保持为 `https://github.com/onion-aqua/OpenAgentAterlier.git`。2026-10-21/22 的前次独立迁移与发布记录保留在原文档备份、Git 历史和 `evidence/migration/`；其旧开发路径不再作为当前入口。
