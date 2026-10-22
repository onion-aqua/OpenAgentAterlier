import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/mission_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'empty quest guidance remains readable on a short large-text screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: MissionScreen(controller: controller, embedded: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('莱莎委托'));
      await tester.pumpAndSettle();
      expect(find.text('还没有莱莎委托'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final scrollable = find
          .descendant(
            of: find.byType(TabBarView),
            matching: find.byType(Scrollable),
          )
          .last;
      final state = tester.state<ScrollableState>(scrollable);
      expect(state.position.maxScrollExtent, greaterThan(0));
      state.position.jumpTo(state.position.maxScrollExtent);
      await tester.pump();
      final explanation = find.textContaining('开启 AI 接口中的联网 Agent');
      expect(tester.getBottomLeft(explanation).dy, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
    },
  );
}
