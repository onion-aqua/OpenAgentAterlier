import 'dart:async';

import 'fish_mcp_protocol.dart';
import 'tts_duration_guard.dart';

/// Observe a prefetch error immediately, even while an earlier clip is playing.
/// Only unwrap when its turn arrives so the owning flow can cancel or skip it.
class SpeechPreparation<T> {
  SpeechPreparation._(this._value, this.error, this._stack);
  final T? _value;
  final Object? error;
  final StackTrace? _stack;

  static Future<SpeechPreparation<T>> capture<T>(
    Future<T> Function() prepare,
  ) async {
    try {
      return SpeechPreparation<T>._(await prepare(), null, null);
    } catch (error, stack) {
      return SpeechPreparation<T>._(null, error, stack);
    }
  }

  T unwrap() {
    if (error case final Object failure) {
      Error.throwWithStackTrace(failure, _stack!);
    }
    return _value as T;
  }

  Future<void> discard(FutureOr<void> Function(T) dispose) async {
    if (error == null) await dispose(unwrap());
  }
}

/// A known invalid returned clip may be skipped. An uncertain generation,
/// billing/permission/transport error must stop rather than incur new requests.
bool isRejectedSpeechAudio(Object error) =>
    error is TtsAudioTooLongException ||
    (error is TtsAudioQualityException &&
        const {'audio_decode_failed', 'audio_silent'}.contains(error.code)) ||
    (error is FishMcpException &&
        error.stage == 'audio_validation' &&
        (error.status == null || error.status! < 400) &&
        !error.outcomeUnknown &&
        const {
          'audio_too_long',
          'audio_decode_failed',
          'audio_silent',
        }.contains(error.code));

/// Permit one bad returned clip, then stop on a consecutive failure. A valid
/// clip resets the streak; billing and uncertain results never advance it.
class SpeechRejectionBudget {
  int consecutive = 0;
  int total = 0;

  bool shouldSkip(Object error) {
    if (!isRejectedSpeechAudio(error)) return false;
    total++;
    consecutive++;
    return consecutive < 2;
  }

  void accepted() => consecutive = 0;
}

class TtsAudioQualityException implements Exception {
  const TtsAudioQualityException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
