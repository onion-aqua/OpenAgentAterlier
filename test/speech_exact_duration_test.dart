import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/audio_envelope.dart';
import 'package:ryza_chat_mvp/src/speech_envelope_loader.dart';
import 'package:ryza_chat_mvp/src/speech_loudness.dart';
import 'package:ryza_chat_mvp/src/speech_spatial.dart';
import 'package:ryza_chat_mvp/src/tts_spatial_settings.dart';

Uint8List _wave({required int rate, required int frames, int channels = 1}) {
  final result = Uint8List(44 + frames * channels * 2);
  final data = ByteData.sublistView(result);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    result.setRange(entry.key, entry.key + 4, entry.value.codeUnits);
  }
  data.setUint32(4, result.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, frames * channels * 2, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    final sample = (sin(2 * pi * 230 * frame / rate) * 4000).round();
    for (var channel = 0; channel < channels; channel++) {
      data.setInt16(
        44 + (frame * channels + channel) * 2,
        sample,
        Endian.little,
      );
    }
  }
  return result;
}

void main() {
  test('real PCM 19 and 71 seconds remain exact at several rates/channels', () {
    for (final rate in [16000, 24000, 44100, 48000]) {
      for (final channels in [1, 2]) {
        for (final seconds in [19, 71]) {
          final envelope = AudioAmplitudeEnvelope.tryParseWav(
            _wave(rate: rate, frames: rate * seconds, channels: channels),
          )!;
          expect(envelope.duration, Duration(seconds: seconds));
          expect(envelope.values.length, seconds * 50);
        }
      }
    }
  });

  test('partial last RMS window does not round up exact PCM duration', () {
    for (final rate in [16000, 22050, 24000, 44100, 48000]) {
      for (final channels in [1, 2, 6]) {
        final frames = rate * 2 + 117;
        final envelope = AudioAmplitudeEnvelope.tryParseWav(
          _wave(rate: rate, frames: frames, channels: channels),
        )!;
        final exact = Duration(microseconds: frames * 1000000 ~/ rate);
        expect(envelope.duration, exact);
        expect(envelope.valueAt(exact), 0);
        expect(
          envelope.values.length * 20000,
          greaterThan(exact.inMicroseconds),
        );
      }
    }
  });

  test(
    'balancing and mono to stereo preserve complete and partial durations',
    () {
      for (final seconds in [19, 71]) {
        const rate = 16000;
        final frames = rate * seconds + 117;
        final original = _wave(rate: rate, frames: frames);
        final balanced = balanceSpeechWav(original)!;
        final stereo = spatializeSpeechWav(
          balanced,
          position: TtsStereoPosition.left,
        )!;
        final exact = Duration(microseconds: frames * 1000000 ~/ rate);
        for (final bytes in [original, balanced, stereo]) {
          expect(AudioAmplitudeEnvelope.tryParseWav(bytes)!.duration, exact);
        }
      }
    },
  );

  test(
    'native map carries exact PCM duration and old RMS lists still work',
    () {
      final exact = parseNativeSpeechEnvelope({
        'values': [0.2, 0.3],
        'durationUs': 20001,
        'sampleFrames': 960,
        'sampleRate': 48000,
        'channels': 2,
      })!;
      expect(exact.duration, const Duration(microseconds: 20001));
      expect(parseNativeSpeechEnvelope([0.2, 0.3])!.duration, isNull);
      expect(
        parseNativeSpeechEnvelope({
          'values': [0.2],
          'durationUs': 0,
        }),
        isNull,
      );
      expect(
        parseNativeSpeechEnvelope({
          'values': ['bad'],
          'durationUs': 20000,
        }),
        isNull,
      );
    },
  );

  test('WAV sample boundaries and channel metadata are validated', () {
    final original = _wave(rate: 16000, frames: 100, channels: 2);
    final wrongBlock = Uint8List.fromList(original);
    ByteData.sublistView(wrongBlock).setUint16(32, 2, Endian.little);
    expect(AudioAmplitudeEnvelope.tryParseWav(wrongBlock), isNull);
    expect(
      AudioAmplitudeEnvelope.tryParseWav(
        original.sublist(0, original.length - 2),
      ),
      isNull,
    );
    expect(
      AudioAmplitudeEnvelope.tryParseWav(
        original,
        frameDuration: Duration.zero,
      ),
      isNull,
    );
  });
}
