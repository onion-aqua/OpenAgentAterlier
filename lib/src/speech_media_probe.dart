import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'speech_preparation.dart';

/// Reads the duration through the installed media decoder without playing any
/// audio. This does not provide PCM samples or establish signal quality.
Future<Duration> probeSpeechDuration(
  String path, {
  AudioPlayer Function()? createPlayer,
}) async {
  AudioPlayer? player;
  StreamSubscription<Duration>? subscription;
  try {
    player = (createPlayer ?? AudioPlayer.new)();
    player.positionUpdater = null;
    final observed = Completer<Duration>();
    // Decoder errors can arrive while setSource is still waiting for prepared.
    // Observe errors immediately; awaiting this future later still reports them.
    observed.future.ignore();
    subscription = player.onDurationChanged.listen(
      (duration) {
        if (duration > Duration.zero && !observed.isCompleted) {
          observed.complete(duration);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!observed.isCompleted) observed.completeError(error, stack);
      },
    );
    final probe = player;
    Future<Duration> read() async {
      await probe.setVolume(0);
      // setSource prepares the decoder. It does not call play/resume or acquire
      // the application's Android focus owner via AppAudioPlayer.
      await probe.setSource(DeviceFileSource(path));
      final duration = await probe.getDuration();
      if (duration != null && duration > Duration.zero) return duration;
      // Some decoders publish duration just after the prepared event, rather
      // than on the first synchronous duration query.
      return observed.future.timeout(const Duration(milliseconds: 600));
    }

    return await read().timeout(const Duration(seconds: 12));
  } on Object {
    throw const TtsAudioQualityException(
      'audio_decode_failed',
      '无法读取语音文件的有效时长，已停止播放该片段',
    );
  } finally {
    try {
      await subscription?.cancel().timeout(const Duration(seconds: 3));
    } on Object {
      // Still release the independent player if stream cancellation fails.
    }
    if (player != null) {
      try {
        await player.dispose().timeout(const Duration(seconds: 3));
      } on Object {
        // Preserve the decoder error if cleanup also fails or times out.
      }
    }
  }
}
