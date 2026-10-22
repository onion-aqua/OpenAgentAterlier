import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/auxiliary_llm_tasks.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_script.dart';
import 'package:ryza_chat_mvp/src/dialogue_language_guard.dart';
import 'package:ryza_chat_mvp/src/memory_ledger.dart';

void main() {
  test(
    'legacy and neutral primary labels parse without changing NPC identity',
    () {
      for (final (label, owner) in [
        ('莱莎', 'ryza'),
        ('Ryza', 'ryza'),
        ('苏菲', 'sophie'),
        ('ソフィー', 'sophie'),
        ('Sophie', 'sophie'),
        ('主角', 'sophie'),
        ('protagonist', 'sophie'),
      ]) {
        final segments = parseAssistantSegments(
          '$label：おはよう。\n角色[klaudia]：こんにちは。\n译文：你好。',
          defaultPrimaryCharacterId: 'sophie',
        );
        expect(segments.map((segment) => segment.speaker), [
          ChatSpeaker.ryza,
          ChatSpeaker.character,
          ChatSpeaker.translation,
        ], reason: label);
        expect(segments.first.primaryCharacterId, owner, reason: label);
        expect(assistantSpeakerLabel(segments.first), '主角', reason: label);
        expect(
          assistantSpeakerLabel(segments[1]),
          '角色[klaudia]',
          reason: label,
        );
        expect(assistantSpeakerLabel(segments.last), '译文', reason: label);
      }
    },
  );

  test(
    'translation sends neutral primary identity and retains NPC IDs',
    () async {
      for (final label in ['主角', 'protagonist', '莱莎', '苏菲']) {
        final result = await DialogueTranslator().translate(
          source: '旁白：她走近。\n$label：おはよう。\n角色[klaudia]：こんにちは。',
          language: 'Chinese',
          complete: (messages) async {
            final payload = jsonDecode(messages.last['content']!) as Map;
            expect(payload['lines'], [
              {'id': 1, 'speaker': 'protagonist', 'text': 'おはよう。'},
              {'id': 2, 'speaker': 'klaudia', 'text': 'こんにちは。'},
            ]);
            return jsonEncode({
              'translations': [
                {'id': 1, 'text': '早上好。'},
                {'id': 2, 'text': '你好。'},
              ],
            });
          },
        );
        expect(
          result,
          '旁白：她走近。\n主角：おはよう。\n译文：早上好。\n角色[klaudia]：こんにちは。\n译文：你好。',
        );
        expect(result, isNot(contains('莱莎')));
        expect(result, isNot(contains('苏菲')));
      }
    },
  );

  test(
    'translation rejects neutral protocol labels inside translated prose',
    () async {
      for (final label in ['主角', 'protagonist']) {
        await expectLater(
          DialogueTranslator().translate(
            source: '主角：おはよう。',
            language: 'Chinese',
            complete: (_) async => jsonEncode({
              'translations': [
                {'id': 0, 'text': '$label：早上好。'},
              ],
            }),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('language repair rebuilds primary lines with neutral labels', () async {
    for (final label in ['主角', 'protagonist', '苏菲', '莱莎']) {
      final result = await ensureAssistantReplyLanguages(
        source: '$label：[happy]现在我们一起出发吧。\n角色[klaudia]：こんにちは。',
        replyLanguage: AppLanguage.japanese,
        narratorLanguage: AppLanguage.chinese,
        inlineTranslationLanguage: TranslationLanguage.none,
        complete: (_) async => '{"corrections":[{"id":0,"text":"一緒に出発しよう！"}]}',
      );
      expect(result, '主角：[happy]一緒に出発しよう！\n角色[klaudia]：こんにちは。');
    }
  });

  test('valid legacy text is retained when no repair is required', () async {
    const source = '苏菲：一緒に出発しよう！';
    expect(
      await ensureAssistantReplyLanguages(
        source: source,
        replyLanguage: AppLanguage.japanese,
        narratorLanguage: AppLanguage.chinese,
        inlineTranslationLanguage: TranslationLanguage.none,
        complete: (_) async => fail('Valid historical text needs no request'),
      ),
      source,
    );
  });

  test(
    'ASMR uses protagonist translation identity and never speaks its label',
    () async {
      for (final label in ['主角', 'protagonist']) {
        final policy = AsmrLanguagePolicy(
          replyLanguage: AppLanguage.japanese,
          translationLanguage: TranslationLanguage.chinese,
          independentTranslation: true,
        );
        final segments = await prepareAsmrScript(
          response: '$label：[whispering]今日はゆっくり休もうね。',
          policy: policy,
          complete: (_) async => fail('Valid ASMR needs no language repair'),
          ensureCurrent: () {},
        );
        expect(segments.single.text, '[whispering]今日はゆっくり休もうね。');
        final translations = await translateAsmrSegments(
          segments: segments,
          policy: policy,
          complete: (messages) async {
            final payload = jsonDecode(messages.last['content']!) as Map;
            expect(payload['lines'], [
              {'id': 0, 'speaker': 'protagonist', 'text': '今日はゆっくり休もうね。'},
            ]);
            return '{"translations":[{"id":0,"text":"今天我们慢慢休息吧。"}]}';
          },
          ensureCurrent: () {},
        );
        expect(translations, {0: '今天我们慢慢休息吧。'});
      }
    },
  );

  test('generic primary labels preserve speech and performance without speaking the protocol', () {
    for (final label in ['主角', 'protagonist', '莱莎', '苏菲']) {
      final source = '$label：[happy][face:happy][action:wave]一緒に行こう。\n译文：一起走吧。';
      expect(
        ttsTextForAssistantResponse(
          source,
          fallbackMood: CharacterMood.neutral,
        ),
        '[happy]一緒に行こう。',
      );
      final performance = performanceSegmentsForAssistantResponse(
        source,
        fallbackMood: CharacterMood.neutral,
      );
      expect(performance, hasLength(1));
      expect(performance.single.speechText, '[happy]一緒に行こう。');
      expect(performance.single.action, CharacterAction.wave);
    }
  });

  test(
    'neutral memory labels identify the actor without duplicate prefixes',
    () {
      for (final label in ['主角', 'protagonist']) {
        final facts = MemoryLedger.extractTurn(
          userText: '好的。',
          assistantText: '$label：我收到了一颗苹果。',
          sourceMessageId: 'generic-item-$label',
        );
        expect(facts, hasLength(1));
        expect(facts.single.summary, '$label确认物品变化：$label收到了一颗苹果。');
        expect(facts.single.summary, isNot(contains('$label：')));
        expect(facts.single.sourceRole, 'assistant');
      }
    },
  );
}
