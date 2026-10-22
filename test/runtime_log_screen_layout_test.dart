import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';
import 'package:ryza_chat_mvp/src/runtime_log_screen.dart';

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 840),
  bool glass = false,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool expandFilters = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RuntimeLogScreen(
        language: AppLanguage.chinese,
        liquidGlass: glass,
        embedded: true,
        onMenuPressed: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (expandFilters) {
    await tester.tap(find.byKey(const ValueKey('runtime-log-filter-toggle')));
    await tester.pumpAndSettle();
  }
}

Future<void> _record(WidgetTester tester, void Function(RuntimeLog) add) =>
    tester.runAsync(() async {
      add(RuntimeLog.instance);
      await Future<void>.delayed(Duration.zero);
    });

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RuntimeLog.instance.initialize();
    await RuntimeLog.instance.clear();
  });
  tearDown(() => RuntimeLog.instance.clear());

  testWidgets('filters collapse by default and retain selection on reopening', (
    tester,
  ) async {
    await _record(tester, (log) {
      log.info('LLM', 'model entry');
      log.info('TTS', 'voice entry');
    });
    await _mount(tester, expandFilters: false);
    expect(find.byType(ChoiceChip), findsNothing);
    final collapsedHeight = tester.getSize(find.byType(ListView)).height;
    expect(collapsedHeight, greaterThan(650));
    final toggle = find.byKey(const ValueKey('runtime-log-filter-toggle'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(
      tester.getSize(find.byType(ListView)).height,
      lessThan(collapsedHeight),
    );
    await tester.tap(find.byKey(const ValueKey('runtime-log-filter-tts')));
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('TTS · 全部级别'), findsOneWidget);
    expect(find.text('voice entry'), findsOneWidget);
    expect(find.text('model entry'), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('runtime-log-filter-tts')),
          )
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  for (final glass in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets('log borders stay separated ($glass, $brightness)', (
        tester,
      ) async {
        await _record(tester, (log) {
          log.info('LLM', 'first short entry');
          log.warning('Memory', 'second short entry');
        });
        await _mount(tester, glass: glass, brightness: brightness);
        final cards = find.byType(GlassContentCard);
        expect(cards, findsNWidgets(2));
        final first = tester.getRect(cards.at(0));
        final second = tester.getRect(cards.at(1));
        expect(second.top - first.bottom, greaterThanOrEqualTo(12));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('switching category from deep in the list shows its first row', (
    tester,
  ) async {
    await _record(tester, (log) {
      log.info('TTS', 'only voice entry');
      for (var i = 0; i < 60; i++) {
        log.info('LLM', 'reply $i');
      }
    });
    await _mount(tester);
    final list = find.byType(ListView);
    await tester.drag(list, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(tester.widget<ListView>(list).controller!.offset, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('runtime-log-filter-tts')));
    await tester.pumpAndSettle();
    expect(find.text('only voice entry'), findsOneWidget);
    expect(tester.widget<ListView>(list).controller!.offset, 0);
    expect(find.text('1 / 61'), findsOneWidget);

    await _record(tester, (log) => log.info('TTS', 'new voice entry'));
    await tester.pumpAndSettle();
    expect(find.text('new voice entry'), findsOneWidget);
    expect(find.text('only voice entry'), findsOneWidget);
    expect(find.text('2 / 62'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty combined filter explains and clears both conditions', (
    tester,
  ) async {
    await _record(tester, (log) {
      log.info('TTS', 'voice info');
      log.error('LLM', 'model error');
    });
    await _mount(tester);
    await tester.tap(find.byType(DropdownButton<RuntimeLogLevel>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ERROR').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('runtime-log-filter-tts')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('runtime-log-filter-llm')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('runtime-log-filter-tts')));
    await tester.pumpAndSettle();
    expect(find.text('暂无匹配日志'), findsOneWidget);
    expect(find.text('TTS · ERROR'), findsNWidgets(2));
    expect(find.text('0 / 2'), findsOneWidget);
    await tester.tap(find.text('显示全部日志'));
    await tester.pumpAndSettle();
    expect(find.text('voice info'), findsOneWidget);
    expect(find.text('model error'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a newly categorized source is visible in its category', (
    tester,
  ) async {
    await _record(tester, (log) {
      log.info('SingingPlanner', 'song marker');
      log.info('Data export', 'saved marker');
      log.info('NewModule', 'other marker');
    });
    await _mount(tester);
    for (final (module, marker) in [
      ('singing', 'song marker'),
      ('storage', 'saved marker'),
      ('system', 'other marker'),
    ]) {
      final chip = find.byKey(ValueKey('runtime-log-filter-$module'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text(marker), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  for (final size in [const Size(320, 480), const Size(720, 420)]) {
    testWidgets('filters leave room for logs with large text on $size', (
      tester,
    ) async {
      await _record(tester, (log) => log.info('LLM', 'visible log'));
      await _mount(tester, size: size, textScale: 1.5);
      expect(find.text('visible log'), findsOneWidget);
      expect(tester.getSize(find.byType(ListView)).height, greaterThan(120));
      final other = find.byKey(const ValueKey('runtime-log-filter-system'));
      await tester.ensureVisible(other);
      await tester.pumpAndSettle();
      await tester.tap(other);
      await tester.pumpAndSettle();
      expect(find.text('暂无匹配日志'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('runtime-log-reset-filters')));
      await tester.pumpAndSettle();
      expect(find.text('visible log'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
