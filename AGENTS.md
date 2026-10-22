# AgentAtelier

- This is an independent project rooted at `D:\AgentAtelier`.
- Work only in this project. Do not use another RyzaChat/AgentAtelierR checkout as a source or writable dependency.
- Preserve existing local changes, imported resources and migration archives. `packages/spine_flutter` and `third_party/live2d_flutter` are local physical dependencies.
- The Git repository has independent objects. The public remote is `https://github.com/onion-aqua/OpenAgentAterlier.git`; do not publish to the former project or restore its remote by default.
- Use `tool/build_protected.ps1` or `tool/run_protected.ps1` for builds and runs. Device installation and publication require an applicable user request.
- Android application ID: `com.ateleragent.studio`. Windows product/company: `AgentAtelier` / `com.ateleragent`. Keep their data isolated from the former application.
- Fish MCP callback: `agentatelier-fishmcp://oauth/callback`. Keep Android, Windows and Dart in sync.
- `.migration-cache/` contains preserved historical files and build caches. It is not an active dependency and must not be published. See `MIGRATION.md`.
