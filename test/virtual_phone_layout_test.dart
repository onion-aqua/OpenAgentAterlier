import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';

const _captureKey = ValueKey('virtual-phone-layout-capture');
const _pageKey = ValueKey('virtual-phone-layout-page');
const _inputKey = ValueKey('virtual-phone-layout-input');

class _LayoutPage extends StatelessWidget {
  const _LayoutPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    key: _pageKey,
    appBar: AppBar(title: const Text('Phone page')),
    body: const Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [TextField(key: _inputKey)],
    ),
  );
}

Future<void> _openPhone(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) =>
          RepaintBoundary(key: _captureKey, child: child!),
      home: const Scaffold(
        backgroundColor: Color(0xFF183B32),
        body: Center(
          child: VirtualPhoneLauncher(
            language: AppLanguage.chinese,
            liquidGlass: false,
            pages: {VirtualPhoneApp.status: _buildPage},
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.smartphone_rounded));
  await tester.pumpAndSettle();
}

Widget _buildPage(BuildContext context) => const _LayoutPage();

Future<void> _capture(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('VIRTUAL_PHONE_EVIDENCE_DIR');
  if (directory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(data.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  final scenarios = <({String name, Size size, FakeViewPadding padding})>[
    (
      name: 'narrow-portrait',
      size: const Size(320, 700),
      padding: const FakeViewPadding(top: 24, bottom: 24),
    ),
    (
      name: 'tall-portrait',
      size: const Size(412, 915),
      padding: const FakeViewPadding(top: 32, bottom: 28),
    ),
    (
      name: 'landscape-cutout',
      size: const Size(844, 390),
      padding: const FakeViewPadding(left: 36, right: 12, bottom: 20),
    ),
  ];

  for (final scenario in scenarios) {
    testWidgets('phone fills edges and protects content: ${scenario.name}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = scenario.size;
      tester.view.padding = scenario.padding;
      tester.view.viewPadding = scenario.padding;
      addTearDown(tester.view.reset);
      await _openPhone(tester);
      final phone = tester.getRect(
        find.byKey(const ValueKey('virtual-phone-screen')),
      );
      expect(phone.left, 0);
      expect(phone.right, scenario.size.width);
      expect(phone.top, scenario.padding.top);
      expect(phone.bottom, scenario.size.height);

      final carrierSlot = tester.getRect(
        find
            .ancestor(
              of: find.byKey(const ValueKey('virtual-phone-status-time')),
              matching: find.byType(Align),
            )
            .first,
      );
      final island = tester.getRect(
        find.byKey(const ValueKey('virtual-phone-dynamic-island')),
      );
      expect(carrierSlot.right, closeTo(island.left - 6, 1));

      final dock = tester.getRect(
        find.byKey(const ValueKey('virtual-phone-dock')),
      );
      expect(dock.left, greaterThanOrEqualTo(scenario.padding.left));
      expect(
        dock.right,
        lessThanOrEqualTo(scenario.size.width - scenario.padding.right),
      );
      expect(
        dock.bottom,
        lessThanOrEqualTo(scenario.size.height - scenario.padding.bottom),
      );
      expect(
        find.byKey(const ValueKey('virtual-phone-pull-handle')).hitTestable(),
        findsOneWidget,
      );
      await _capture(tester, scenario.name);

      final app = find.byKey(const ValueKey('virtual-phone-app-status'));
      await tester.ensureVisible(app);
      await tester.tap(app);
      await tester.pumpAndSettle();
      final page = tester.getRect(find.byKey(_pageKey));
      expect(page.left, closeTo(scenario.padding.left, 1));
      expect(
        page.right,
        closeTo(scenario.size.width - scenario.padding.right, 1),
      );
      expect(
        page.bottom,
        closeTo(scenario.size.height - scenario.padding.bottom, 1),
      );
      final pageMedia = MediaQuery.of(tester.element(find.byKey(_inputKey)));
      expect(pageMedia.padding, EdgeInsets.zero);
      expect(pageMedia.viewPadding, EdgeInsets.zero);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('page keeps input above keyboard and adapts after rotation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 915);
    tester.view.padding = const FakeViewPadding(top: 32, bottom: 28);
    tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 28);
    addTearDown(tester.view.reset);
    await _openPhone(tester);
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-status')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(_inputKey), 'Retained input');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.view.padding = const FakeViewPadding(top: 32);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_inputKey)).bottom, closeTo(615, 1));
    expect(
      MediaQuery.of(tester.element(find.byKey(_pageKey))).viewInsets.bottom,
      300,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('virtual-phone-screen'))).bottom,
      915,
    );
    await _capture(tester, 'tall-portrait-keyboard');

    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.physicalSize = const Size(915, 412);
    tester.view.padding = const FakeViewPadding(left: 32, bottom: 20);
    tester.view.viewPadding = const FakeViewPadding(left: 32, bottom: 20);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('virtual-phone-screen'))),
      const Rect.fromLTWH(0, 0, 915, 412),
    );
    expect(
      tester.widget<TextField>(find.byKey(_inputKey)).controller?.text ??
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
      'Retained input',
    );
    expect(tester.takeException(), isNull);
  });
}
