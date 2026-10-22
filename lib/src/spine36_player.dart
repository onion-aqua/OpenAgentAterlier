import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

/// Version selection is exact: 3.60 / 3.6x must never enter the 3.6 reader.
bool isSpine36(String version) => RegExp(r'^3\.6(?:\.|$)').hasMatch(version);
bool get spine36Available =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

class Spine36Model {
  Spine36Model(this.skeleton, this.atlas, this.texture);

  final Uint8List skeleton;
  final Uint8List atlas;
  final Uint8List texture;

  static Future<Spine36Model> fromBundle(
    AssetBundle bundle, {
    required String skeleton,
    required String atlas,
  }) async {
    Future<Uint8List> read(String name) async {
      final data = await bundle.load(name);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    final files = await Future.wait([read(skeleton), read(atlas)]);
    final page = utf8
        .decode(files[1])
        .split(RegExp(r'\r?\n'))
        .firstWhere((line) => line.trim().isNotEmpty)
        .trim();
    if (page.contains('/') || page.contains('\\') || !page.endsWith('.png')) {
      throw const FormatException('Expected one local PNG atlas page');
    }
    final texture = '${atlas.substring(0, atlas.lastIndexOf('/') + 1)}$page';
    return Spine36Model(files[0], files[1], await read(texture));
  }

  late final Map<String, Object> payload = _payload();

  Map<String, Object> _payload() {
    final json = jsonDecode(utf8.decode(skeleton));
    if (json is! Map ||
        json['skeleton'] is! Map ||
        !isSpine36('${json['skeleton']['spine']}')) {
      throw const FormatException('Expected a Spine 3.6 JSON skeleton');
    }
    // Packages already passed single-page atlas / texture validation. Keep the
    // original files untouched; normalize only the in-memory player URL.
    final text = utf8
        .decode(atlas)
        .replaceFirst(
          RegExp(r'^\s*[^\r\n]+\.png', multiLine: true),
          'texture.png',
        );
    return {
      'skeleton': skeleton,
      'atlas': Uint8List.fromList(utf8.encode(text)),
      'texture': texture,
    };
  }

  /// Parse AND render with the same offline runtime used by the visible view.
  Future<List<String>> validate() async {
    if (!spine36Available) {
      throw UnsupportedError('Spine 3.6 playback currently requires Android');
    }
    final result = await const MethodChannel('agentatelier/spine36')
        .invokeListMethod<String>('validate', payload)
        .timeout(const Duration(seconds: 25));
    return result ?? const [];
  }
}

class Spine36Player extends StatefulWidget {
  const Spine36Player({
    super.key,
    required this.model,
    required this.performance,
    required this.onReady,
    required this.onError,
  });

  final Spine36Model model;
  final Map<String, Object?> performance;
  final ValueChanged<List<String>> onReady;
  final ValueChanged<Object> onError;

  @override
  State<Spine36Player> createState() => _Spine36PlayerState();
}

class _Spine36PlayerState extends State<Spine36Player> {
  MethodChannel? _channel;
  bool _ready = false;

  @override
  void didUpdateWidget(covariant Spine36Player oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready) _sync();
  }

  Future<void> _sync() async {
    try {
      await _channel?.invokeMethod<void>('performance', widget.performance);
    } on Object catch (error) {
      if (mounted) widget.onError(error);
    }
  }

  void _attach(int id) {
    _channel = MethodChannel('agentatelier/spine36/$id');
    _channel!.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'ready') {
        _ready = true;
        await _sync();
        if (mounted) {
          widget.onReady((call.arguments as List).cast<String>());
        }
      } else if (call.method == 'error') {
        widget.onError(StateError('${call.arguments}'));
      }
    });
  }

  @override
  void dispose() {
    _ready = false;
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!spine36Available) {
      return const Center(child: Text('此平台尚不支持 Spine 3.6 播放'));
    }
    return AndroidView(
      viewType: 'agentatelier/spine36',
      creationParams: widget.model.payload,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _attach,
      // Character interactions remain with the Flutter overlay.
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    );
  }
}
