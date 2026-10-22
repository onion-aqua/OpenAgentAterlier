import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/mimo_tts_client.dart';
import 'package:ryza_chat_mvp/src/mimo_tts_config.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';

Uint8List wav() {
  final bytes = Uint8List(48);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  bytes.setRange(8, 12, ascii.encode('WAVE'));
  bytes.setRange(12, 16, ascii.encode('fmt '));
  bytes.setRange(36, 40, ascii.encode('data'));
  final data = ByteData.sublistView(bytes);
  for (final pair in [(4, 40), (16, 16), (24, 24000), (28, 48000), (40, 4)]) {
    data.setUint32(pair.$1, pair.$2, Endian.little);
  }
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const clone = MimoTtsConfig(
    referencePath: '/private/reference.wav',
    referenceName: 'reference.wav',
  );

  test(
    'MiMo clone uses chat audio protocol and decodes returned WAV',
    () async {
      final sample = wav();
      final client = MimoTtsClient(
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://api.xiaomimimo.com/v1/chat/completions',
          );
          expect(
            request.headers['Authorization'],
            'Bearer test-mimo-key-private',
          );
          final body = jsonDecode(request.body) as Map;
          expect(body['model'], MimoTtsConfig.cloneModel);
          expect(body['stream'], false);
          expect(body.containsKey('input'), false);
          expect(body['messages'][0]['role'], 'user');
          expect(body['messages'][1]['role'], 'assistant');
          expect(body['messages'][1]['content'], '[开心]你好');
          expect(body['audio'], {
            'format': 'wav',
            'voice': 'data:audio/wav;base64,${base64Encode(sample)}',
          });
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'audio': {'data': base64Encode(sample)},
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final result = await client.synthesizeBytes(
        config: clone,
        apiKey: 'test-mimo-key-private',
        text: '[happy][face:happy][action:none]你好',
        intensity: TtsEmotionIntensity.natural,
        density: TtsCueDensity.normal,
        referenceBytes: sample,
      );
      expect(result, sample);
      expect(
        RuntimeLog.instance.formattedText,
        isNot(contains(base64Encode(sample))),
      );
      expect(
        RuntimeLog.instance.formattedText,
        isNot(contains('test-mimo-key-private')),
      );
    },
  );

  test('MiMo preset and design omit unnecessary reference audio', () async {
    for (final model in [
      MimoTtsConfig.presetModel,
      MimoTtsConfig.designModel,
    ]) {
      final client = MimoTtsClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(
            (body['audio'] as Map).containsKey('voice'),
            model == MimoTtsConfig.presetModel,
          );
          expect(body['messages'][0]['content'], contains('轻柔女声'));
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'audio': {'data': base64Encode(wav())},
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      await client.synthesizeBytes(
        config: MimoTtsConfig(model: model, instructions: '轻柔女声'),
        apiKey: 'test',
        text: '你好',
        intensity: TtsEmotionIntensity.natural,
        density: TtsCueDensity.normal,
      );
    }
  });

  test('MiMo sends selected reply language in user instructions', () async {
    for (final language in AppLanguage.values) {
      for (final asmr in [false, true]) {
        final client = MimoTtsClient(
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            expect(body.containsKey('language'), false);
            expect(
              body['messages'][0]['content'],
              contains('目标语言为${language.promptLabel}'),
            );
            expect(body['messages'][1]['content'], 'Test');
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'audio': {'data': base64Encode(wav())},
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        addTearDown(client.close);
        await client.synthesizeBytes(
          config: const MimoTtsConfig(model: MimoTtsConfig.presetModel),
          apiKey: 'test',
          text: 'Test',
          intensity: TtsEmotionIntensity.natural,
          density: TtsCueDensity.normal,
          language: language,
          asmr: asmr,
        );
      }
    }
  });

  test('MiMo encoded reference limit and file signatures are enforced', () {
    expect(mimoEncodedLength(7500000), mimoMaxEncodedAudioBytes);
    expect(mimoEncodedLength(7500001), greaterThan(mimoMaxEncodedAudioBytes));
    expect(
      () => mimoReferenceDataUri(Uint8List(0), 'voice.wav'),
      throwsA(isA<AiServiceException>()),
    );
    expect(
      () => mimoReferenceDataUri(wav(), 'voice.mp3'),
      throwsA(isA<AiServiceException>()),
    );
    expect(
      () => mimoReferenceDataUri(wav(), 'voice.m4a'),
      throwsA(isA<AiServiceException>()),
    );
  });

  test(
    'MiMo protocol errors never become playable JSON or HTML files',
    () async {
      for (final response in [
        http.Response('<html>bad gateway</html>', 502),
        http.Response('{"choices":[]}', 200),
        http.Response(
          '{"choices":[{"message":{"audio":{"data":"%%%"}}}]}',
          200,
        ),
        http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'audio': {'data': base64Encode(utf8.encode('not audio'))},
                },
              },
            ],
          }),
          200,
        ),
      ]) {
        final client = MimoTtsClient(client: MockClient((_) async => response));
        addTearDown(client.close);
        await expectLater(
          client.synthesizeBytes(
            config: const MimoTtsConfig(model: MimoTtsConfig.presetModel),
            apiKey: 'test',
            text: '你好',
            intensity: TtsEmotionIntensity.natural,
            density: TtsCueDensity.normal,
          ),
          throwsA(isA<AiServiceException>()),
        );
      }
    },
  );

  test('MiMo emotion intensity and inline cue density remain independent', () {
    const speech = '[sad]你好，[sigh]我有些累。[breathy]晚安。[face:sad][action:think]';
    final noCues = mimoSpeechPresentation(
      speech,
      clone,
      TtsEmotionIntensity.dramatic,
      TtsCueDensity.off,
    );
    expect(noCues.text, '[悲伤]你好，我有些累。晚安。');
    expect(
      noCues.instructions,
      contains(TtsEmotionIntensity.dramatic.voiceInstruction),
    );
    final noEmotion = mimoSpeechPresentation(
      speech,
      clone,
      TtsEmotionIntensity.off,
      TtsCueDensity.frequent,
      asmr: true,
    );
    expect(noEmotion.text, isNot(contains('[悲伤]')));
    expect(noEmotion.text, contains('[叹气]'));
    expect(noEmotion.text, contains('[气声]'));
    expect(noEmotion.text, isNot(contains('action:')));
    expect(noEmotion.instructions, contains('不喊叫'));
  });

  test('MiMo settings persist locally and backups never import arbitrary file paths', () async {
    final controller = await AppController.load();
    controller.configureMimoTts(
      config: clone,
      enabled: true,
      emotionIntensity: TtsEmotionIntensity.vivid,
      cueDensity: TtsCueDensity.sparse,
      previewText: '试音内容',
    );
    expect(controller.setTtsVoiceMode(TtsVoiceMode.asmr), true);
    await Future<void>.delayed(Duration.zero);
    final reloaded = await AppController.load();
    expect(reloaded.ttsProvider, TtsProvider.mimo);
    expect(reloaded.mimoTts.referencePath, clone.referencePath);
    expect(reloaded.ttsCueDensity, TtsCueDensity.sparse);
    final exported = controller.exportData();
    expect(jsonEncode(exported), isNot(contains('/private/reference.wav')));
    final restored = await AppController.load();
    await restored.importData(exported);
    expect(restored.mimoTts.referencePath, isEmpty);
    expect(restored.mimoTts.validationError, isNotNull);
    expect(
      MimoTtsConfig.fromJson({
        'referencePath': '/secret',
      }, allowLocalReference: false).referencePath,
      isEmpty,
    );
    controller.dispose();
    reloaded.dispose();
    restored.dispose();
  });
}
