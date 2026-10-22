import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  test('user wording alone does not create a character performance event', () {
    // Motion playback is driven by the model's explicit protocol tags. A user
    // request must not be interpreted locally as a Spine group id.
    const userText = '请抱臂、拍手，再执行 motion_A_001_idle';
    final cue = performanceCueForAssistantResponse(userText);

    expect(cue.action, isNull);
    expect(cue.actions, isEmpty);
    expect(cue.actionCueCount, 0);
  });

  test('only an explicit Ryza action tag creates a performance event', () {
    const response = '莱莎：[curious][face:neutral][action:think] 让我想想。';
    final cue = performanceCueForAssistantResponse(response);

    expect(cue.action, CharacterAction.think);
    expect(cue.actions, [CharacterAction.think]);
    expect(cue.actionCueCount, 1);
  });
}
