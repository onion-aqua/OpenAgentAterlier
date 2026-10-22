import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'character_appearance.dart';
import 'character_expression.dart';
import 'character_spine_view.dart';
import 'spine36_player.dart';
import 'runtime_log.dart';

/// Native names are resolved at import time. The renderer checks them again
/// against the loaded skeleton before exposing any performance capability.
class MappedSpineCapabilities {
  const MappedSpineCapabilities({
    required this.idle,
    required this.actions,
    required this.expressions,
    required this.parameters,
  });

  final String idle;
  final Map<String, ({String animation, String description})> actions;
  final Map<String, String> expressions;
  final Map<String, String> parameters;

  factory MappedSpineCapabilities.parse(
    String gesture, {
    required bool Function(String) hasAnimation,
  }) {
    final decoded = jsonDecode(gesture);
    final runtime = decoded is Map ? decoded['ModelMapping.Runtime'] : null;
    if (runtime is! Map || runtime['idleAnimations'] is! List) {
      throw const FormatException('缺少模型映射运行配置');
    }
    final idles = runtime['idleAnimations'] as List;
    if (idles.isEmpty ||
        idles.first is! String ||
        !hasAnimation(idles.first as String)) {
      throw const FormatException('映射待机动画不存在');
    }
    final actions = <String, ({String animation, String description})>{};
    if (runtime['actions'] case final Map rows) {
      for (final entry in rows.entries) {
        final row = entry.value;
        if (entry.key is! String ||
            row is! Map ||
            row['animation'] is! String ||
            (row['description'] != null && row['description'] is! String)) {
          continue;
        }
        final animation = row['animation'] as String;
        if (hasAnimation(animation)) {
          actions[entry.key as String] = (
            animation: animation,
            description: row['description'] as String? ?? entry.key as String,
          );
        }
      }
    }
    Map<String, String> clips(Object? value) {
      if (value is! Map) return const {};
      return {
        for (final entry in value.entries)
          if (entry.key is String &&
              entry.value is String &&
              hasAnimation(entry.value as String))
            entry.key as String: entry.value as String,
      };
    }

    return MappedSpineCapabilities(
      idle: idles.first as String,
      actions: Map.unmodifiable(actions),
      expressions: Map.unmodifiable(clips(runtime['expressions'])),
      parameters: Map.unmodifiable(clips(runtime['parameters'])),
    );
  }

  String groupId(String action) => 'grp_mapped_$action';
  String? actionForGroup(String id) {
    if (!id.startsWith('grp_mapped_')) return null;
    final action = id.substring('grp_mapped_'.length);
    return actions.containsKey(action) ? action : null;
  }
}

class MappedSpineView extends StatefulWidget {
  const MappedSpineView({
    super.key,
    required this.appearance,
    required this.bundle,
    required this.expression,
    this.action,
    this.actionNonce = 0,
    this.paused = false,
    this.speaking = false,
    this.speechEnergyProvider,
    required this.onReady,
    this.onLoadFailed,
  });

  final CharacterAppearance appearance;
  final AssetBundle bundle;
  final CharacterExpression expression;
  final String? action;
  final int actionNonce;
  final bool paused;
  final bool speaking;
  final double Function()? speechEnergyProvider;
  final ValueChanged<MappedSpineCapabilities> onReady;
  final VoidCallback? onLoadFailed;

  @override
  // Each imported appearance is keyed by ID and has an immutable version.
  // ignore: no_logic_in_create_state
  State<MappedSpineView> createState() => isSpine36(appearance.spineVersion)
      ? _MappedSpine36ViewState()
      : _MappedSpineViewState();
}

