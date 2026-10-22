import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_catalog.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/npc_chat_contacts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(CharacterCatalog.load);

  test('three-language role tags and ordinary name prefixes share NPC IDs', () {
    for (final entry in {
      'fee': ['fee', 'Fee', 'Fi', '菲', 'フィー'],
      'kala': ['kala', 'Kala', '卡菈', '卡拉', 'カラ', 'カラ・イデアス'],
    }.entries) {
      for (final name in entry.value) {
        for (final prefix in ['角色[$name]', name]) {
          final segments = parseAssistantSegments('$prefix：这是当前 NPC 的一句话。');
          expect(
            segments.single.speaker,
            ChatSpeaker.character,
            reason: prefix,
          );
          expect(segments.single.characterId, entry.key, reason: prefix);
          expect(segments.single.text, '这是当前 NPC 的一句话。');
        }
      }
    }
    final inline = parseAssistantSegments('角色[Fi]：第一句。角色[菲]：第二句。角色[フィー]：第三句。');
    expect(inline.map((segment) => segment.characterId), ['fee', 'fee', 'fee']);
  });

  test('translation and hidden names do not become original NPC speech', () {
    final segments = parseAssistantSegments(
      '<think>角色[fee]：隐藏发言。</think>\n'
      '角色[卡菈]：原文。\n译文：\n菲：译文里复制的人名。',
    );
    expect(
      segments
          .where((s) => s.speaker == ChatSpeaker.character)
          .map((s) => s.characterId),
      ['kala'],
    );
    expect(segments.last.speaker, ChatSpeaker.translation);
    expect(segments.last.text, '菲：译文里复制的人名。');
    final copiedTag = parseAssistantSegments('莱莎：今日は晴れ。\n译文：\n角色[菲]：当然可以。');
    expect(copiedTag.where((s) => s.speaker == ChatSpeaker.character), isEmpty);
    expect(copiedTag.last.speaker, ChatSpeaker.translation);
  });

  test(
    'canonical resolution keeps role domains and ambiguous identities apart',
    () {
      expect(resolveNpcContactId('菲', primaryCharacterId: 'sophie'), isNull);
      expect(resolveNpcContactId('プラフタ', primaryCharacterId: 'sophie'), isNull);
      expect(
        resolveNpcContactId('プラフタ（人形）', primaryCharacterId: 'sophie'),
        'sophie_plachta_doll',
      );
      expect(
        resolveNpcContactId('Plachta (Young)', primaryCharacterId: 'sophie'),
        'sophie_plachta_young',
      );
      final canonical = parseAssistantSegments(
        '角色[プラフタ（人形）]：人偶的记忆。',
        defaultPrimaryCharacterId: 'sophie',
      );
      expect(canonical.single.characterId, 'sophie_plachta_doll');
      expect(resolveNpcContactId('fee', primaryCharacterId: 'unknown'), isNull);
    },
  );

  test(
    'historical name tags contribute to the same NPC in-person memory',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.addUserMessage('菲，给你看这个天蓝纸鹤。');
      controller.addAssistantMessage('角色[菲]：天蓝纸鹤我记住了。');
      controller.addUserMessage('卡菈，记住这片银叶。');
      controller.addAssistantMessage('角色[カラ]：银叶我记住了。');
      expect(controller.buildNpcMessagePrompt('fee'), contains('天蓝纸鹤'));
      expect(controller.buildNpcMessagePrompt('fee'), isNot(contains('银叶')));
      expect(controller.buildNpcMessagePrompt('kala'), contains('银叶'));
      expect(controller.buildNpcMessagePrompt('kala'), isNot(contains('天蓝纸鹤')));
      controller.addNpcContact('fee');
      controller.addNpcContact('kala');
      final backup = controller.exportData();
      final contactIds = (backup['npcChats'] as Map)['contacts'];
      // Alias repair applies to interpretation; saves keep one canonical key.
      expect(jsonEncode(backup['npcChats']), contains('fee'));
      expect(jsonEncode(backup['npcChats']), contains('kala'));
      expect(contactIds, ['fee', 'kala']);
    },
  );
}
