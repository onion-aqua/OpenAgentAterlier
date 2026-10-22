import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/audio_envelope.dart';
import 'package:ryza_chat_mvp/src/tts_duration_guard.dart';

void main() {
  group('decoded duration', () {
    test('uses precise decoded duration before RMS window length', () {
      final envelope = AudioAmplitudeEnvelope.fromRms(
        List<double>.filled(3550, .2),
        duration: const Duration(seconds: 19),
      );
      expect(ttsAudioDuration(envelope), const Duration(seconds: 19));
    });

    test('precise duration remains available without RMS windows', () {
      expect(
        ttsAudioDuration(
          const AudioAmplitudeEnvelope(
            frameDuration: Duration.zero,
            values: [],
            duration: Duration(milliseconds: 19001),
          ),
        ),
        const Duration(milliseconds: 19001),
      );
    });

    test('falls back to windows without truncating excessive audio', () {
      final envelope = AudioAmplitudeEnvelope.fromRms(
        List<double>.filled(3550, .2),
      );
      expect(ttsAudioDuration(envelope), const Duration(seconds: 71));
      expect(
        ttsAudioDuration(
          const AudioAmplitudeEnvelope(
            frameDuration: Duration(seconds: 1),
            values: [1],
            duration: Duration.zero,
          ),
        ),
        const Duration(seconds: 1),
      );
      expect(
        ttsAudioDuration(
          AudioAmplitudeEnvelope.fromRms(
            List<double>.filled(601, .1),
            frameDuration: const Duration(seconds: 1),
          ),
        ),
        const Duration(seconds: 601),
      );
    });

    test('missing or unusable duration is unknown', () {
      expect(ttsAudioDuration(null), isNull);
      expect(
        ttsAudioDuration(
          const AudioAmplitudeEnvelope(
            frameDuration: Duration.zero,
            values: [1],
          ),
        ),
        isNull,
      );
      expect(ttsAudioDuration(AudioAmplitudeEnvelope.fromRms([])), isNull);
    });
  });

  group('duration plausibility', () {
    const japanese = '今日はそばにいてくれてありがとう。外の星を眺めながら、少しだけ静かにお話ししようね。';

    TtsDurationAssessment assess(
      String text, {
      String? language,
      bool asmr = false,
      double speed = 1,
      Duration actual = Duration.zero,
    }) => assessTtsAudioDuration(
      TtsDurationContext(
        text: text,
        languageCode: language,
        asmr: asmr,
        effectiveSpeed: speed,
      ),
      actual,
    );

    test(
      'normal Japanese 19-second clip survives a former 15-second limit',
      () {
        final value = assess(
          japanese,
          language: 'ja',
          actual: const Duration(seconds: 19),
        );
        expect(value.isOverlong, isFalse);
        expect(value.maximum, greaterThan(const Duration(seconds: 19)));
        expect(value.maximum, lessThan(const Duration(seconds: 71)));
        expect(value.expected, greaterThan(Duration.zero));
      },
    );

    test(
      'a minute of unintended audio for the same short text is rejected',
      () {
        final value = assess(
          japanese,
          language: 'ja',
          actual: const Duration(seconds: 71),
        );
        expect(value.isOverlong, isTrue);
        expect(value.isSuspicious, isFalse);
        expect(value.reason, 'excessive_duration');
      },
    );

    test('short Chinese text still rejects excessive decoded audio', () {
      final actual = ttsAudioDuration(
        AudioAmplitudeEnvelope.fromRms(List<double>.filled(500, .2)),
      )!;
      expect(actual, const Duration(seconds: 10));
      expect(isTtsAudioOverlong('等一下。', actual), isTrue);
      expect(isTtsAudioOverlong('嗯。', const Duration(seconds: 4)), isFalse);
      expect(
        isTtsAudioOverlong('嗯。', const Duration(seconds: 5), asmr: true),
        isFalse,
      );
    });

    test('soft boundary reports uncertainty without discarding paid audio', () {
      final baseline = assess(japanese, language: 'ja');
      final value = assess(
        japanese,
        language: 'ja',
        actual: baseline.softMaximum + const Duration(milliseconds: 1),
      );
      expect(value.isOverlong, isFalse);
      expect(value.isSuspicious, isTrue);
      expect(value.reason, 'longer_than_expected');
      expect(value.maximum, greaterThan(value.softMaximum));
      expect(value.softMaximum, greaterThan(value.expected));
    });

    test(
      'known effective slow speed changes the estimate, not a model name',
      () {
        final normal = assess(japanese, language: 'ja');
        final slow = assess(japanese, language: 'ja', speed: .5);
        final fast = assess(japanese, language: 'ja', speed: 2);
        expect(slow.expected, greaterThan(normal.expected));
        expect(fast.expected, lessThan(normal.expected));
        expect(slow.effectiveSpeed, .5);
        expect(normal.effectiveSpeed, 1);
      },
    );

    test('invalid or extreme speeds cannot create unlimited allowances', () {
      final normal = assess(japanese, language: 'ja');
      for (final speed in [double.nan, double.infinity, -1.0, 0.0]) {
        expect(
          assess(japanese, language: 'ja', speed: speed).maximum,
          normal.maximum,
        );
      }
      expect(
        assess(japanese, language: 'ja', speed: .0001).maximum,
        assess(japanese, language: 'ja', speed: .5).maximum,
      );
      expect(
        assess(japanese, language: 'ja', speed: 100).maximum,
        assess(japanese, language: 'ja', speed: 2).maximum,
      );
    });

    test(
      'Japanese kanji expands conservatively, including kanji-only text',
      () {
        expect(
          assess('図書館', language: 'ja-JP').expected,
          greaterThan(assess('図書館', language: 'zh-CN').expected),
        );
        expect(assess('きゃ').spokenUnits, 1);
        expect(assess('きや').spokenUnits, 2);
        expect(assess('ｷｬ').spokenUnits, 1);
        expect(assess('こんにちは').languageCode, 'ja');
        expect(assess('图书馆').languageCode, 'zh');
      },
    );

    test(
      'Latin words use syllables while acronyms and mixed scripts survive',
      () {
        expect(assess('hello').spokenUnits, 2);
        expect(assess('TTS').spokenUnits, 3);
        final mixed = assess('今日はOpenAIでTTSを2026年も楽しもう。', language: 'ja');
        expect(mixed.spokenUnits, greaterThan(10));
        expect(mixed.maximum, greaterThan(Duration.zero));
      },
    );

    test(
      'unknown cue text and emotion repetitions do not inflate duration',
      () {
        final plain = assess(japanese, language: 'ja');
        expect(
          assess('[face:smile][action:wave]$japanese', language: 'ja').maximum,
          plain.maximum,
        );
        expect(
          assess(
            '${'[something that is not spoken]' * 100}$japanese',
            language: 'ja',
          ).maximum,
          plain.maximum,
        );
        expect(
          assess('${'[happy]' * 100}$japanese', language: 'ja').maximum,
          plain.maximum,
        );
      },
    );

    test('known pauses have bounded nonzero allowance', () {
      final plain = assess(japanese, language: 'ja');
      final pause = assess('[pause]$japanese', language: 'ja');
      final ten = assess('${'[long pause]' * 10}$japanese', language: 'ja');
      final thousand = assess(
        '${'[long pause]' * 1000}$japanese',
        language: 'ja',
      );
      expect(pause.pauseBudget, greaterThan(plain.pauseBudget));
      expect(pause.maximum, greaterThan(plain.maximum));
      expect(thousand.maximum, ten.maximum);
      expect(thousand.maximum, lessThan(const Duration(seconds: 71)));
    });

    test('breaths and emotional delivery never stack unbounded allowances', () {
      final once = assess('[whispering][sighing]$japanese', language: 'ja');
      final repeated = assess(
        '${'[whispering][sighing]' * 100}$japanese',
        language: 'ja',
      );
      expect(repeated.maximum, lessThan(const Duration(seconds: 71)));
      expect(repeated.maximum, lessThan(once.maximum * 2));
      expect(
        assess('[whispering]$japanese', language: 'ja').expected,
        greaterThan(assess(japanese, language: 'ja').expected),
      );
      expect(
        assess(japanese, language: 'ja', asmr: true).expected,
        greaterThan(assess(japanese, language: 'ja').expected),
      );
    });

    test('sentence and paragraph pauses scale with multi-part speech', () {
      final single = assess('ゆっくり星を見よう。', language: 'ja');
      final multiple = assess(
        'ゆっくり星を見よう。\n今日はありがとう。\nまた明日お話ししよう。',
        language: 'ja',
      );
      expect(multiple.expected, greaterThan(single.expected * 2));
      expect(multiple.pauseBudget, greaterThan(single.pauseBudget));
      expect(multiple.maximum, greaterThan(single.maximum));
    });

    test('punctuation runs and emoji cannot inflate the speech budget', () {
      expect(
        assess('はい${'…' * 100}。', language: 'ja').maximum,
        assess('はい…。', language: 'ja').maximum,
      );
      expect(
        assess('はい。🌸✨', language: 'ja').maximum,
        assess('はい。', language: 'ja').maximum,
      );
    });

    test('cue-only audio is not mistaken for spoken text', () {
      final value = assess(
        '[pause][unknown]',
        actual: const Duration(seconds: 19),
      );
      expect(value.hasSpeech, isFalse);
      expect(value.isOverlong, isTrue);
      expect(value.reason, 'no_spoken_content');
      expect(assess(' \n').maximum, Duration.zero);
    });

    test('diagnostics contain measures without the dialogue or cue bodies', () {
      final value = assess(
        '[happy]秘密の言葉です。',
        language: 'ja',
        actual: const Duration(seconds: 4),
      );
      expect(value.summary['language'], 'ja');
      expect(value.summary['actualMs'], 4000);
      expect(value.summary.toString(), isNot(contains('秘密')));
      expect(value.summary.toString(), isNot(contains('happy')));
      expect(ttsVisibleRuneCount('[happy][face:smile] 你好，世界。'), 6);
    });
  });
}
