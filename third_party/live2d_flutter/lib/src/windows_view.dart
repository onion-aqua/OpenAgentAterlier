part of '../flutter_live2d.dart';

const MethodChannel _windowsLive2DChannel = MethodChannel('flutter_live2d');

class _WindowsLive2DView extends StatefulWidget {
  const _WindowsLive2DView({required this.onPlatformViewCreated});

  final ValueChanged<int> onPlatformViewCreated;

  @override
  State<_WindowsLive2DView> createState() => _WindowsLive2DViewState();
}

class _WindowsLive2DViewState extends State<_WindowsLive2DView> {
  int? _viewId;
  int? _textureId;
  int _pixelWidth = 0;
  int _pixelHeight = 0;
  bool _creationStarted = false;
  Object? _error;

  @override
  void dispose() {
    final viewId = _viewId;
    if (viewId != null) {
      unawaited(
        _windowsLive2DChannel.invokeMethod<void>('disposeView', {
          'viewId': viewId,
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 1.0;
        final logicalHeight =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 1.0;
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final width =
            (logicalWidth * devicePixelRatio).round().clamp(1, 4096).toInt();
        final height =
            (logicalHeight * devicePixelRatio).round().clamp(1, 4096).toInt();

        _ensureView(width, height);

        if (_error != null) {
          return Center(child: Text('Live2D Windows error: $_error'));
        }

        final textureId = _textureId;
        if (textureId == null) return const SizedBox.expand();

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _updatePointer,
          onPointerMove: _updatePointer,
          onPointerUp: (_) => _resetPointer(),
          onPointerCancel: (_) => _resetPointer(),
          child: Texture(textureId: textureId),
        );
      },
    );
  }

  void _ensureView(int width, int height) {
    final viewId = _viewId;
    if (viewId == null) {
      if (_creationStarted) return;
      _creationStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_createView(width, height));
      });
      return;
    }

    if (_pixelWidth == width && _pixelHeight == height) return;
    _pixelWidth = width;
    _pixelHeight = height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _viewId != viewId) return;
      unawaited(
        _windowsLive2DChannel.invokeMethod<void>('resizeView', {
          'viewId': viewId,
          'width': width,
          'height': height,
        }).catchError(_handleAsyncError),
      );
    });
  }

  Future<void> _createView(int width, int height) async {
    try {
      final result = await _windowsLive2DChannel
          .invokeMapMethod<String, Object?>('createView', {
        'width': width,
        'height': height,
      });
      final viewId = result?['viewId'] as int?;
      final textureId = result?['textureId'] as int?;
      if (viewId == null || textureId == null) {
        throw const FormatException('Invalid createView response.');
      }
      if (!mounted) {
        await _windowsLive2DChannel.invokeMethod<void>('disposeView', {
          'viewId': viewId,
        });
        return;
      }
      _viewId = viewId;
      _textureId = textureId;
      _pixelWidth = width;
      _pixelHeight = height;
      widget.onPlatformViewCreated(viewId);
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  void _updatePointer(PointerEvent event) {
    final viewId = _viewId;
    final size = context.size;
    if (viewId == null || size == null || size.isEmpty) return;
    final x = 2.0 * event.localPosition.dx / size.width - 1.0;
    final y = -(2.0 * event.localPosition.dy / size.height - 1.0);
    unawaited(
      _windowsLive2DChannel.invokeMethod<void>('setDragging', {
        'viewId': viewId,
        'x': x.clamp(-1.0, 1.0),
        'y': y.clamp(-1.0, 1.0),
      }),
    );
  }

  void _resetPointer() {
    final viewId = _viewId;
    if (viewId == null) return;
    unawaited(
      _windowsLive2DChannel.invokeMethod<void>('setDragging', {
        'viewId': viewId,
        'x': 0.0,
        'y': 0.0,
      }),
    );
  }

  dynamic _handleAsyncError(Object error) {
    if (mounted) setState(() => _error = error);
  }
}
