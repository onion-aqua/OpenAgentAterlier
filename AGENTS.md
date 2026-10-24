# OpenAgentAtelier

- This is the purified (提纯版本) independent project rooted at `D:\OpenAgentAtelier`, relocated from `D:\AgentAtelier` on 2026-10-24. Do not replace it with the original RyzaChat version.
- Work only in this project. Do not use another RyzaChat/AgentAtelierR checkout as a source or writable dependency.
- Preserve existing local changes, imported resources and migration archives. `packages/spine_flutter` and `third_party/live2d_flutter` are local physical dependencies.
- The Git repository has independent objects. The public remote is `https://github.com/onion-aqua/OpenAgentAterlier.git`; do not publish to the former project or restore its remote by default.
- Use `tool/build_protected.ps1` or `tool/run_protected.ps1` for builds and runs. Device installation and publication require an applicable user request.
- User-visible app name: `OpenAgentAtelier` (`lib/src/app_identity.dart`). No custom app/launch image. Android application ID: `com.ateleragent.studio`. Windows storage ProductName/company stay `AgentAtelier` / `com.ateleragent` for data compatibility; window/EXE/display metadata use `OpenAgentAtelier`. Keep their data isolated from the former application.
- Current character names, avatars and prompts must follow the active model profile and its resources. Missing identity/assets use neutral defaults; legacy IDs and parser aliases never supply a character identity. The virtual phone inventory keeps the `alchemy` routing ID for compatibility and displays `背包` / `Inventory`.
- Fish MCP callback: `agentatelier-fishmcp://oauth/callback`. Keep Android, Windows and Dart in sync.
- `.migration-cache/` contains preserved historical source files. `.project-migration/` contains local migration manifests, historical differences, APKs, symbols, and reports; both are local archives, are not active dependencies, and must not be published. See `MIGRATION.md` and `项目文件与删除清单.md`.
