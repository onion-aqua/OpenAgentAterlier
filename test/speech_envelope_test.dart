import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/audio_envelope.dart';

void main() {
  test('constant voiced PCM stays voiced instead of inventing closures', () {
    final envelope = AudioAmplitudeEnvelope.fromRms(List.filled(50, 0.3));
    expect(envelope.values.skip(3).every((v) => v > 0.9), isTrue);
  });
  test('real pauses close the mouth within 60ms and recover promptly', () {
    final envelope = AudioAmplitudeEnvelope.fromRms([
      ...List.filled(10, 0.0),
      ...List.filled(10, 0.3),
      ...List.filled(5, 0.0),
      ...List.filled(10, 0.3),
    ]);
    expect(envelope.values[22], 0);
    expect(envelope.values[25], greaterThan(0.8));
    expect(envelope.values.take(10).every((v) => v == 0), isTrue);
  });
}
