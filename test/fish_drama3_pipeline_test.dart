import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';
import 'package:ryza_chat_mvp/src/memory_text.dart';
import 'package:ryza_chat_mvp/src/speech_planner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'model-specific planning follows MCP provider and the saved model',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      for (final entry in [
        (TtsProvider.fishAudioMcp, 'drama-3', true),
        (TtsProvider.fishAudioMcp, 's2.1-pro', false),
        (TtsProvider.fishAudioMcp, '', false),
        (TtsProvider.fishAudio, 'drama-3', false),
      ]) {
        controller.ttsProvider = entry.$1;
        controller.fishMcpModel = entry.$2;
        expect(controller.fishMcpUsesDrama3, entry.$3);
        final prompt = buildContinuousAsmrSystemPrompt(
          controller,
          targetChars: 350,
        );
        expect(prompt.contains('Drama 3 发声'), entry.$3);
      }
    },
  );

  test(
    'Drama 3 planner accepts new cue names and preserves dialogue and memory',
    () async {
      const source = '莱莎：明日も会おう。待っているよ。';
      Future<SpeechPlan> plan(bool drama3) => SpeechPlanner().plan(
        source: source,
        previousEmotion: 'relaxed',
        intensity: TtsEmotionIntensity.natural,
        density: TtsCueDensity.frequent,
        asmr: false,
        drama3: drama3,
        complete: (messages) async {
          expect(messages.first['content']!.contains('当前为Drama 3'), drama3);
          return jsonEncode({
            'segments': [
              {
                'id': 0,
                'emotion': 'relaxed',
                'cues': [
                  {'offset': 0, 'tag': 'soft'},
                  {'offset': 7, 'tag': 'stress'},
                ],
              },
            ],
          });
        },
      );
      final drama = await plan(true);
      expect(drama.lines[0], contains('[soft]'));
      expect(drama.lines[0], contains('[stress]'));
      expect(drama.lines[0], isNot(contains('<')));
      expect(
        displayTextForAssistantResponse(drama.apply(source)),
        displayTextForAssistantResponse(source),
      );
      expect(cleanMemoryText(drama.lines[0]!), '明日も会おう。待っているよ。');
      final other = await plan(false);
      expect(other.lines[0], isNot(contains('[soft]')));
      expect(other.lines[0], isNot(contains('[stress]')));
    },
  );

  test('new delivery controls obey disabled and sparse density', () {
    const source = '[soft]你好。[stress]慢慢来。[slow]今天有很多时间。';
    final disabled = applyFishEmotionIntensityPerSentence(
      source,
      TtsEmotionIntensity.off,
      density: TtsCueDensity.off,
      drama3: true,
    );
    expect(disabled, isNot(contains('[')));
    expect(disabled.replaceAll(' ', ''), '你好。慢慢来。今天有很多时间。');
    final sparse = applyFishEmotionIntensityPerSentence(
      source,
      TtsEmotionIntensity.off,
      density: TtsCueDensity.sparse,
      drama3: true,
    );
    expect(
      RegExp(r'\[(?:soft|stress|slow)\]').allMatches(sparse),
      hasLength(1),
    );
    expect(sparse.replaceAll(RegExp(r'\[[^\]]+\]|\s+'), ''), '你好。慢慢来。今天有很多时间。');
  });
}
