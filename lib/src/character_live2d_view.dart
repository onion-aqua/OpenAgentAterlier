import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:live2d_flutter/live2d_flutter.dart';

import 'character_expression.dart';
import 'live2d_model_descriptor.dart';
import 'runtime_log.dart';

/// Hosts one user-provided Cubism model and translates the app's stable
/// semantic performance protocol to the model's own motion/expression names.
///
/// The widget does not ship a model or infer parameter IDs. Those values come
/// from [descriptor], which is validated against the model's `.model3.json`
/// before it is passed here. Keeping this adapter independent from Spine lets
/// both runtimes consume the same LLM performance result.
class CharacterLive2dView extends StatefulWidget {
  const CharacterLive2dView({
    super.key,
    required this.modelDirectory,
    required this.modelFileName,
    this.manifestAsset,
    this.descriptor,
    this.onDescriptor,
    this.expression = CharacterExpression.neutral,
    this.action,
    this.actionNonce = 0,
    this.speaking = false,
    this.speechEnergy = 0,
    this.speechEnergyProvider,
    this.paused = false,
    this.onReady,
    this.onLoadFailed,
  });

  /// Asset or filesystem directory containing the complete model bundle.
  final String modelDirectory;

  /// The `.model3.json` entry file inside [modelDirectory].
  final String modelFileName;
  final String? manifestAsset;

  /// Optional validated semantic catalog. Missing entries intentionally map
  /// to no-op rather than guessing a nearby motion.
  final Live2DModelDescriptor? descriptor;
  final ValueChanged<Live2DModelDescriptor?>? onDescriptor;

  final CharacterExpression expression;
  final String? action;
  final int actionNonce;

  /// Speaking only controls the model's configured mouth parameter. The
  /// current package API has no PCM/RMS callback; [speechEnergy] is therefore
  /// a temporary envelope hook supplied by the audio layer.
  final bool speaking;
  final double speechEnergy;
  final double Function()? speechEnergyProvider;
  final bool paused;

  final VoidCallback? onReady;
  final ValueChanged<Object>? onLoadFailed;

  @override
  State<CharacterLive2dView> createState() => _CharacterLive2dViewState();
}

class _CharacterLive2dViewState extends State<CharacterLive2dView> {
  late final Live2DViewController _controller;
  Timer? _speechTimer;
  int _loadGeneration = 0;
  bool _loaded = false;
  Object? _error;
  String? _lastAction;
  int _lastActionNonce = -1;
  CharacterExpression? _lastExpression;
  bool? _lastPaused;
  bool? _lastSpeaking;
  Live2DModelDescriptor? _descriptor;
  bool _syncing = false;
  bool _syncRequested = false;
  bool _sampling = false;
  Future<void> _nativeQueue = Future<void>.value();
  ({int generation, String parameter, double value})? _pendingSpeechSample;

  bool _isCurrent(int generation) => mounted && generation == _loadGeneration;

