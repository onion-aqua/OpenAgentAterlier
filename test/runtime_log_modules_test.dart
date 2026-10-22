import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';
import 'package:ryza_chat_mvp/src/runtime_log_screen.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RuntimeLog.instance.clear();
  });
  test('planner and unknown sources persist and classify', () async {
    final log = RuntimeLog.instance;
    log.info('plan_character_action', 'action marker');
    log.info('plan_character_expression', 'face marker');
    log.error('NewModule', 'failure');
    expect(log.entries.map((e) => e.module), [
      RuntimeLogModule.action,
      RuntimeLogModule.expression,
      RuntimeLogModule.system,
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await log.initialize();
    expect(log.entries.length, 3);
    await log.clear();
    await log.initialize();
    expect(log.entries, isEmpty);
  });
  test('active feature sources route to their matching module', () {
    const sources = <RuntimeLogModule, List<String>>{
      RuntimeLogModule.llm: ['LLM', 'AI', 'AI suggestion', 'Agent'],
      RuntimeLogModule.tts: [
        'TTS',
        'TTS loudness',
        'TTS playback',
        'Fish Audio 试音',
        'Qwen-TTS 试音',
        '通用 TTS 试音',
      ],
      RuntimeLogModule.expression: [
        'plan_character_expression',
        'ExpressionPlanner',
      ],
      RuntimeLogModule.action: ['plan_character_action', 'ActionPlanner'],
      RuntimeLogModule.speech: ['SpeechPlanner'],
      RuntimeLogModule.singing: ['SingingPlanner', 'plan_singing_performance'],
      RuntimeLogModule.memory: ['Memory'],
      RuntimeLogModule.translation: ['Translation'],
      RuntimeLogModule.character: [
        'Character',
        'CharacterAssets',
        'CharacterMotion',
        'CharacterState',
        'LipSync',
        'SkinImport',
        'Interaction',
      ],
      RuntimeLogModule.storage: [
        'Persistence',
        'NpcPersistence',
        'TranslationPersistence',
        'Data export',
        'Data import',
        'Legacy data conversion',
        'Attachment',
      ],
      RuntimeLogModule.soundscape: ['Soundscape'],
      RuntimeLogModule.alarm: ['Alarm'],
      RuntimeLogModule.relay: ['PC Agent', 'RelayClient'],
      RuntimeLogModule.system: [
        'App',
        'Camera',
        'Flutter',
        'Navigation',
        'Platform',
        'Startup',
        'NewModule',
      ],
    };
    for (final module in sources.entries) {
      for (final source in module.value) {
        expect(
          RuntimeLogModule.forSource(source),
          module.key,
          reason: 'Source $source must remain in ${module.key.name}',
        );
      }
    }
  });
  test('classification normalizes labels with explicit routing precedence', () {
    const cases = <String, RuntimeLogModule>{
      '  PLAN-CHARACTER-EXPRESSION / request  ': RuntimeLogModule.expression,
      'action_planner:playback': RuntimeLogModule.action,
      'Speech Planner / response': RuntimeLogModule.speech,
      'Singing.Planner': RuntimeLogModule.singing,
      'PLAN-SINGING-PERFORMANCE': RuntimeLogModule.singing,
      'FishAudio/response': RuntimeLogModule.tts,
      'TTS-playback': RuntimeLogModule.tts,
      'Data_export': RuntimeLogModule.storage,
      'translation.persistence': RuntimeLogModule.storage,
      'Character Persistence': RuntimeLogModule.storage,
      'npc_persistence': RuntimeLogModule.storage,
      'Memory-refresh': RuntimeLogModule.memory,
      'Translation:retry': RuntimeLogModule.translation,
      'AI/suggestion': RuntimeLogModule.llm,
      'PC_Agent/questions': RuntimeLogModule.relay,
      'Relay Client': RuntimeLogModule.relay,
      'Soundscape/playback': RuntimeLogModule.soundscape,
      'Voice Alarm': RuntimeLogModule.alarm,
      'Airplane': RuntimeLogModule.system,
      'Unrecognized feature': RuntimeLogModule.system,
      '': RuntimeLogModule.system,
    };
    for (final entry in cases.entries) {
      expect(
        RuntimeLogModule.forSource(entry.key),
        entry.value,
        reason: entry.key,
      );
    }
  });
  test(
    'classification preserves legacy entries, source and stable identity',
    () {
      final original = RuntimeLogEntry(
        id: 'saved-singing-entry',
        timestamp: DateTime(2026, 10, 12),
        level: RuntimeLogLevel.warning,
        source: '  SingingPlanner  ',
        message: 'singing request failed',
        repeatCount: 2,
        lastTimestamp: DateTime(2026, 10, 12, 0, 1),
      );
      final restored = RuntimeLogEntry.fromJson(original.toJson());
      expect(restored.module, RuntimeLogModule.singing);
      expect(restored.toJson(), original.toJson());
      expect(restored.identity, original.identity);
    },
  );
  test('new feature and unknown categories collect every severity', () {
    final log = RuntimeLog.instance;
    for (final source in ['SingingPlanner', 'Data export', 'NewModule']) {
      for (final level in RuntimeLogLevel.values) {
        log.add(level, source, '$source ${level.name} marker');
      }
    }
    expect(log.entries.length, 9);
    expect(log.entries.map((entry) => entry.module), [
      ...List.filled(3, RuntimeLogModule.singing),
      ...List.filled(3, RuntimeLogModule.storage),
      ...List.filled(3, RuntimeLogModule.system),
    ]);
  });
  test('action info is sampled by category without suppressing warnings', () {
    final log = RuntimeLog.instance;
    log.infoRateLimited('ActionPlanner', 'motion-start', 'first');
    log.infoRateLimited('ActionPlanner', 'motion-start', 'second');
    log.infoRateLimited('ActionPlanner', 'motion-finish', 'finished');
    log.warning('ActionPlanner', 'playback failed');
    expect(log.entries.map((entry) => entry.message), [
      'first',
      'finished',
      'playback failed',
    ]);
  });
  test(
    'diagnostics logged by listeners do not recursively refresh listeners',
    () async {
      final log = RuntimeLog.instance;
      var notifications = 0;
      void listener() {
        notifications++;
        if (notifications < 10) log.error('Flutter', 'listener diagnostic');
      }

      log.addListener(listener);
      try {
        log.info('LLM', 'initial diagnostic');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(notifications, 1);
        expect(log.entries.map((entry) => entry.message), [
          'initial diagnostic',
          'listener diagnostic',
        ]);
      } finally {
        log.removeListener(listener);
      }
      await log.clear();
    },
  );
  test('nested JSON is formatted and sensitive values are redacted', () {
    final value = RuntimeLog.prettyMessage(
      jsonEncode({
        'body': jsonEncode({
          'api_key': 'private-value',
          'result': [1, 2],
        }),
      }),
    );
    expect(value, contains('\n'));
    expect(value, isNot(contains('private-value')));
    expect((jsonDecode(value)['body'] as Map)['api_key'], '[REDACTED]');
    expect(
      RuntimeLog.prettyMessage('line one\nline two'),
      'line one\nline two',
    );
  });
  test(
    'legacy logs get distinct short identities without storing message in keys',
    () {
      final json = <String, dynamic>{
        'timestamp': '2026-10-06T01:00:00',
        'level': 'error',
        'source': 'Flutter',
        'message': List.filled(1000, 'large stack').join('\n'),
      };
      final first = RuntimeLogEntry.fromJson(json);
      final second = RuntimeLogEntry.fromJson(json);
      expect(first.identity.length, lessThan(100));
      expect(second.identity, isNot(first.identity));
      expect(first.repeatCount, 1);
      expect(first.lastTimestamp, isNull);
    },
  );
  test(
    'consecutive identical errors retain first context and repeat count',
    () async {
      final log = RuntimeLog.instance;
      log.error('Flutter', 'first failure');
      final first = log.entries.last;
      for (var index = 0; index < 300; index++) {
        log.error('Flutter', 'first failure');
      }
      expect(log.entries.length, 1);
      expect(log.entries.single.identity, first.identity);
      expect(log.entries.single.timestamp, first.timestamp);
      expect(log.entries.single.repeatCount, 301);
      expect(log.entries.single.lastTimestamp, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await log.initialize();
      expect(log.entries.single.repeatCount, 301);
      expect(log.entries.single.lastTimestamp, isNotNull);
      log.error('Flutter', 'different failure');
      log.error('Flutter', 'first failure');
      expect(log.entries.length, 3);
      expect(log.entries.last.repeatCount, 1);
      await log.clear();
    },
  );
  testWidgets('module filters isolate visible messages', (tester) async {
    await tester.runAsync(() async {
      RuntimeLog.instance.info('LLM', 'llm marker');
      RuntimeLog.instance.info('TTS', 'tts marker');
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: RuntimeLogScreen(
          language: AppLanguage.values.first,
          onMenuPressed: () {},
        ),
      ),
    );
    expect(find.text('llm marker'), findsOneWidget);
    expect(find.text('tts marker'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('runtime-log-filter-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'TTS'));
    await tester.pumpAndSettle();
    expect(find.text('llm marker'), findsNothing);
    expect(find.text('tts marker'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => RuntimeLog.instance.clear());
  });
  testWidgets('new logs preserve expanded rows with semantics enabled', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final message = List.generate(
      10,
      (index) => 'existing line $index',
    ).join('\n');
    await tester.runAsync(() async {
      RuntimeLog.instance.error('Flutter', message);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: RuntimeLogScreen(
          language: AppLanguage.chinese,
          onMenuPressed: () {},
          embedded: true,
        ),
      ),
    );
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    final originalState = tester.state(find.byType(ExpansionTile));
    await tester.runAsync(() async {
      RuntimeLog.instance.error('Flutter', message);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('重复 2 次'), findsOneWidget);
    expect(tester.state(find.byType(ExpansionTile)), same(originalState));
    await tester.runAsync(() async {
      RuntimeLog.instance.info('TTS', 'new item');
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('new item'), findsOneWidget);
    expect(find.text(message), findsOneWidget);
    expect(tester.state(find.byType(ExpansionTile)), same(originalState));
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => RuntimeLog.instance.clear());
    semantics.dispose();
  });
}
