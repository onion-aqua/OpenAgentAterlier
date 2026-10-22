import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_localization.dart';

enum AppFrameRateMode { high, adaptive, low }

extension AppFrameRateModeData on AppFrameRateMode {
  String label(AppLanguage language) => switch (this) {
    AppFrameRateMode.high => language.text(
      '高帧率',
      'High frame rate',
      '高フレームレート',
    ),
    AppFrameRateMode.adaptive => language.text('自适应', 'Adaptive', '自動調整'),
    AppFrameRateMode.low => language.text('低帧率', 'Low frame rate', '低フレームレート'),
  };

  String description(AppLanguage language) => switch (this) {
    AppFrameRateMode.high => language.text(
      '持续使用 120Hz 或设备支持的更高刷新率',
      'Always use 120Hz or the highest rate supported by the device',
      '常時120Hz、または端末が対応する最高リフレッシュレートを使用',
    ),
    AppFrameRateMode.adaptive => language.text(
      '静置 24fps，界面 60fps，朗读 90fps，触摸与动作 120fps',
      '24fps idle, 60fps UI, 90fps speech, 120fps touch and motion',
      '待機24fps、UI 60fps、音声90fps、タッチと動作120fps',
    ),
    AppFrameRateMode.low => language.text(
      '限制角色动画为 30fps，降低功耗',
      'Limit character animation to 30fps to reduce power use',
      'キャラクターアニメを30fpsに制限して消費電力を抑制',
    ),
  };

  double get sliderValue => switch (this) {
    AppFrameRateMode.high => 0,
    AppFrameRateMode.adaptive => 1,
    AppFrameRateMode.low => 2,
  };

  double get baseFramesPerSecond => switch (this) {
    AppFrameRateMode.high => 120,
    AppFrameRateMode.adaptive => 24,
    AppFrameRateMode.low => 30,
  };

  bool get prefersDeviceMaximum => this == AppFrameRateMode.high;

  static AppFrameRateMode fromSliderValue(double value) =>
      switch (value.round().clamp(0, 2)) {
        0 => AppFrameRateMode.high,
        1 => AppFrameRateMode.adaptive,
        _ => AppFrameRateMode.low,
      };
}

enum FrameRateActivity { interfaceAnimation, speech, characterMotion, touch }

extension on FrameRateActivity {
  double get framesPerSecond => switch (this) {
    FrameRateActivity.interfaceAnimation => 60,
    FrameRateActivity.speech => 90,
    FrameRateActivity.characterMotion || FrameRateActivity.touch => 120,
  };
}

typedef PreferredFrameRateRequester = Future<double?> Function(
  double framesPerSecond,
  bool preferMaximum,
);

/// Coordinates the Android display request and the character renderer's own
/// update rate. Other platforms still receive the animation cap.
class AdaptiveFrameRateController extends ChangeNotifier {
  AdaptiveFrameRateController({
    PreferredFrameRateRequester? requestPreferredFrameRate,
  }) : _requestPreferredFrameRate =
           requestPreferredFrameRate ?? _requestAndroidFrameRate;

  static const _channel = MethodChannel('agent_atelier_r/frame_rate');

  final PreferredFrameRateRequester _requestPreferredFrameRate;
  final Set<FrameRateActivity> _sustainedActivities = {};
  final Map<FrameRateActivity, Timer> _activityTimers = {};
  AppFrameRateMode _mode = AppFrameRateMode.adaptive;
  double _effectiveFramesPerSecond = 24;
  int _requestGeneration = 0;
  bool _disposed = false;

  AppFrameRateMode get mode => _mode;
  double get effectiveFramesPerSecond => _effectiveFramesPerSecond;

  void setMode(AppFrameRateMode value, {bool force = false}) {
    if (!force && value == _mode) return;
    _mode = value;
    _recompute(force: true);
  }

  void setActivity(FrameRateActivity activity, bool active) {
    final changed = active
        ? _sustainedActivities.add(activity)
        : _sustainedActivities.remove(activity);
    if (changed) _recompute();
  }

  void boost(
    FrameRateActivity activity, {
    Duration duration = const Duration(milliseconds: 900),
  }) {
    _activityTimers.remove(activity)?.cancel();
    _activityTimers[activity] = Timer(duration, () {
      _activityTimers.remove(activity);
      _recompute();
    });
    _recompute();
  }

  void _recompute({bool force = false}) {
    var target = _mode.baseFramesPerSecond;
    if (_mode == AppFrameRateMode.adaptive) {
      for (final activity in {
        ..._sustainedActivities,
        ..._activityTimers.keys,
      }) {
        target = target < activity.framesPerSecond
            ? activity.framesPerSecond
            : target;
      }
    }
    if (!force && target == _effectiveFramesPerSecond) return;
    _effectiveFramesPerSecond = target;
    notifyListeners();
    unawaited(_applyPlatformRate(target, _mode.prefersDeviceMaximum));
  }

  Future<void> _applyPlatformRate(double target, bool preferMaximum) async {
    final generation = ++_requestGeneration;
    try {
      await _requestPreferredFrameRate(target, preferMaximum);
      if (_disposed || generation != _requestGeneration) return;
    } on MissingPluginException {
      // Desktop and tests still use the renderer-side frame cap.
    } on PlatformException catch (error) {
      debugPrint('Unable to apply Android frame rate: ${error.message}');
    }
  }

  static Future<double?> _requestAndroidFrameRate(
    double framesPerSecond,
    bool preferMaximum,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'setPreferredFrameRate',
      {'framesPerSecond': framesPerSecond, 'preferMaximum': preferMaximum},
    );
    return (result?['appliedFramesPerSecond'] as num?)?.toDouble();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _activityTimers.values) {
      timer.cancel();
    }
    _activityTimers.clear();
    _sustainedActivities.clear();
    super.dispose();
  }
}
