import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/speech_media_probe.dart';
import 'package:ryza_chat_mvp/src/speech_preparation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final eventChannels = <String>{};
  int? durationMilliseconds;
  int? lateDurationMilliseconds;
  bool rejectSource = false;

  Future<void> event(String id, Map<String, Object> payload) =>
      messenger.handlePlatformMessage(
        'xyz.luan/audioplayers/events/$id',
        const StandardMethodCodec().encodeSuccessEnvelope(payload),
        (_) {},
      );

  setUpAll(() async {
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    await AudioPlayer.global.ensureInitialized();
  });

  setUp(() {
    calls.clear();
    durationMilliseconds = 12880;
    lateDurationMilliseconds = null;
    rejectSource = false;
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        calls.add(call);
        final id = (call.arguments as Map?)?['playerId'] as String?;
        if (call.method == 'create') {
          final channel = 'xyz.luan/audioplayers/events/$id';
          eventChannels.add(channel);
          messenger.setMockMethodCallHandler(
            MethodChannel(channel),
            (_) async => null,
          );
        }
        if (call.method == 'setSourceUrl') {
          if (rejectSource) {
            await messenger.handlePlatformMessage(
              'xyz.luan/audioplayers/events/$id',
              const StandardMethodCodec().encodeErrorEnvelope(
                code: 'WindowsAudioError',
                message: 'Local decoder fixture',
              ),
              (_) {},
            );
            return null;
          }
          await event(id!, {'event': 'audio.onPrepared', 'value': true});
        }
        if (call.method == 'getDuration') {
          if (lateDurationMilliseconds case final int lateDuration) {
            Timer(const Duration(milliseconds: 10), () {
              unawaited(
                event(id!, {
                  'event': 'audio.onDuration',
                  'value': lateDuration,
                }),
              );
            });
          }
          return durationMilliseconds;
        }
        return null;
      },
    );
  });

  tearDown(() {
    for (final channel in eventChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
    eventChannels.clear();
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      null,
    );
  });

  tearDownAll(() {
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  test(
    'reads a playable MP3 duration without playback or companion focus',
    () async {
      expect(
        await probeSpeechDuration('C:/local/returned.mp3'),
        const Duration(milliseconds: 12880),
      );
      expect(calls.any((call) => call.method == 'create'), isTrue);
      expect(
        calls
            .where((call) => call.method == 'setVolume')
            .map((call) => (call.arguments as Map)['volume']),
        [0],
      );
      expect(
        (calls.singleWhere((call) => call.method == 'setSourceUrl').arguments
            as Map)['url'],
        'C:/local/returned.mp3',
      );
      expect(
        calls.any(
          (call) =>
              call.method == 'resume' ||
              call.method == 'play' ||
              call.method == 'setAudioActive',
        ),
        isFalse,
      );
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    },
  );

  test('uses the injected independent player factory', () async {
    var created = 0;
    await probeSpeechDuration(
      'C:/local/returned.wav',
      createPlayer: () {
        created++;
        return AudioPlayer();
      },
    );
    expect(created, 1);
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
  });

  test(
    'accepts a delayed duration event after an initially missing query',
    () async {
      durationMilliseconds = null;
      lateDurationMilliseconds = 19250;
      expect(
        await probeSpeechDuration('C:/local/returned.mp3'),
        const Duration(milliseconds: 19250),
      );
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    },
  );

  for (final invalid in <int?>[null, 0, -1]) {
    test('missing or invalid duration $invalid fails and disposes', () async {
      durationMilliseconds = invalid;
      await expectLater(
        probeSpeechDuration('C:/local/invalid.mp3'),
        throwsA(
          isA<TtsAudioQualityException>().having(
            (error) => error.code,
            'code',
            'audio_decode_failed',
          ),
        ),
      );
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    });
  }

  test('source decoder failure disposes without retrying or playing', () async {
    rejectSource = true;
    await expectLater(
      probeSpeechDuration('C:/local/invalid.mp3'),
      throwsA(
        isA<TtsAudioQualityException>().having(
          (error) => error.code,
          'code',
          'audio_decode_failed',
        ),
      ),
    );
    expect(calls.where((call) => call.method == 'setSourceUrl'), hasLength(1));
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    expect(
      calls.any((call) => call.method == 'resume' || call.method == 'play'),
      isFalse,
    );
  });
}
