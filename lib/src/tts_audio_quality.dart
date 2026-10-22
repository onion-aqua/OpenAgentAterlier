import 'audio_envelope.dart';
import 'speech_preparation.dart';

/// Conservative signal checks only: an amplitude envelope cannot establish
/// which words were spoken or distinguish all breaths from soft consonants.
void validateSpeechSignal(AudioAmplitudeEnvelope? envelope) {
  if (envelope == null || envelope.values.isEmpty) {
    throw const TtsAudioQualityException(
      'audio_decode_failed',
      '语音文件无法解码或没有可播放的内容',
    );
  }
  if (envelope.values.any((value) => !value.isFinite || value < 0)) {
    throw const TtsAudioQualityException('audio_decode_failed', '语音文件包含无效音频数据');
  }
  final raw = envelope.rawRms;
  if (raw.isEmpty) return;
  if (raw.any((value) => !value.isFinite || value < 0)) {
    throw const TtsAudioQualityException('audio_decode_failed', '语音文件包含无效音频数据');
  }
  // Below approximately -96 dBFS is digital silence, not a quiet whisper.
  if (raw.every((value) => value < .000015)) {
    throw const TtsAudioQualityException('audio_silent', '返回的语音几乎完全静音，已跳过播放');
  }
}
