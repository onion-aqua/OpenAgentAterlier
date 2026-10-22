import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/memory_ledger.dart';
import 'package:ryza_chat_mvp/src/memory_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _document(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('extracts every high signal sentence and keeps provenance', () {
    final facts = MemoryLedger.extractTurn(
      userText: '我们约定明天去森林。收到你的苹果。',
      assistantText:
          '<think>内部推理：明天。</think><answer>好，明天一起出发。</answer>\n'
          '<tool_call>不要保存这个工具参数</tool_call>',
      sourceMessageId: 'assistant-1',
      now: DateTime(2026, 10, 6),
    );

    expect(facts, isNotEmpty);
    expect(facts.where((fact) => fact.category == 'promise'), hasLength(2));
    expect(facts.any((fact) => fact.category == 'item'), isTrue);
    expect(facts.every((fact) => !fact.summary.contains('内部推理')), isTrue);
    expect(facts.every((fact) => !fact.summary.contains('工具参数')), isTrue);
    expect(facts.any((fact) => fact.sourceRole == 'user'), isTrue);
    expect(facts.any((fact) => fact.sourceRole == 'assistant'), isTrue);
  });

  test('drops an unclosed reasoning block from a partial model response', () {
    final facts = MemoryLedger.extractTurn(
      userText: '我们约定明天见。',
      assistantText: '<think>明天的内部计划还没有结束，不能成为记忆。',
      sourceMessageId: 'assistant-partial',
    );
    expect(facts, hasLength(1));
    expect(facts.single.summary, contains('约定明天'));
    expect(facts.single.summary, isNot(contains('内部计划')));
  });

  test('delivery cues and discussion of NPC lore are not durable events', () {
    final facts = MemoryLedger.extractTurn(
      userText: '介绍一下伙伴们。',
      assistantText:
          '莱莎：[happy]えへへ、終にわたしたちの仲間のこと話すの、なんだか[emphasis]新鮮だなあ。\n'
          'レントは剣の腕を磨くのに夢中な熱血漢で、タオは本が大好きで遺跡のことなら誰より詳しいんだ。\n'
          '莱莎住在库肯岛的村子，在工坊学习炼金术。\n'
          '[happy]でもね、アンペルさんとリラさんのおかげで、アタシたちも[emphasis]ここまでやってきた。',
      sourceMessageId: 'lore-turn',
    );
    expect(facts, isEmpty);
  });

  test(
    'retains a complete attributed Japanese promise without speech cues',
    () {
      const assertion = '明日一緒に森へ出発して、帰ってから集めた薬草で新しい薬を作ることを約束したので、準備を済ませて待っている';
      final facts = MemoryLedger.extractTurn(
        userText: 'ありがとう。',
        assistantText: '莱莎：[very happy]$assertion[emphasis]。',
        sourceMessageId: 'promise-turn',
      );
      expect(facts, hasLength(1));
      expect(facts.single.category, 'promise');
      expect(facts.single.summary, '莱莎确认约定：$assertion。');
      final entries =
          _document(MemoryLedger.mergeIntoTimeline('', facts)!)['entries']
              as List;
      expect(entries.single['summary'], contains('準備を済ませて待っている。'));
      expect(entries.single['local_ledger_version'], 2);
      expect(entries.single['summary'], isNot(contains('[emphasis]')));
    },
  );

  test(
    'questions, wishes and unaccepted item requests are not event facts',
    () {
      for (final input in [
        '明天一起出发？',
        '你能不能答应明天去森林。',
        '如果明天一起出发就好了。',
        '请送给我苹果。',
        '我希望明天一起出发。',
      ]) {
        final facts = MemoryLedger.extractTurn(
          userText: input,
          assistantText: '我还没决定。',
          sourceMessageId: 'request-turn',
        );
        expect(
          facts.where((fact) => fact.category != 'user_preference'),
          isEmpty,
          reason: input,
        );
      }
    },
  );

  test('only a user assertion can establish a user preference', () {
    final facts = MemoryLedger.extractTurn(
      userText: '我喜欢苹果。',
      assistantText: '[happy]我喜欢梨子。',
      sourceMessageId: 'preference-turn',
    );
    expect(facts, hasLength(1));
    expect(facts.single.sourceRole, 'user');
    expect(facts.single.summary, '用户表达偏好：用户喜欢苹果。');
  });

  test('an explicit Japanese user preference remains recallable', () {
    final facts = MemoryLedger.extractTurn(
      userText: '私はりんごが好き。',
      assistantText: '[happy]覚えておくね。',
      sourceMessageId: 'ja-preference-turn',
    );
    expect(facts, hasLength(1));
    expect(facts.single.category, 'user_preference');
    expect(facts.single.summary, contains('私はりんごが好き。'));
  });

  test('user colons retain the full preference assertion and provenance', () {
    for (final assertion in ['我的名字是：小明', '我喜欢：苹果', '我喜欢:苹果']) {
      final facts = MemoryLedger.extractTurn(
        userText: '$assertion。',
        assistantText: '记住了。',
        sourceMessageId: 'colon-preference-turn',
      );
      expect(facts, hasLength(1), reason: assertion);
      expect(facts.single.category, 'user_preference');
      expect(facts.single.summary, contains(assertion.substring(1)));
      expect(facts.single.sourceRole, 'user');
      expect(facts.single.sourceMessageId, 'colon-preference-turn');
    }
  });

  test('ordinary assistant headings are not mistaken for speaker names', () {
    final facts = MemoryLedger.extractTurn(
      userText: '好的。',
      assistantText: '约定：我们明天一起出发。',
      sourceMessageId: 'colon-heading-turn',
    );
    expect(facts, hasLength(1));
    expect(facts.single.summary, '角色确认约定：约定：我们明天一起出发。');
    expect(facts.single.sourceRole, 'assistant');
  });

  test('only explicit supported assistant speakers lose their label', () {
    for (final label in [
      '主角',
      'protagonist',
      '莱莎',
      'ライザ',
      '苏菲',
      'Sophie',
      '角色[claudia]',
    ]) {
      final facts = MemoryLedger.extractTurn(
        userText: '好的。',
        assistantText: '$label：我收到了一颗苹果。',
        sourceMessageId: 'speaker-label-turn',
      );
      expect(facts, hasLength(1), reason: label);
      expect(facts.single.summary, '$label确认物品变化：$label收到了一颗苹果。');
      expect(facts.single.sourceRole, 'assistant');
    }
  });

  test(
    'narration retains its text instead of becoming a speaker assertion',
    () {
      final facts = MemoryLedger.extractTurn(
        userText: '继续。',
        assistantText: '旁白：我收到了一颗苹果。',
        sourceMessageId: 'narration-turn',
      );
      expect(facts, hasLength(1));
      expect(facts.single.summary, '确认物品变化：旁白：我收到了一颗苹果。');
      expect(facts.single.sourceRole, 'assistant');
    },
  );

  test('append-only merge is idempotent and preserves user facts', () {
    final first = MemoryLedger.extractTurn(
      userText: '我喜欢在湖边采集。',
      assistantText: '好，明天一起去湖边。',
      sourceMessageId: 'assistant-1',
      now: DateTime(2026, 10, 6),
    );
    final saved = MemoryLedger.mergeIntoTimeline('', first)!;
    final repeated = MemoryLedger.mergeIntoTimeline(saved, first)!;
    expect(_document(repeated)['entries'], hasLength(2));

    final edited = MemoryTimeline.normalizeExisting(
      jsonEncode({
        'entries': [
          {
            'sequence': 1,
            'category': 'user_preference',
            'summary': '用户手动修正为喜欢在海岸采集。',
            'importance': 4,
          },
        ],
      }),
    );
    final protected = MemoryLedger.mergeIntoTimeline(edited, first)!;
    final entries = _document(protected)['entries'] as List;
    expect(entries.first['summary'], '用户手动修正为喜欢在海岸采集。');
  });

  test('local facts are recorded without an auxiliary model', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.setLongTermMemoryEnabled(true);
    controller.addUserMessage('我希望明天去森林。');
    controller.addAssistantMessage('好，我们约定明天一起出发。');

    expect(
      controller.recordDeterministicMemoryForLastTurn(
        now: DateTime(2026, 10, 6),
      ),
      isTrue,
    );
    final memory = _document(controller.memorySummary);
    expect(
      (memory['entries'] as List).any(
        (entry) => entry['category'] == 'promise',
      ),
      isTrue,
    );
    expect(
      controller.memoryPromptForCurrentConversation(currentInput: '森林'),
      contains('森林'),
    );
  });

  test(
    'completed stream commits local facts through the chat entry point',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.setLongTermMemoryEnabled(true);
      controller.addUserMessage('我们约定明天去森林。');
      controller.beginAssistantStream();
      controller.appendAssistantDelta('好，明天一起出发。');
      final messageId = controller.messages.last.id;

      controller.finishAssistantStream(recordMemory: true);

      final entries = _document(controller.memorySummary)['entries'] as List;
      expect(entries, isNotEmpty);
      expect(
        entries.every((entry) => entry['source_message_id'] == messageId),
        isTrue,
      );
      expect(
        controller.memoryPromptForCurrentConversation(currentInput: '森林'),
        contains('森林'),
      );
    },
  );

  for (final failed in [false, true]) {
    test(
      '${failed ? 'failed' : 'cancelled'} stream does not commit partial facts',
      () async {
        SharedPreferences.setMockInitialValues({});
        final controller = await AppController.load();
        addTearDown(controller.dispose);
        controller.setLongTermMemoryEnabled(true);
        controller.addUserMessage('我们约定明天去森林。');
        controller.beginAssistantStream();
        controller.appendAssistantDelta('好，明天一起');

        if (failed) {
          controller.failAssistantStream('网络连接中断');
        } else {
          controller.finishAssistantStream();
        }

        expect(controller.memorySummary, isEmpty);
      },
    );
  }
}
