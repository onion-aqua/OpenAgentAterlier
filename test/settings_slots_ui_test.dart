import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/character_prompt_editor.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:ryza_chat_mvp/src/settings_slots.dart';

void main() {
  Future<AppController> setup(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return c;
  }

  testWidgets('user slots keep drafts and Cancel does not switch active data', (
    tester,
  ) async {
    final c = await setup(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(controller: c, onMenuPressed: () {}),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('称呼与自画像'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '第一位');
    await tester.tap(find.byKey(const ValueKey('settings-slot-4')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '第五位');
    await tester.tap(find.byKey(const ValueKey('settings-slot-0')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '第一位',
    );
    await tester.tap(find.byKey(const ValueKey('settings-slot-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并使用'));
    await tester.pumpAndSettle();
    expect(c.userAddress, '第五位');
    expect(
      c.settingsSlots(SettingsSlotKind.user).entries[0]?['address'],
      '第一位',
    );
    await tester.tap(find.text('称呼与自画像'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-slot-0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '不保存');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.userAddress, '第五位');
    expect(
      c.settingsSlots(SettingsSlotKind.user).entries[0]?['address'],
      '第一位',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final world in [false, true]) {
    testWidgets(
      '${world ? 'world' : 'character'} editor saves independent slot drafts with keyboard',
      (tester) async {
        final c = await setup(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        CharacterPromptEditor(controller: c, world: world),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-slot-1')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '第二槽位的设定');
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-slot-2')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '第三槽位的设定');
        await tester.ensureVisible(find.text('保存并使用'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存并使用'));
        await tester.pumpAndSettle();
        final bank = c.settingsSlots(
          world ? SettingsSlotKind.world : SettingsSlotKind.character,
        );
        expect(bank.active, 2);
        expect(bank.entries[1]?['text'], '第二槽位的设定');
        expect(bank.entries[2]?['text'], '第三槽位的设定');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('accent picker exposes seven presets and applies selection', (
    tester,
  ) async {
    final c = await setup(tester);
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: c,
        builder: (context, _) => MaterialApp(
          theme: atelierTheme(c.accentTheme, Brightness.light),
          home: SettingsScreen(controller: c, onMenuPressed: () {}),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-category-appearance')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题色'));
    await tester.pumpAndSettle();
    for (final accent in AppAccentTheme.values) {
      expect(find.byKey(ValueKey('accent-${accent.name}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('accent-rose')));
    await tester.pumpAndSettle();
    expect(c.accentTheme, AppAccentTheme.rose);
    expect(
      Theme.of(tester.element(find.text('主题色').last)).colorScheme.primary,
      AppAccentTheme.rose.color,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