class _MappedSpine36ViewState extends State<MappedSpineView> {
  Spine36Model? _model;
  String? _gesture;
  MappedSpineCapabilities? _capabilities;
  String? _error;
  Timer? _speechTimer;
  double _energy = 0;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final appearance = widget.appearance;
      final model = await Spine36Model.fromBundle(
        widget.bundle,
        skeleton: appearance.skeletonAsset,
        atlas: appearance.atlasAsset,
      );
      final gesture = await widget.bundle.loadString(appearance.gestureAsset);
      if (!mounted) return;
      setState(() {
        _model = model;
        _gesture = gesture;
      });
    } on Object catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (!mounted || _failed) return;
    _failed = true;
    _speechTimer?.cancel();
    RuntimeLog.instance.warning('Spine36', '模型加载失败：$error');
    setState(() => _error = 'Spine 3.6 模型加载失败：$error');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onLoadFailed?.call();
    });
  }

  void _ready(List<String> animations) {
    try {
      final capabilities = MappedSpineCapabilities.parse(
        _gesture!,
        hasAnimation: animations.contains,
      );
      setState(() => _capabilities = capabilities);
      _syncSpeech();
      RuntimeLog.instance.info('Spine36', '模型已加载；动画=${animations.length}');
      widget.onReady(capabilities);
    } on Object catch (error) {
      _fail(error);
    }
  }

  @override
  void didUpdateWidget(covariant MappedSpineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSpeech();
  }

  void _syncSpeech() {
    if (!_failed &&
        _capabilities != null &&
        widget.speaking &&
        !widget.paused) {
      _speechTimer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) return;
        final energy = (widget.speechEnergyProvider?.call() ?? 0).clamp(
          0.0,
          1.0,
        );
        if (_energy != energy) setState(() => _energy = energy);
      });
    } else {
      _speechTimer?.cancel();
      _speechTimer = null;
      _energy = 0;
    }
  }

  @override
  void dispose() {
    _speechTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final model = _model;
    if (model == null) return const SizedBox.shrink();
    final capabilities = _capabilities;
    return Spine36Player(
      model: model,
      performance: {
        'idle':
            capabilities?.idle ?? widget.appearance.idleAnimations.firstOrNull,
        'face':
            capabilities?.expressions[widget.expression.name] ??
            capabilities?.expressions['neutral'],
        'action': capabilities?.actions[widget.action]?.animation,
        'actionNonce': widget.actionNonce,
        'mouth': capabilities?.parameters['mouthOpen'],
        'speaking': widget.speaking && !widget.paused,
        'energy': _energy,
        'paused': widget.paused,
      },
      onReady: _ready,
      onError: _fail,
    );
  }
}

class _MappedSpineViewState extends State<MappedSpineView> {
  late final SpineWidgetController _controller;
  MappedSpineCapabilities? _capabilities;
  TrackEntry? _mouth;
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = SpineWidgetController(
      maxDeltaTime: 0.05,
      onBeforeApplyAnimation: (_) {
        final entry = _mouth;
        if (entry != null) {
          final energy = widget.speaking
              ? (widget.speechEnergyProvider?.call() ?? 0).clamp(0.0, 1.0)
              : 0.0;
          entry.setTrackTime(entry.getAnimation().getDuration() * energy);
        }
      },
      onInitialized: (controller) async {
        try {
          final source = await widget.bundle.loadString(
            widget.appearance.gestureAsset,
          );
          if (!mounted) return;
          final capabilities = MappedSpineCapabilities.parse(
            source,
            hasAnimation: (name) =>
                controller.skeletonData.findAnimation(name) != null,
          );
          controller.animationState.getData().setDefaultMix(0.25);
          controller.animationState.setAnimationByName(
            0,
            capabilities.idle,
            true,
          );
          _capabilities = capabilities;
          _ready = true;
          _sync();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onReady(capabilities);
          });
        } on Object {
          if (!mounted) return;
          setState(() => _error = '映射资源校验失败，请重新导入模型');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onLoadFailed?.call();
          });
        }
      },
    );
    if (widget.paused) _controller.pause();
  }

  @override
  void didUpdateWidget(covariant MappedSpineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(
      playAction:
          oldWidget.actionNonce != widget.actionNonce ||
          oldWidget.action != widget.action,
    );
  }

  void _sync({bool playAction = true}) {
    if (widget.paused) {
      _controller.pause();
    } else {
      _controller.resume();
    }
    if (!_ready) return;
    final capabilities = _capabilities!;
    final state = _controller.animationState;
    final face =
        capabilities.expressions[widget.expression.name] ??
        capabilities.expressions['neutral'];
    if (face != null) {
      if (state.getCurrent(11)?.getAnimation().getName() != face) {
        state.setAnimationByName(11, face, false);
      }
    } else if (state.getCurrent(11) != null) {
      state.setEmptyAnimation(11, 0.2);
    }
    final mouth = capabilities.parameters['mouthOpen'];
    if (widget.speaking && mouth != null) {
      _mouth = state.getCurrent(13);
      if (_mouth?.getAnimation().getName() != mouth) {
        _mouth = state.setAnimationByName(13, mouth, false)..setTimeScale(0);
      }
    } else if (_mouth != null) {
      _mouth = null;
      state.setEmptyAnimation(13, 0.15);
    }
    if (playAction && widget.action != null) {
      final action = capabilities.actions[widget.action];
      if (action != null) {
        state.setAnimationByName(1, action.animation, false);
        state.addEmptyAnimation(1, 0.25, 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    return CharacterSpineView(
      atlas: widget.appearance.atlasAsset,
      skeleton: widget.appearance.skeletonAsset,
      bundle: widget.bundle,
      controller: _controller,
      onLoadFailed: widget.onLoadFailed,
    );
  }
}
