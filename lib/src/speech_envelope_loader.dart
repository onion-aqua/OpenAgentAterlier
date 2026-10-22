import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_envelope.dart';
import 'runtime_log.dart';

Future<AudioAmplitudeEnvelope?> loadSpeechEnvelope(
  String path,
  Uint8List bytes,
) async {
  final wav = await compute(_parseWavEnvelope, bytes);
  if (wav != null) return wav;
  if (!Platform.isAndroid) return null;
  try {
    final result = await const MethodChannel('agent_atelier_r/speech_envelope')
        .invokeMethod<Object?>('analyze', {'path': path});
    return parseNativeSpeechEnvelope(result);
  } on Object catch (error, stack) {
    RuntimeLog.instance.error('LipSync', error, stack);
    return null;
  }
}

AudioAmplitudeEnvelope? _parseWavEnvelope(Uint8List bytes) =>
    AudioAmplitudeEnvelope.tryParseWav(bytes);

/// New native responses carry PCM duration; old builds returned only RMS values.
@visibleForTesting
AudioAmplitudeEnvelope? parseNativeSpeechEnvelope(Object? result) {
  final raw = result is Map ? result['values'] : result;
  if (raw is! List || raw.isEmpty || raw.any((value) => value is! num)) {
    return null;
  }
  Duration? duration;
  if (result is Map) {
    final micros = result['durationUs'];
    if (micros is! int || micros <= 0 || micros > 600000000) return null;
    duration = Duration(microseconds: micros);
  }
  return AudioAmplitudeEnvelope.fromRms(
    raw.cast<num>().map((value) => value.toDouble()).toList(),
    duration: duration,
  );
}
