import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'runtime_log.dart';

/// One focus owner for all app media; never changes a system stream's volume.
class AndroidCompanionRuntime extends ChangeNotifier
    with WidgetsBindingObserver {
  AndroidCompanionRuntime({
    bool? enabled,
    MethodChannel? methods,
    EventChannel? events,
  }) : enabled =
           enabled ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       _methods =
           methods ?? const MethodChannel('agent_atelier_r/companion_runtime'),
       _events =
           events ??
           const EventChannel('agent_atelier_r/companion_runtime/events');

  static final instance = AndroidCompanionRuntime();
  final bool enabled;
  final MethodChannel _methods;
  final EventChannel _events;
  final Set<Object> _activePlayers = {};
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _initializing;
  Future<void> _activityTail = Future<void>.value();
  Future<void> _identityTail = Future<void>.value();
  String _companionName = '';
  Map<String, dynamic> _state = const {};
  bool _disposed = false;

  bool get running => _state['running'] == true;
  bool get starting => _state['starting'] == true;
  bool get stopRequested => _state['stopRequested'] == true;
  bool get notificationsAllowed => _state['notificationsAllowed'] == true;
  bool get phoneStatePermission => _state['phoneStatePermission'] == true;
  bool get callActive => _state['callActive'] == true;
  bool get muted => enabled && (stopRequested || _state['muted'] == true);
  String get manufacturer => _state['manufacturer'] as String? ?? '';
  String get lastError => _state['lastError'] as String? ?? '';

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!enabled || _disposed) return;
    WidgetsBinding.instance.addObserver(this);
    _subscription = _events.receiveBroadcastStream().listen(
      _acceptState,
      onError: (Object error) => _report(error),
    );
    await refresh();
    if (!running && !starting && !stopRequested) await start();
  }

  void _acceptState(dynamic value) {
    if (_disposed || value is! Map) return;
    final next = Map<String, dynamic>.from(value);
    if (mapEquals(_state, next)) return;
    final wasMuted = muted;
    _state = next;
    if (muted != wasMuted) {
      RuntimeLog.instance.info(
        'Audio',
        muted ? '应用音频已静音（通话、焦点中断或停止陪伴）' : '应用音频已恢复',
      );
    }
    notifyListeners();
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? arguments]) async {
    if (!enabled || _disposed) return;
    try {
      _acceptState(await _methods.invokeMethod<dynamic>(method, arguments));
    } on MissingPluginException {
      // Tests and other desktop platforms do not register this Android bridge.
    } on PlatformException catch (error) {
      _report(error);
    }
  }

  void _report(Object error) {
    if (_disposed) return;
    RuntimeLog.instance.warning('Audio', '后台陪伴状态同步失败：${error.runtimeType}');
  }

  Future<void> start() => _invoke('start');
  Future<void> stop() => _invoke('stop');
  Future<void> refresh() => _invoke('getState');

  /// Names belong to the selected model. An empty name restores the generic
  /// companion notification, without starting the service or asking permission.
  Future<void> setCompanionName(String? name) {
    _companionName = (name ?? '')
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
        .trim();
    final next = _identityTail.then(
      (_) => _invoke('setCompanionName', {'name': _companionName}),
    );
    _identityTail = next.catchError((Object error) => _report(error));
    return next;
  }

  Future<void> openBackgroundSettings() async {
    if (!enabled || _disposed) return;
    try {
      await _methods.invokeMethod<dynamic>('openBackgroundSettings');
    } on MissingPluginException {
      // No Android bridge on desktop.
    } on PlatformException catch (error) {
      _report(error);
    }
  }

  /// Playback waits for this snapshot before it can become audible. Requests
  /// are serialized and use the latest aggregate, so old completions cannot
  /// release focus from a newly started player.
  Future<void> setPlayerActive(Object player, bool active) {
    if (active) {
      _activePlayers.add(player);
    } else {
      _activePlayers.remove(player);
    }
    final next = _activityTail.then((_) async {
      await initialize();
      // Completing one clip must not request focus on behalf of another player
      // that is still suppressed by a call or other interruption.
      if (!active && _activePlayers.isNotEmpty && !stopRequested) return;
      await _invoke('setAudioActive', {
        'active': _activePlayers.isNotEmpty && !stopRequested,
      });
    });
    _activityTail = next.catchError((Object error) => _report(error));
    return next;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
