import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/world_map_localization.dart';
import 'package:ryza_chat_mvp/src/world_map_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('map NPC names stay within the focused map and remain readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    controller.interfaceLanguage = AppLanguage.english;
    controller.selectedAreaId = 'area_01';
    controller.selectedStageId = 'stage_01_002_01';
    late BuildContext preloadContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            preloadContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.runAsync(
      () => WorldMapScreen.preload(preloadContext, controller),
    );
    final world = (await tester.runAsync(
      () => rootBundle.loadString('assets/world_map/world_hierarchy.json'),
    ))!;
    final data = jsonDecode(world) as Map<String, dynamic>;
    final area = (data['areas'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((area) => area['id'] == 'area_01');
    final field = (area['fields'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((field) => field['id'] == 'field_01_002');
    final name = localizedWorldPlaceName(
      id: field['id'] as String,
      fallback: field['name'] as String,
      language: AppLanguage.english,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: WorldMapScreen(
          controller: controller,
          onMenuPressed: () {},
          onClose: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();
    final label = find.textContaining('May meet:');
    expect(label, findsOneWidget);
    final rect = tester.getRect(label);
    final focused = tester.getRect(
      find.byKey(const ValueKey('world-map-focused-field')),
    );
    expect(rect.left, greaterThanOrEqualTo(focused.left));
    expect(rect.right, lessThanOrEqualTo(focused.right));
    final names = tester.widget<Text>(label).data!;
    await tester.longPress(label);
    await tester.pumpAndSettle();
    expect(find.text(names), findsNWidgets(2));
    final tooltipRect = tester.getRect(find.text(names).last);
    expect(tooltipRect.left, greaterThanOrEqualTo(0));
    expect(tooltipRect.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });
}
