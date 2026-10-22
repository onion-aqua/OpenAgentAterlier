import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/settings_slots.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy settings migrate, slots stay independent and survive backups',
    () async {
      SharedPreferences.setMockInitialValues({
        'user_address': '原来的称呼',
        'character_persona': '原来人物性格',
        'world_setting': '原来世界内容',
      });
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final user = controller.settingsSlots(SettingsSlotKind.user);
      expect(user.entries.length, 5);
      expect(user.entries.first?['address'], '原来的称呼');
      expect(user.entries.skip(1), everyElement(isNull));
      user.entries[4] = {
        'address': '新伙伴',
        'portrait': '远方来的旅者',
        'relationshipRole': 'adventureCompanion',
        'interactionStyle': 'lively',
        'relationshipCustom': '一起旅行',
        'interactionCustom': '爱开玩笑',
        'boundaries': '不要旧称呼',
      };
      user.active = 4;
      expect(controller.userAddress, '原来的称呼');
      controller.saveSettingsSlots(SettingsSlotKind.user, user);
      expect(controller.userAddress, '新伙伴');
      expect(
        controller.userRelationshipRole,
        UserRelationshipRole.adventureCompanion,
      );
      expect(controller.userInteractionCustom, '爱开玩笑');
      for (final kind in [SettingsSlotKind.character, SettingsSlotKind.world]) {
        final draft = controller.settingsSlots(kind);
        draft.entries[3] = {'text': '${kind.name}第三备用内容'};
        draft.active = 3;
        controller.saveSettingsSlots(kind, draft);
      }
      controller.setAccentTheme(AppAccentTheme.rose);
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.settingsSlots(SettingsSlotKind.user).active, 4);
      expect(restored.userPortrait, '远方来的旅者');
      expect(restored.characterPersona, 'character第三备用内容');
      expect(restored.worldSetting, 'world第三备用内容');
      expect(restored.accentTheme, AppAccentTheme.rose);
      final backup =
          jsonDecode(jsonEncode(restored.exportData())) as Map<String, dynamic>;
      controller.setCharacterPersona('待替换');
      await controller.importData(backup);
      for (final kind in SettingsSlotKind.values) {
        final draft = controller.settingsSlots(kind)..active = 0;
        controller.saveSettingsSlots(kind, draft);
      }
      expect(controller.userAddress, '原来的称呼');
      expect(controller.characterPersona, '原来人物性格');
      expect(controller.worldSetting, '原来世界内容');
      final prompt = controller.buildCharacterPrompt();
      expect(prompt, contains('原来的称呼'));
      expect(prompt, isNot(contains('character第三备用内容')));
      expect(prompt, isNot(contains('world第三备用内容')));
      expect(prompt, isNot(contains('远方来的旅者')));
      final oldBackup = controller.exportData()..remove('settingsSlots');
      await controller.importData(oldBackup);
      expect(controller.settingsSlots(SettingsSlotKind.user).active, 0);
      expect(
        controller.settingsSlots(SettingsSlotKind.user).entries[4],
        isNull,
      );
    },
  );

  test(
    'malformed slot storage is bounded and does not replace current profile',
    () async {
      SharedPreferences.setMockInitialValues({
        'user_address': '保留我',
        'settings_slots_v1': 'invalid JSON',
      });
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      expect(
        controller.settingsSlots(SettingsSlotKind.user).entries[0]?['address'],
        '保留我',
      );
      final slots = SettingsSlots.fromJson({
        'active': 500,
        'entries': [
          false,
          1,
          {'text': 12},
        ],
      });
      expect(slots.active, 4);
      expect(slots.entries.length, 5);
      expect(slots.entries[0], isNull);
      expect(slots.entries[2], isEmpty);
    },
  );

  test(
    'all seven palettes have readable primary buttons in both appearances',
    () {
      expect(AppAccentTheme.values.length, 7);
      expect(AppAccentTheme.values.map((v) => v.color).toSet().length, 7);
      for (final accent in AppAccentTheme.values) {
        for (final brightness in Brightness.values) {
          final colors = atelierTheme(accent, brightness).colorScheme;
          final a = colors.primary.computeLuminance();
          final b = colors.onPrimary.computeLuminance();
          final contrast = a > b
              ? (a + 0.05) / (b + 0.05)
              : (b + 0.05) / (a + 0.05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '$accent / $brightness',
          );
        }
      }
    },
  );
}
