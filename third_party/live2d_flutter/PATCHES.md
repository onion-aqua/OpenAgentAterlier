# AgentAtelierR patch of live2d_flutter 1.0.3

Source: <https://pub.dev/api/archives/live2d_flutter-1.0.3.tar.gz>

Published archive SHA-256:

```text
b16d5d861661427609a692e311f469941526d33a32912616191b8ca5efc84332
```

The published archive declares `assets/web/flutter_live2d_web.js` and shaders in
`pubspec.yaml`, but contains neither. This makes Flutter's normal asset bundler
fail on every platform. This project fixes the incomplete package without
editing the global Pub cache:

1. Keep the plugin's `lib/`, Android/iOS/macOS/Windows source, native Framework,
   and `web_runtime/` from that exact archive, including their license notices.
2. Generate the real web JavaScript and shaders using the upstream
   `web_runtime/build.mjs` and its locked `esbuild 0.28.2`. The generated
   `assets/web/` is committed so normal tests do not require Node/npm.
3. Set `publish_to: none`; use this package via a project-local path dependency.
4. Keep proprietary Cubism Core headers/libraries out of Git. Prepare them
   locally with `tool/prepare_live2d_runtime.ps1` before native builds. The
   preparation script verifies the exact published archive or checks files
   against recorded upstream fingerprints; it never writes to the Pub cache.
5. Align the Android plugin's NDK with the app's `28.2.13676358` toolchain.
   The upstream `27.2.12479018` pin would require an otherwise unused NDK in
   this project's offline Gradle setup. Supported native ABIs remain
   `arm64-v8a` and `x86_64`.

6. Package the 36 OpenGL ES shader sources (including Tegra variants) from
   `Shaders/StandardES` into Android native
   `assets/FrameworkShaders/` through a generated Gradle asset directory.
   Cubism reads these with `AssetManager`, not Flutter's asset bundle.
   `Shaders/Standard` is desktop GLSL 1.20 and cannot compile in Android's ES2
   context; a loaded MOC alone did not prove that any model could be drawn.
   The SourceSet receives a resolved directory, compatible with AGP 9's
   Provider restriction; `preBuild` explicitly depends on the shader Sync task.
7. Register native view handles before accepting method-channel commands.
   Commands keep per-view order, initialize the surface/viewport before model
   loading, and return an explicit error after ten seconds without a usable
   surface or when their view is disposed. A 1x1 EGL pbuffer permits initial
   unload and cleanup without a visible surface. Method-channel acknowledgments
   are posted after native execution rather than when merely queued.
8. Keep the native view alive through temporary TextureView surface loss.
   Release SurfaceTexture only after the render thread releases EGL, then
   reload the active model when the new surface is available. Permanent view
   disposal and engine detach clean up the native handle on that thread.
9. Reject missing/invalid MOC data before creating a renderer, guard absent
   expression/motion files, and serialize shared Framework reference counting.
   Android logs use fixed status messages; model paths and dialogue are omitted.
10. Keep Android and Windows external parameter controls as per-model overrides, applying
    them after motion, expression, physics and pose evaluation but before the
    final model update. Lip sync therefore survives saved-parameter restoration
    without contaminating the animation baseline. Explicit zero closes the
    mouth; unload/reload creates a fresh override set.
11. Reuse the preloaded Android motion cache for idle and explicit motions.
    Queue entries borrow each motion (`autoDelete=false`); the model stops its
    motion/expression queues and releases the caches exactly once on disposal.
    This removes an unowned allocation on every idle loop or motion request.
12. Add a per-view configurable idle motion on Android and Windows. The public
    controller accepts the exact Cubism group (including an empty group name)
    and index, native code validates that the motion exists, and foreground
    motions return to that selection only after completing. Android reapplies
    the selection after a temporary surface recreation without starting a
    duplicate motion; a deliberate model load resets to the `Idle[0]` default.

`Live2DCommandQueueTest` verifies startup unloading, delayed surfaces, queue
ordering across multiple views, disposal, timeout, native errors and context
failure. These tests exercise scheduling without needing a proprietary model.

No example app, character/model assets, upstream tests, `native_smoke` project,
build outputs, or `node_modules` are vendored. Original Dart/native plugin
rendering behavior is retained except for the Android fixes described above.
`UPSTREAM_FILES.json` records hashes of retained upstream
files, while `RUNTIME_FILES.json` records ignored Cubism Core files and generated
web assets, enabling review and repeatable integrity checks.

## Licenses

- Plugin: original BSD 3-Clause in `LICENSE` and `NOTICES`.
- Cubism Framework and sample-derived web code: Live2D Open Software License;
  original notices in `web_runtime/LICENSE.framework.md`,
  `web_runtime/LICENSE.samples.md`, and source headers remain intact.
- Cubism Core: Live2D Proprietary Software License, described in
  `windows/LICENSE.core.md` and `NOTICES`; the SDK's release/distribution
  conditions apply separately. A BSD plugin license does not license Core or
  user models. See the original links in these files.

Android/Windows native compilation and actual model rendering require their
normal toolchains and remain separate validation steps. Generating web assets
or passing unit tests does not establish native rendering correctness.
