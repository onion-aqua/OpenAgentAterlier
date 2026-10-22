import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reply-time input preference survives local backup import', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.setUnlockInputWhileReplying(true);
    expect(controller.exportData()['unlockInputWhileReplying'], isTrue);

    final restored = await AppController.load();
    await restored.importData(controller.exportData());
    expect(restored.unlockInputWhileReplying, isTrue);
  });

  test(
    'custom user profile priority is persisted and changes the prompt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      controller.configureUserProfile(
        address: '伙伴',
        portrait: '',
        relationshipRole: UserRelationshipRole.familiarPartner,
        interactionStyle: UserInteractionStyle.balanced,
        boundaries: '',
        relationshipCustom: '一起旅行的老朋友',
        interactionCustom: '多给行动建议',
        preferCustom: false,
      );
      expect(controller.buildCharacterPrompt(), isNot(contains('一起旅行的老朋友')));
      controller.setPreferCustomUserProfile(true);
      expect(controller.buildCharacterPrompt(), contains('一起旅行的老朋友'));
      expect(controller.exportData()['preferCustomUserProfile'], isTrue);
      final restored = await AppController.load();
      await restored.importData(controller.exportData());
      expect(restored.preferCustomUserProfile, isTrue);
    },
  );

  test('agent context is retrieved on demand', () async {
    SharedPreferences.setMockInitialValues({});
    final c = await AppController.load();
    c.setAgentEnabled(true);
    c.longTermMemoryEnabled = true;
    c.memorySummary = 'MEMORY_SENTINEL';
    final prompt = c.buildCharacterPrompt();
    expect(prompt, contains('search_memory'));
    expect(prompt, contains('lookup_character'));
    expect(prompt, isNot(contains('MEMORY_SENTINEL')));
    expect(
      c.queryContextTool('search_memory', {'query': '约定'}),
      contains('MEMORY_SENTINEL'),
    );
    c.longTermMemoryEnabled = false;
    expect(
      c.queryContextTool('search_memory', {'query': '约定'}),
      isNot(contains('MEMORY_SENTINEL')),
    );
  });
  test(
    'world setting is independent and included in both prompt modes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      final original = controller.editableWorldSetting;
      final persona = controller.editableCharacterPersona;
      controller.setWorldSetting('世界由浮空岛构成。');
      for (final compact in [false, true]) {
        controller.setLlmContextCompatibility(compact);
        expect(controller.buildCharacterPrompt(), contains('世界由浮空岛构成。'));
        expect(
          controller.buildCharacterPrompt(),
          contains('ryzaSpeechLanguage'),
        );
      }
      final restored = await AppController.load();
      await restored.importData(controller.exportData());
      expect(restored.editableWorldSetting, '世界由浮空岛构成。');
      expect(restored.editableCharacterPersona, persona);
      restored.setWorldSetting(original);
      expect(restored.worldSetting, isEmpty);
    },
  );
  test(
    'editable persona preserves machine rules and restores defaults',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      final original = controller.editableCharacterPersona;
      controller.setCharacterPersona('喜欢观察星空的炼金术士');
      for (final compact in [false, true]) {
        controller.setLlmContextCompatibility(compact);
        final prompt = controller.buildCharacterPrompt();
        expect(prompt, contains('喜欢观察星空的炼金术士'));
        expect(prompt, contains('ryzaSpeechLanguage'));
        expect(prompt, contains('[action:none]'));
      }
      final restored = await AppController.load();
      await restored.importData(controller.exportData());
      expect(restored.characterPersona, '喜欢观察星空的炼金术士');
      restored.setCharacterPersona(original);
      expect(restored.characterPersona, isEmpty);
      expect(restored.editableCharacterPersona, original);
    },
  );
  test(
    'persona and world injection switches preserve machine protocols',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      controller.setCharacterPersona('PERSONA_SENTINEL');
      controller.setWorldSetting('WORLD_SENTINEL');

      expect(controller.buildCharacterPrompt(), contains('PERSONA_SENTINEL'));
      expect(controller.buildCharacterPrompt(), contains('WORLD_SENTINEL'));

      controller.setCharacterPersonaInjectionEnabled(false);
      controller.setWorldSettingInjectionEnabled(false);
      for (final compact in [false, true]) {
        controller.setLlmContextCompatibility(compact);
        final prompt = controller.buildCharacterPrompt();
        expect(prompt, isNot(contains('PERSONA_SENTINEL')));
        expect(prompt, isNot(contains('WORLD_SENTINEL')));
        expect(prompt, contains('人物详细设定注入已关闭'));
        expect(prompt, contains('世界书注入已关闭'));
        expect(prompt, contains('ryzaSpeechLanguage'));
        expect(prompt, contains('[action:none]'));
      }

      final restored = await AppController.load();
      await restored.importData(controller.exportData());
      expect(restored.characterPersonaInjectionEnabled, isFalse);
      expect(restored.worldSettingInjectionEnabled, isFalse);
    },
  );
  test(
    'compact context preserves contracts and injects NPC on mention',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      final full = controller.buildCharacterPrompt();
      controller.setLlmContextCompatibility(true);
      final compact = controller.buildCharacterPrompt();
      expect(compact.length, lessThanOrEqualTo(full.length));
      // The compatibility mode reserves a 6000-character history budget. The
      // fixed protocol itself is intentionally kept below that budget; this
      // ceiling is less brittle than the old 4000-character assertion after
      // adding the runtime action-capability contract.
      expect(compact.length, lessThan(6000));
      expect(compact, contains('ryzaSpeechLanguage'));
      expect(compact, contains('[action:none]'));
      final candidates = controller.characterCatalog.encountersFor(
        controller.selectedStageId,
      );
      if (candidates.isNotEmpty) {
        final npc = candidates.first.profile;
        expect(compact, isNot(contains(npc.encounterPrompt)));
        expect(
          controller.buildCharacterPrompt(currentInput: npc.names.chinese),
          contains(npc.encounterPrompt),
        );
      }
      final backup = controller.exportData();
      final restored = await AppController.load();
      await restored.importData(backup);
      expect(restored.llmContextCompatibility, true);
    },
  );
  test('memory prompt honors current input and disabled state', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.updateMemorySummary(
      '{"entries":[{"date":"2026-09-10","category":"other","importance":2,"summary":"我们约好明天去森林采集星砂。","keywords":["星砂"]}]}',
    );
    expect(
      controller.memoryPromptForCurrentConversation(currentInput: '星砂'),
      contains('星砂'),
    );
    controller.setLongTermMemoryEnabled(false);
    expect(
      controller.memoryPromptForCurrentConversation(currentInput: '星砂'),
      contains('长期记忆功能已关闭'),
    );
  });

  test(
    'compact memory prompt keeps state and valid entry boundaries',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.updateMemorySummary(
        jsonEncode({
          'entries': [
            for (var index = 0; index < 12; index++)
              {
                'date': '2026-09-${(index + 1).toString().padLeft(2, '0')}',
                'category': 'other',
                'importance': 1,
                'summary': 'compact-memory-$index',
              },
            {
              'date': '2026-09-20',
              'category': 'relationship_turning_point',
              'importance': 5,
              'summary': '当前关系已确认',
              'state_change': {'domain': '关系', 'from': '陌生人', 'to': '伙伴'},
            },
          ],
        }),
      );
      controller.setLlmContextCompatibility(true);
      final prompt = controller.buildCharacterPrompt();
      expect(prompt, contains('"current_state"'));
      expect(prompt, contains('compact-memory-11'));
      expect(prompt, contains('其余条目可通过 search_memory 按当前话题查询。'));
      // The compact document must not be a suffix fragment beginning in the
      // middle of a JSON string.
      expect(prompt, contains('"schema_version":2'));
    },
  );

  test(
    'contact request targets are included in the same LLM prompt snapshot',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final prompt = controller.buildCharacterPrompt(
        currentInput: '能否交换联系方式？',
        contactRequestIds: const ['claudia'],
      );
      expect(prompt, contains('本轮应用根据点名或最近在场发言锁定联系请求目标'));
      expect(prompt, contains('claudia='));
      expect(prompt, contains('角色[精确 npc_id]'));
    },
  );
}
