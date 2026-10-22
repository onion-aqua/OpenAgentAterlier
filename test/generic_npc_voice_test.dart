import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  const response = '主角：こんにちは。\n角色[klaudia]：一緒に行こう。\n译文：一起走吧。';

  test('generic owner cannot route an NPC to a built-in voice', () {
    final speech = assistantSpeechSegmentsForResponse(
      response,
      activeCharacterId: 'ryza',
      allowPresetNpcVoices: false,
      fallbackMood: CharacterMood.neutral,
    );
    expect(speech, hasLength(1));
    expect(speech.single.isPrimary, isTrue);
    expect(speech.single.speechText, contains('こんにちは。'));

    // Reading an old NPC line remains possible without activating its voice.
    final npc = parseAssistantSegments(response)[1];
    expect(npc.characterId, 'klaudia');
    expect(displayTextForAssistantSegment(npc), '一緒に行こう。');
    expect(
      isKlaudiaSpeechSegment(
        npc,
        activeCharacterId: 'ryza',
        allowPresetNpcVoices: false,
      ),
      isFalse,
    );
  });

  test(
    'a response containing only an old NPC never synthesizes for a model',
    () {
      expect(
        assistantSpeechSegmentsForResponse(
          '角色[klaudia]：おはよう。',
          activeCharacterId: 'ryza',
          allowPresetNpcVoices: false,
          fallbackMood: CharacterMood.neutral,
        ),
        isEmpty,
      );
    },
  );

  test('explicit legacy voice routing keeps its compatibility behavior', () {
    final speech = assistantSpeechSegmentsForResponse(
      response,
      activeCharacterId: 'ryza',
      allowPresetNpcVoices: true,
      fallbackMood: CharacterMood.neutral,
    );
    expect(speech.map((segment) => segment.isPrimary), [true, false]);
    expect(
      fishReferenceIdForAssistantSpeech(
        speech.last,
        primaryReferenceId: 'imported-voice',
      ),
      klaudiaFishAudioReferenceId,
    );
  });
}
