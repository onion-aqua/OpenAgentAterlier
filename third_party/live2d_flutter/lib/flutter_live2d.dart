/// Flutter plugin that renders Live2D Cubism models on Android, iOS, macOS,
/// Web and Windows.
///
/// Public API surface:
///
///  * [Live2DView] — widget that hosts the native GL surface.
///  * [Live2DViewController] — owns one view's runtime state. Acts as a
///    `ValueListenable<Live2DViewState>`; subscribe with
///    [ValueListenableBuilder] or `addListener`.
///  * [Live2DViewState] — immutable snapshot of one view's state, surfaced
///    through [Live2DViewController.value].
///  * [Live2DLifecycle], [Live2DLoadedModel], [Live2DException] — supporting
///    types referenced by [Live2DViewState].
///  * [Live2D] — static helpers not tied to a specific view.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'flutter_live2d_platform_interface.dart';
import 'src/native_asset_writer_stub.dart'
    if (dart.library.io) 'src/native_asset_writer_io.dart'
    as native_asset_writer;
import 'src/web_view_stub.dart' if (dart.library.js_interop) 'src/web_view.dart'
    as web_view;

export 'flutter_live2d_platform_interface.dart';

// Source files are split under `lib/src/` and joined into this single
// library via `part` directives so private members (e.g. lifecycle hooks
// `_attach` / `_detach` on the controller) can be shared with the widget
// without leaking into the public API.
part 'src/exception.dart';
part 'src/view_state.dart';
part 'src/asset_cache.dart';
part 'src/view_controller.dart';
part 'src/view.dart';
part 'src/windows_view.dart';
