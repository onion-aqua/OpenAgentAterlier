import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/audio_envelope.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_protocol.dart';
import 'package:ryza_chat_mvp/src/speech_preparation.dart';
import 'package:ryza_chat_mvp/src/tts_audio_quality.dart';
import 'package:ryza_chat_mvp/src/tts_duration_guard.dart';

FishMcpException _invalidClip(
  String code, {
  bool unknown = false,
  int? status,
}) => FishMcpException(
  stage: 'audio_validation',
  code: code,
  message: 'A returned clip failed local validation',
  status: status,
  outcomeUnknown: unknown,
  generationSubmitted: true,
);

const _overlong = TtsAudioTooLongException(
  actual: Duration(seconds: 71),
  maximum: Duration(seconds: 25),
);
const _silent = TtsAudioQualityException('audio_silent', 'Silence');

AudioAmplitudeEnvelope _envelope({
  List<double> values = const [.2, .3],
  List<double> rawRms = const [],
}) => AudioAmplitudeEnvelope(
  frameDuration: const Duration(milliseconds: 20),
  values: values,
  rawRms: rawRms,
);

Matcher _qualityCode(String code) => throwsA(
  isA<TtsAudioQualityException>().having((error) => error.code, 'code', code),
);

void main() {
  group('prefetched speech results', () {
    test(
      'observes a later clip error before its playback turn is awaited',
      () async {
        final unhandled = <Object>[];
        final failure = StateError('later clip failed');
        final originalStack = StackTrace.fromString('prefetch-origin:17');
        late Completer<String> source;
        late Future<SpeechPreparation<String>> pending;

        runZonedGuarded(() {
          source = Completer<String>();
          pending = SpeechPreparation.capture(() => source.future);
          source.completeError(failure, originalStack);
        }, (error, _) => unhandled.add(error));

        // Simulate the current clip still playing: no one awaits pending yet.
        // An unobserved source error would reach its zone during these turns.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(unhandled, isEmpty);

        final prepared = await pending;
        expect(prepared.error, same(failure));
        expect(() => prepared.unwrap(), throwsA(same(failure)));
        expect(unhandled, isEmpty);
      },
    );

    test(
      'unwrap preserves the original asynchronous error and stack',
      () async {
        final failure = ArgumentError('original failure');
        final originalStack = StackTrace.fromString(
          'actual-synthesis-origin:42',
        );
        final prepared = await SpeechPreparation.capture<String>(
          () => Future<String>.error(failure, originalStack),
        );

        Object? observed;
        StackTrace? observedStack;
        try {
          prepared.unwrap();
        } catch (error, stack) {
          observed = error;
          observedStack = stack;
        }
        expect(observed, same(failure));
        expect(observedStack.toString(), originalStack.toString());
        expect(observedStack.toString(), isNot(contains('unwrap')));
      },
    );

    test(
      'synchronous preparation throws are captured without replacement',
      () async {
        final failure = FormatException('invalid returned audio');
        final originalStack = StackTrace.fromString('decode-origin:9');
        final prepared = await SpeechPreparation.capture<String>(() {
          Error.throwWithStackTrace(failure, originalStack);
        });
        expect(prepared.error, same(failure));
        try {
          prepared.unwrap();
          fail('The failed preparation must throw when consumed');
        } on FormatException catch (error, stack) {
          expect(error, same(failure));
          expect(stack.toString(), originalStack.toString());
        }
      },
    );

    test(
      'successful and nullable preparation values unwrap normally',
      () async {
        final prepared = await SpeechPreparation.capture(
          () async => 'clip-path',
        );
        expect(prepared.error, isNull);
        expect(prepared.unwrap(), 'clip-path');
        final nullable = await SpeechPreparation.capture<String?>(
          () async => null,
        );
        expect(nullable.error, isNull);
        expect(nullable.unwrap(), isNull);
      },
    );
  });

  group('discarded prefetches', () {
    test('releases an unused successful prefetched clip', () async {
      final disposed = <String>[];
      final prepared = await SpeechPreparation.capture(
        () async => 'prefetched.wav',
      );
      await prepared.discard((path) async {
        await Future<void>.delayed(Duration.zero);
        disposed.add(path);
      });
      expect(disposed, ['prefetched.wav']);
    });

    test('failed prefetch does not throw or call its disposer', () async {
      final prepared = await SpeechPreparation.capture<String>(
        () => Future<String>.error(_overlong),
      );
      var disposed = false;
      await prepared.discard((_) {
        disposed = true;
      });
      expect(disposed, isFalse);
      expect(prepared.error, same(_overlong));
    });
  });

  group('returned audio rejection classification', () {
    test('recognizes known local duration, decode and silence failures', () {
      expect(isRejectedSpeechAudio(_overlong), isTrue);
      expect(isRejectedSpeechAudio(_silent), isTrue);
      expect(
        isRejectedSpeechAudio(
          const TtsAudioQualityException('audio_decode_failed', 'Invalid PCM'),
        ),
        isTrue,
      );
      for (final code in [
        'audio_too_long',
        'audio_decode_failed',
        'audio_silent',
      ]) {
        expect(isRejectedSpeechAudio(_invalidClip(code)), isTrue, reason: code);
      }
    });

    test(
      'does not turn billing or authorization errors into skippable clips',
      () {
        for (final status in [401, 402, 403, 429, 500]) {
          final failure = FishMcpException(
            stage: 'studio_generate',
            code: status == 402 ? 'insufficient_credits' : 'service_error',
            status: status,
            message: 'Request rejected',
            generationSubmitted: true,
          );
          expect(
            isRejectedSpeechAudio(failure),
            isFalse,
            reason: 'HTTP $status',
          );
        }
        expect(
          isRejectedSpeechAudio(_invalidClip('audio_silent', status: 402)),
          isFalse,
        );
      },
    );

    test(
      'transport, timeout and uncertain outcomes stop the generation flow',
      () {
        final errors = <Object>[
          const SocketException('network interrupted'),
          TimeoutException('transport timeout'),
          FishMcpException(
            stage: 'transport',
            code: 'audio_decode_failed',
            message: 'No reliable completion result',
            outcomeUnknown: true,
            generationSubmitted: true,
          ),
          _invalidClip('audio_too_long', unknown: true),
          _invalidClip('audio_decode_failed', unknown: true),
          _invalidClip('audio_silent', unknown: true),
        ];
        for (final error in errors) {
          expect(isRejectedSpeechAudio(error), isFalse, reason: '$error');
        }
      },
    );

    test(
      'unknown codes and text that merely mentions validation do not skip',
      () {
        final errors = <Object>[
          const TtsAudioQualityException(
            'unrecognized_quality_error',
            'Unknown',
          ),
          _invalidClip('unknown_validation_failure'),
          Exception('audio_too_long'),
          StateError('audio_silent'),
          FishMcpException(
            stage: 'cancelled',
            code: 'request_cancelled',
            message: 'Playback cancelled',
          ),
        ];
        for (final error in errors) {
          expect(isRejectedSpeechAudio(error), isFalse, reason: '$error');
        }
      },
    );
  });

  group('bounded rejected-clip recovery', () {
    test(
      'a successful middle clip resets the consecutive rejection budget',
      () {
        final budget = SpeechRejectionBudget();
        expect(budget.shouldSkip(_overlong), isTrue);
        budget.accepted();
        expect(budget.shouldSkip(_silent), isTrue);
        budget.accepted();
        expect(budget.shouldSkip(_invalidClip('audio_decode_failed')), isTrue);
      },
    );

    test('two consecutive invalid returned clips stop instead of looping', () {
      final budget = SpeechRejectionBudget();
      expect(budget.shouldSkip(_overlong), isTrue);
      expect(budget.shouldSkip(_silent), isFalse);
      expect(budget.shouldSkip(_invalidClip('audio_decode_failed')), isFalse);
    });

    test('unknown or possibly billable errors are never skipped', () {
      final errors = <Object>[
        TimeoutException('request outcome unknown'),
        _invalidClip('audio_silent', unknown: true),
        FishMcpException(
          stage: 'studio_generate',
          status: 402,
          code: 'insufficient_credits',
          message: 'Insufficient credits',
          generationSubmitted: true,
        ),
      ];
      for (final error in errors) {
        expect(SpeechRejectionBudget().shouldSkip(error), isFalse);
      }
    });
  });

  group('conservative signal quality', () {
    test('digital silence is rejected without calling it a quiet whisper', () {
      expect(
        () => validateSpeechSignal(_envelope(rawRms: const [0, 0, 0])),
        _qualityCode('audio_silent'),
      );
      expect(
        () => validateSpeechSignal(_envelope(rawRms: const [.000001, .000004])),
        _qualityCode('audio_silent'),
      );
    });

    test(
      'real low-volume whispers and sparse quiet speech remain playable',
      () {
        expect(
          () => validateSpeechSignal(_envelope(rawRms: const [.00003, .00005])),
          returnsNormally,
        );
        expect(
          () =>
              validateSpeechSignal(_envelope(rawRms: const [0, 0, .00003, 0])),
          returnsNormally,
        );
      },
    );

    test('unknown raw RMS does not invent evidence of silent audio', () {
      expect(
        () => validateSpeechSignal(
          _envelope(values: const [0, 0], rawRms: const []),
        ),
        returnsNormally,
      );
    });

    test('missing and empty decoded envelopes are rejected', () {
      expect(
        () => validateSpeechSignal(null),
        _qualityCode('audio_decode_failed'),
      );
      expect(
        () => validateSpeechSignal(_envelope(values: const [])),
        _qualityCode('audio_decode_failed'),
      );
    });

    test('nonfinite or negative raw samples are invalid, not silent', () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
        -.1,
      ]) {
        expect(
          () => validateSpeechSignal(_envelope(rawRms: [value, .2])),
          _qualityCode('audio_decode_failed'),
        );
      }
    });

    test(
      'nonfinite envelope samples are invalid even if raw RMS is unknown',
      () {
        for (final value in [
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]) {
          expect(
            () => validateSpeechSignal(
              _envelope(values: [value], rawRms: const []),
            ),
            _qualityCode('audio_decode_failed'),
          );
        }
      },
    );
  });
}
