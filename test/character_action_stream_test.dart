import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  test('streamed none does not retrigger an earlier action', () {
    const first = '莱莎：[curious][face:neutral][action:think] 让我想想。';
    const second = '\n莱莎：[calm][face:neutral][action:none] 先别急。';
    final events = <CharacterAction>[];
    String? consumed;
    var text = '';
    for (final character in (first + second).split('')) {
      text += character;
      final cue = performanceCueForAssistantResponse(text);
      final action = cue.action;
      if (action == null || action == CharacterAction.none) continue;
      final key = '${action.name}:${cue.actionCueCount}';
      if (key == consumed) continue;
      consumed = key;
      events.add(action);
    }
    expect(events, [CharacterAction.think]);
    expect(
      performanceCueForAssistantResponse(text).action,
      CharacterAction.none,
    );
  });

  test('later explicit actions still fire after a quiet segment', () {
    const text = '''莱莎：[curious][action:think] 想一想。
莱莎：[calm][action:none] 嗯。
莱莎：[confident][action:explain] 可以这么做。''';
    final cue = performanceCueForAssistantResponse(text);
    expect(cue.action, CharacterAction.explain);
    expect(cue.actionCueCount, 3);
    final segments = performanceSegmentsForAssistantResponse(
      text,
      fallbackMood: CharacterMood.neutral,
    );
    expect(segments.map((segment) => segment.action), [
      CharacterAction.think,
      CharacterAction.none,
      CharacterAction.explain,
    ]);
    expect(segments[1].speechText, '[calm] 嗯。');
  });

  test('exact runtime motion group tags are preserved separately', () {
    const text = '莱莎：[confident][face:tease][action:grp_b_03] 看吧！';
    final cue = performanceCueForAssistantResponse(text);
    expect(cue.action, isNull);
    expect(cue.actions, isEmpty);
    expect(cue.motionGroupIds, ['grp_b_03']);
    final segment = performanceSegmentsForAssistantResponse(
      text,
      fallbackMood: CharacterMood.neutral,
    ).single;
    expect(segment.motionGroupIds, ['grp_b_03']);
  });
}
