import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alchemy_models.dart';
import 'package:ryza_chat_mvp/src/alchemy_screen.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/shop_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final precious in [false, true]) {
    testWidgets(
      '${precious ? 'precious' : 'inventory'} item confirmation shows its complete long content',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final controller = (await tester.runAsync(() => AppController.load()))!;
        addTearDown(controller.dispose);
        const itemName = '携带着古代炼金工房传承的多功能素材收纳盒与附带精细说明书';
        final gift = ShopCatalog.byId('ryza_gift')!;
        if (precious) {
          controller.preciousItems = {gift.id: 1};
        } else {
          controller.alchemyState = AlchemyState(
            inventory: [
              AlchemyItem(
                instanceId: 'long-name-test',
                templateId: 'uni',
                quality: 50,
                quantity: 2,
                tagIds: const [],
                acquiredAt: DateTime(2026),
                customName: itemName,
              ),
            ],
            history: const [],
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: AlchemyScreen(controller: controller, embedded: true),
          ),
        );
        await tester.pumpAndSettle();
        final useButton = find.byTooltip(precious ? '使用' : '使用 1 份');
        await tester.scrollUntilVisible(
          useButton,
          180,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(useButton);
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        final content = find.descendant(
          of: dialog,
          matching: find.textContaining(
            precious
                ? gift.description(
                    controller.interfaceLanguage,
                    characterName:
                        controller.activeCharacterProfile.names.chinese,
                  )
                : '消耗 1 份',
          ),
        );
        expect(content, findsOneWidget);
        final scrollable = find.descendant(
          of: dialog,
          matching: find.byType(Scrollable),
        );
        if (scrollable.evaluate().isNotEmpty) {
          final state = tester.state<ScrollableState>(scrollable.first);
          state.position.jumpTo(state.position.maxScrollExtent);
          await tester.pump();
        }
        final text = tester.widget<Text>(content).data!;
        final paragraph = tester.renderObject<RenderParagraph>(content);
        final lastBox = paragraph
            .getBoxesForSelection(
              TextSelection(
                baseOffset: text.length - 1,
                extentOffset: text.length,
              ),
            )
            .last;
        final end = paragraph.localToGlobal(
          Offset(lastBox.left, lastBox.bottom),
        );
        final actions = find.descendant(
          of: dialog,
          matching: find.widgetWithText(FilledButton, '使用'),
        );
        expect(end.dy, lessThanOrEqualTo(tester.getTopLeft(actions).dy));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(
          precious
              ? controller.preciousItems[gift.id]
              : controller.alchemyState.inventory.single.quantity,
          precious ? 1 : 2,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