  Future<T> _nativeCommand<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _nativeQueue = _nativeQueue.then((_) async {
      try {
        result.complete(await operation());
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @override
  void initState() {
    super.initState();
    _controller = Live2DViewController();
    _descriptor = widget.descriptor;
    _loadModel();
  }

  @override
  void didUpdateWidget(covariant CharacterLive2dView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelDirectory != widget.modelDirectory ||
        oldWidget.modelFileName != widget.modelFileName ||
        oldWidget.manifestAsset != widget.manifestAsset) {
      _loadModel();
      return;
    }
    if (oldWidget.descriptor != widget.descriptor) {
      _descriptor = widget.descriptor;
      _lastExpression = null;
      _lastAction = null;
      _lastActionNonce = -1;
    }
    if ((oldWidget.speaking && !widget.speaking) ||
        (!oldWidget.paused && widget.paused)) {
      _speechTimer?.cancel();
      _speechTimer = null;
      if (_loaded) unawaited(_applySpeechEnergy(energy: 0));
    }
    if (_loaded) unawaited(_syncPerformance());
  }

  Future<void> _loadModel() async {
    final generation = ++_loadGeneration;
    final modelDirectory = widget.modelDirectory;
    final modelFileName = widget.modelFileName;
    final manifestAsset = widget.manifestAsset;
    final providedDescriptor = widget.descriptor;
    final onDescriptor = widget.onDescriptor;
    _speechTimer?.cancel();
    _speechTimer = null;
    _pendingSpeechSample = null;
    _descriptor = null;
    if (mounted) {
      setState(() {
        _loaded = false;
        _error = null;
        _lastAction = null;
        _lastActionNonce = -1;
        _lastExpression = null;
        _lastPaused = null;
        _lastSpeaking = null;
      });
    }
    try {
      await _controller.whenAttached;
      if (!_isCurrent(generation)) return;
      final descriptor = await _readDescriptor(
        generation: generation,
        modelDirectory: modelDirectory,
        modelFileName: modelFileName,
        manifestAsset: manifestAsset,
        provided: providedDescriptor,
      );
      if (!_isCurrent(generation)) return;
      _descriptor = descriptor;
      onDescriptor?.call(descriptor);
      await _nativeCommand(() async {
        if (!_isCurrent(generation)) return;
        await _controller.unloadModel().catchError((_) {});
        if (!_isCurrent(generation)) return;
        final ok = await _controller.loadModel(
          modelDir: modelDirectory,
          modelFileName: modelFileName,
        );
        if (!_isCurrent(generation)) return;
        if (!ok) {
          throw _controller.value.lastError ??
              StateError('Live2D model rejected');
        }
        final idle = descriptor?.idleMotion;
        if (idle != null) {
          await _controller.setIdleMotion(group: idle.group, index: idle.index);
          if (!_isCurrent(generation)) return;
        }
        setState(() => _loaded = true);
        RuntimeLog.instance.info(
          'Live2D',
          '模型已加载；动作=${descriptor?.motionCapabilities.length ?? 0}，表情=${descriptor?.expressions.length ?? 0}',
        );
        widget.onReady?.call();
      });
      if (_isCurrent(generation) && _loaded) await _syncPerformance();
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      setState(() => _error = error);
      RuntimeLog.instance.warning(
        'Live2D',
        '模型加载失败：${error is Live2DException ? error.code : error.runtimeType}',
      );
      widget.onLoadFailed?.call(error);
    }
  }

  Future<Live2DModelDescriptor?> _readDescriptor({
    required int generation,
    required String modelDirectory,
    required String modelFileName,
    required String? manifestAsset,
    required Live2DModelDescriptor? provided,
  }) async {
    if (provided != null) return provided;
    final prefix = modelDirectory.endsWith('/')
        ? modelDirectory
        : '$modelDirectory/';
    try {
      final isAsset = modelDirectory.startsWith('assets/');
      Future<String> read(String path) =>
          isAsset ? rootBundle.loadString(path) : File(path).readAsString();
      final source = await read('$prefix$modelFileName');
      if (!_isCurrent(generation)) return null;
      final manifest = manifestAsset == null || manifestAsset.isEmpty
          ? null
          : await read('$prefix$manifestAsset');
      if (!_isCurrent(generation)) return null;
      return Live2DModelDescriptor.parse(
        source,
        manifestJson: manifest,
        modelId: modelDirectory,
      );
    } on Object {
      if (_isCurrent(generation)) {
        RuntimeLog.instance.warning('Live2D', '动作/表情目录解析失败，暂不提供规划能力');
      }
      // Descriptor parsing is capability metadata, not a reason to prevent a
      // valid native model from rendering.
      return null;
    }
  }

  Future<void> _syncPerformance() async {
    _syncRequested = true;
    if (_syncing) return;
    _syncing = true;
    try {
      while (_syncRequested && mounted && _loaded) {
        _syncRequested = false;
        await _applyPerformance();
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _applyPerformance() async {
    if (!_loaded || !mounted) return;
    final generation = _loadGeneration;
    try {
      await _nativeCommand(() async {
        if (!_isCurrent(generation) || !_loaded) return;
        final paused = widget.paused;
        final expression = widget.expression;
        final action = widget.action;
        final actionNonce = widget.actionNonce;
        final descriptor = _descriptor;
        if (_lastPaused != paused) {
          await _controller.setRenderingPaused(paused);
          if (!_isCurrent(generation)) return;
          _lastPaused = paused;
        }
        if (_lastExpression != expression) {
          final resolution = descriptor?.resolveExpression(expression);
          final asset = resolution?.expression;
          if (asset != null) await _controller.setExpression(asset.index);
          if (!_isCurrent(generation)) return;
          _lastExpression = expression;
        }
        if (action != null &&
            (action != _lastAction || actionNonce != _lastActionNonce)) {
          final motion =
              descriptor?.resolveAction(action) ??
              descriptor?.motionCapabilities[action];
          if (motion != null) {
            await _controller.startMotion(
              group: motion.group,
              index: motion.index,
              priority: 2,
            );
          }
          if (!_isCurrent(generation)) return;
          _lastAction = action;
          _lastActionNonce = actionNonce;
        } else if (action == null) {
          _lastAction = null;
        }
      });
      if (!_isCurrent(generation) || !_loaded) return;
      final samplingSpeech = widget.speaking && !widget.paused;
      if (_lastSpeaking != samplingSpeech) {
        _lastSpeaking = samplingSpeech;
        _speechTimer?.cancel();
        _speechTimer = samplingSpeech
            ? Timer.periodic(const Duration(milliseconds: 80), (_) {
                unawaited(_applySpeechEnergy());
              })
            : null;
        if (!samplingSpeech) await _applySpeechEnergy(energy: 0);
      }
      if (samplingSpeech && _isCurrent(generation)) await _applySpeechEnergy();
    } on Object catch (error) {
      if (_isCurrent(generation)) {
        setState(() => _error = error);
        widget.onLoadFailed?.call(error);
      }
    }
  }

  Future<void> _applySpeechEnergy({double? energy}) async {
    final parameter =
        _descriptor?.parameterBindings['mouthOpen'] ??
        _descriptor?.parameterBindings['mouthopen'] ??
        _descriptor?.parameterGroups['LipSync']?.firstOrNull;
    if (parameter == null || parameter.isEmpty || !_loaded || !mounted) return;
    // Cubism models commonly define mouth-open as 0..1. The native runtime
    // clamps out-of-range values to the model's configured range.
    _pendingSpeechSample = (
      generation: _loadGeneration,
      parameter: parameter,
      value: widget.paused || !widget.speaking
          ? 0
          : (energy ??
                    widget.speechEnergyProvider?.call() ??
                    widget.speechEnergy)
                .clamp(0.0, 1.0),
    );
    if (_sampling) return;
    _sampling = true;
    try {
      while (_pendingSpeechSample != null) {
        final sample = _pendingSpeechSample!;
        _pendingSpeechSample = null;
        try {
          await _nativeCommand(() async {
            if (!_isCurrent(sample.generation) || !_loaded) return;
            await _controller.setParameter(sample.parameter, sample.value);
          });
        } on Object catch (error) {
          if (_isCurrent(sample.generation)) widget.onLoadFailed?.call(error);
        }
      }
    } finally {
      _sampling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Live2DView(controller: _controller),
        if (!_loaded && _error == null)
          const Center(child: CircularProgressIndicator()),
        if (_error != null)
          Center(
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Colors.black54),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Live2D 模型加载失败',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _speechTimer?.cancel();
    _pendingSpeechSample = null;
    // The plugin updates its ValueNotifier after native commands complete.
    // Let those commands and the child view's detach finish before disposal.
    unawaited(_nativeQueue.then((_) => _controller.dispose()));
    super.dispose();
  }
}
