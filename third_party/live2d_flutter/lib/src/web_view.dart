import 'dart:async';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../flutter_live2d_platform_interface.dart';
import 'view_lifecycle.dart';
import 'web_canvas_registry.dart';

int _nextWebViewType = 0;

Widget buildLive2DWebView({
  required ValueChanged<int> onPlatformViewCreated,
}) {
  return _Live2DWebView(onPlatformViewCreated: onPlatformViewCreated);
}

class _Live2DWebView extends StatefulWidget {
  const _Live2DWebView({required this.onPlatformViewCreated});

  final ValueChanged<int> onPlatformViewCreated;

  @override
  State<_Live2DWebView> createState() => _Live2DWebViewState();
}

class _Live2DWebViewState extends State<_Live2DWebView> {
  late final String _viewType;
  int? _viewId;

  @override
  void initState() {
    super.initState();
    _viewType = 'flutter_live2d_web_${_nextWebViewType++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final canvas = web.HTMLCanvasElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.display = 'block'
        ..style.touchAction = 'none';
      webLive2DCanvases[viewId] = canvas;
      return canvas;
    });
  }

  void _handleCreated(int viewId) {
    _viewId = viewId;
    final platform = FlutterLive2dPlatform.instance;
    final Live2DViewLifecycle? lifecycle = platform is Live2DViewLifecycle
        ? platform as Live2DViewLifecycle
        : null;
    if (webLive2DCanvases[viewId] == null || lifecycle == null) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError('Live2D Web view $viewId cannot initialize.'),
          library: 'flutter_live2d',
        ),
      );
      return;
    }

    final initialization = lifecycle.initializeView(viewId: viewId);
    widget.onPlatformViewCreated(viewId);
    unawaited(
      initialization.catchError((Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'flutter_live2d',
            context: ErrorDescription('while initializing Web view $viewId'),
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    final viewId = _viewId;
    final platform = FlutterLive2dPlatform.instance;
    final Live2DViewLifecycle? lifecycle = platform is Live2DViewLifecycle
        ? platform as Live2DViewLifecycle
        : null;
    if (viewId != null && lifecycle != null) {
      unawaited(lifecycle.disposeView(viewId: viewId));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(
      viewType: _viewType,
      onPlatformViewCreated: _handleCreated,
    );
  }
}
