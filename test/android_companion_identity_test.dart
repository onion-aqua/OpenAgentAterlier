import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/android_companion_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/companion_identity');
  const events = EventChannel('test/companion_identity/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late AndroidCompanionRuntime runtime;
  late Map<String, Object> state;
  var runtimeDisposed = false;
  Completer<void>? pendingName;

  setUp(() {
    calls.clear();
    pendingName = null;
    runtimeDisposed = false;
    state = {'running': false, 'stopRequested': false, 'muted': false};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'setCompanionName') await pendingName?.future;
      return Map<String, Object>.from(state);
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/companion_identity/events'),
      (_) async => null,
    );
    runtime = AndroidCompanionRuntime(
      enabled: true,
      methods: channel,
      events: events,
    );
  });

  tearDown(() {
    if (!runtimeDisposed) runtime.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/companion_identity/events'),
      null,
    );
  });

  test(
    'model names and rename update without starting a companion session',
    () async {
      await runtime.setCompanionName('橘');
      await runtime.setCompanionName('橘的新名字');
      expect(calls.map((call) => call.method), [
        'setCompanionName',
        'setCompanionName',
      ]);
      expect(calls.map((call) => (call.arguments as Map)['name']), [
        '橘',
        '橘的新名字',
      ]);
      expect(runtime.running, isFalse);
    },
  );

  test(
    'removing a model clears identity and normalizes display-only controls',
    () async {
      await runtime.setCompanionName('  橘\n角色\u0000  ');
      await runtime.setCompanionName(null);
      expect((calls.first.arguments as Map)['name'], '橘 角色');
      expect((calls.last.arguments as Map)['name'], '');
      expect(calls.every((call) => call.method == 'setCompanionName'), isTrue);
    },
  );

  test('rapid model switches serialize to the latest name', () async {
    pendingName = Completer<void>();
    final first = runtime.setCompanionName('第一个模型');
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(1));
    final second = runtime.setCompanionName('第二个模型');
    final third = runtime.setCompanionName('当前模型');
    pendingName!.complete();
    pendingName = null;
    await Future.wait([first, second, third]);
    expect((calls.first.arguments as Map)['name'], '第一个模型');
    expect((calls.last.arguments as Map)['name'], '当前模型');
    expect(
      calls.skip(1).every((call) => (call.arguments as Map)['name'] == '当前模型'),
      isTrue,
    );
  });

  test(
    'identity refresh preserves call mute and a user-stopped session',
    () async {
      state.addAll({'stopRequested': true, 'callActive': true, 'muted': true});
      await runtime.initialize();
      calls.clear();
      await runtime.setCompanionName('当前模型');
      expect(runtime.muted, isTrue);
      expect(runtime.callActive, isTrue);
      expect(runtime.stopRequested, isTrue);
      expect(calls.map((call) => call.method), ['setCompanionName']);
    },
  );

  test(
    'desktop and disposed runtimes do not invoke Android identity methods',
    () async {
      final desktop = AndroidCompanionRuntime(enabled: false, methods: channel);
      await desktop.setCompanionName('当前模型');
      desktop.dispose();
      runtime.dispose();
      runtimeDisposed = true;
      await runtime.setCompanionName('已关闭');
      expect(calls, isEmpty);
    },
  );
}
