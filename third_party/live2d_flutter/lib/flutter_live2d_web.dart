import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'flutter_live2d_platform_interface.dart';
import 'src/view_lifecycle.dart';
import 'src/web_canvas_registry.dart';

const String _coreScriptUrl =
    'https://cubism.live2d.com/sdk-web/core/06/live2dcubismcore.min.js';

@JS('Live2DCubismCore')
external JSObject? get _cubismCore;

@JS('FlutterLive2DWeb')
external JSObject? get _live2DWebRuntime;

@JS('FlutterLive2DWeb.createView')
external JSPromise<JSAny?> _createView(
  JSNumber viewId,
  web.HTMLCanvasElement canvas,
  JSString shaderBaseUrl,
);

@JS('FlutterLive2DWeb.disposeView')
external JSPromise<JSAny?> _disposeView(JSNumber viewId);

@JS('FlutterLive2DWeb.loadModel')
external JSPromise<JSBoolean> _loadModel(
  JSNumber viewId,
  JSString modelDir,
  JSString modelFileName,
);

@JS('FlutterLive2DWeb.unloadModel')
external JSPromise<JSAny?> _unloadModel(JSNumber viewId);

@JS('FlutterLive2DWeb.setRenderingPaused')
external JSPromise<JSAny?> _setRenderingPaused(
  JSNumber viewId,
  JSBoolean paused,
);

@JS('FlutterLive2DWeb.startMotion')
external JSPromise<JSAny?> _startMotion(
  JSNumber viewId,
  JSString group,
  JSNumber index,
  JSNumber priority,
);

@JS('FlutterLive2DWeb.setExpression')
external JSPromise<JSAny?> _setExpression(JSNumber viewId, JSNumber index);

@JS('FlutterLive2DWeb.setParameter')
external JSPromise<JSAny?> _setParameter(
  JSNumber viewId,
  JSString parameterId,
  JSNumber value,
);

@JS('FlutterLive2DWeb.setMotionSpeed')
external JSPromise<JSAny?> _setMotionSpeed(
  JSNumber viewId,
  JSNumber speed,
);

/// Web implementation backed by the official Cubism Web Framework.
class FlutterLive2dWeb extends FlutterLive2dPlatform
    implements Live2DViewLifecycle {
  FlutterLive2dWeb();

  static Future<void>? _scriptsReady;

  final Map<int, Future<void>> _viewInitializers = {};

  static void registerWith(Registrar registrar) {
    FlutterLive2dPlatform.instance = FlutterLive2dWeb();
  }

  @override
  Future<String?> getPlatformVersion() async => web.window.navigator.userAgent;

  @override
  Future<String> getTempDirectory() {
    throw UnsupportedError('Web models are loaded from URLs, not temp files.');
  }

  @override
  Future<void> initializeView({required int viewId}) {
    final canvas = webLive2DCanvases.remove(viewId);
    if (canvas == null) {
      return Future<void>.error(
        PlatformException(
          code: 'INVALID_ARGS',
          message: 'Web view $viewId requires an HTMLCanvasElement.',
        ),
      );
    }

    final initialization = _guard('NATIVE_ERROR', () async {
      await _ensureScriptsLoaded();
      await _createView(
        viewId.toJS,
        canvas,
        _packageAssetUrl('assets/web/shaders/').toJS,
      ).toDart;
    });
    _viewInitializers[viewId] = initialization;
    return initialization;
  }

  @override
  Future<void> disposeView({required int viewId}) async {
    final initialization = _viewInitializers.remove(viewId);
    if (initialization == null) return;
    try {
      await initialization;
      await _disposeView(viewId.toJS).toDart;
    } catch (_) {
      // A failed initialization has no browser resources left to release.
    }
  }

  @override
  Future<bool> loadModel({
    required int viewId,
    required String modelDir,
    required String modelFileName,
  }) {
    return _guard('LOAD_FAILED', () async {
      await _requireView(viewId);
      final result = await _loadModel(
        viewId.toJS,
        modelDir.toJS,
        modelFileName.toJS,
      ).toDart;
      return result.toDart;
    });
  }

  @override
  Future<void> unloadModel({required int viewId}) {
    return _guard('NATIVE_ERROR', () async {
      await _requireView(viewId);
      await _unloadModel(viewId.toJS).toDart;
    });
  }

  @override
  Future<void> setRenderingPaused({
    required int viewId,
    required bool paused,
  }) {
    return _guard('NATIVE_ERROR', () async {
      await _requireView(viewId);
      await _setRenderingPaused(viewId.toJS, paused.toJS).toDart;
    });
  }

  @override
  Future<void> startMotion({
    required int viewId,
    required String group,
    required int index,
    int priority = 2,
  }) {
    return _guard('NATIVE_ERROR', () async {
      await _requireView(viewId);
      await _startMotion(
        viewId.toJS,
        group.toJS,
        index.toJS,
        priority.toJS,
      ).toDart;
    });
  }

  @override
  Future<void> setExpression({required int viewId, required int index}) {
    return _guard('NATIVE_ERROR', () async {
      await _requireView(viewId);
      await _setExpression(viewId.toJS, index.toJS).toDart;
    });
  }

  @override
  Future<void> setParameter({
    required int viewId,
    required String parameterId,
    required double value,
  }) {
    return _guard('NATIVE_ERROR', () async {
      await _requireView(viewId);
      await _setParameter(
        viewId.toJS,
        parameterId.toJS,
        value.toJS,
      ).toDart;
    });
  }

  @override
  Future<void> setMotionSpeed({
    required int viewId,
    required double speed,
  }) {
    return _guard('NATIVE_ERROR', () async {
      await _requireView(viewId);
      await _setMotionSpeed(viewId.toJS, speed.toJS).toDart;
    });
  }

  Future<void> _requireView(int viewId) {
    final initialization = _viewInitializers[viewId];
    if (initialization == null) {
      throw PlatformException(
        code: 'VIEW_NOT_FOUND',
        message: 'No Live2D Web view registered for id $viewId.',
      );
    }
    return initialization;
  }

  static Future<void> _ensureScriptsLoaded() {
    return _scriptsReady ??= () async {
      if (_cubismCore == null) {
        await _loadScript(_coreScriptUrl, 'Live2DCubismCore');
      }
      if (_live2DWebRuntime == null) {
        await _loadScript(
          _packageAssetUrl('assets/web/flutter_live2d_web.js'),
          'FlutterLive2DWeb',
        );
      }
    }();
  }

  static Future<void> _loadScript(String source, String globalName) {
    final completer = Completer<void>();
    final script = web.HTMLScriptElement()
      ..src = source
      ..async = true;

    script.addEventListener(
      'load',
      ((web.Event _) {
        if (!completer.isCompleted) completer.complete();
      }).toJS,
    );
    script.addEventListener(
      'error',
      ((web.Event _) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Failed to load $globalName from $source.'),
          );
        }
      }).toJS,
    );
    web.document.head?.append(script);
    return completer.future;
  }

  static String _packageAssetUrl(String path) {
    return Uri.parse(
      web.document.baseURI,
    ).resolve('assets/packages/live2d_flutter/$path').toString();
  }

  static Future<T> _guard<T>(
    String errorCode,
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } on PlatformException {
      rethrow;
    } catch (error) {
      throw PlatformException(code: errorCode, message: error.toString());
    }
  }
}
