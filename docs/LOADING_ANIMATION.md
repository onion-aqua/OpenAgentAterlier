# 启动加载动画

用户于 2026-09-15 提供并明确允许将以下六张图片提交到 GitHub。
它们来自 `C:/Users/cheny/Desktop/frames/`，按原文件内容复制，未使用原版游戏加载素材替代。

允许公开的文件清单：

- `assets/branding/loading/frame_00.png`
- `assets/branding/loading/frame_01.png`
- `assets/branding/loading/frame_02.png`
- `assets/branding/loading/frame_03.png`
- `assets/branding/loading/frame_04.png`
- `assets/branding/loading/frame_05.png`

每帧 150 毫秒，六帧循环。`RyzaLoadingPanel` 将动画放入居中的半透明黑色圆角面板，下方按 UI 语言显示“加载中... / Loading... / 読み込み中...”。系统减少动态效果开启时显示第一帧。

启动先显示白底封面，Logo 宽度为屏幕的 85%，保留原先的 3 秒封面展示时间。进入聊天界面后，再显示动画加载面板；文字使用已加载的 UI 语言设置。面板位于屏幕覆盖层，持续显示至当前角色 Spine 初始化完成，不跟随角色镜头缩放。资源解密失败时让出错误提示，不用加载面板遮盖错误。

发布时只放行上面六个文件。若发布仓库使用 `*.png` 和 `assets/**/*` 全局排除规则，在其末尾保留以下例外（父目录也必须可遍历）：

```gitignore
!assets/**/
!assets/branding/loading/frame_0[0-5].png
```

这项授权不扩展到其他图片、服装、骨骼、模型、音频或加密包。构建仍使用 `powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode debug`。
