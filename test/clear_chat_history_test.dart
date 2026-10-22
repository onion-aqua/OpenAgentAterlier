import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final clearMemory in [false, true]) {
    test('clearing chat persists memory choice: $clearMemory', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.addUserMessage('将被删除的对话');
      controller.updateMemorySummary('重要约定：明天一起采集');
      await controller.saveToLocalSlot(0);
      final saved = controller.localSaveSlots.first;
      final revision = controller.dataRevision;
      final progress = controller.userMessageCount;
      controller.clearChatHistory(clearLongTermMemory: clearMemory);
      expect(controller.dataRevision, revision + 1);
      expect(controller.messages.any((m) => m.text == '将被删除的对话'), isFalse);
      expect(controller.memorySummary, clearMemory ? '' : '重要约定：明天一起采集');
      expect(controller.longTermMemoryEnabled, isTrue);
      expect(controller.userMessageCount, progress);
      expect(
        controller.localSaveSlots.first?.messageCount,
        saved?.messageCount,
      );
      // Allow the serialized preferences save queue to drain, then reload.
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.memorySummary, controller.memorySummary);
      expect(restored.messages.any((m) => m.text == '将被删除的对话'), isFalse);
      await restored.loadFromLocalSlot(0);
      expect(restored.memorySummary, '重要约定：明天一起采集');
    });
  }

  for (final choice in ['取消', '保留长期记忆', '一并删除']) {
    testWidgets('clear history confirmation: $choice', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      controller.addUserMessage('旧对话');
      controller.updateMemorySummary('旧记忆');
      final revision = controller.dataRevision;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(controller: controller, onMenuPressed: () {}),
        ),
      );
      final category = find.byKey(const ValueKey('settings-category-data'));
      await tester.scrollUntilVisible(
        category,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(category);
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除聊天记录'));
      await tester.pumpAndSettle();
      // Opening the dialog must not clear anything before a choice is made.
      expect(controller.messages.last.text, '旧对话');
      expect(controller.memorySummary, '旧记忆');
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(controller.messages.any((m) => m.text == '旧对话'), choice == '取消');
      expect(controller.memorySummary, choice == '一并删除' ? '' : '旧记忆');
      expect(controller.dataRevision, choice == '取消' ? revision : revision + 1);
      expect(tester.takeException(), isNull);
    });
  }
}
