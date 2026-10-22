import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alarm_audio.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';

void main() {
  test('alarm periods follow the scheduled hour', () {
    expect(alarmTimePeriod(6), 'morning');
    expect(alarmTimePeriod(12), 'daytime');
    expect(alarmTimePeriod(18), 'evening');
    expect(alarmTimePeriod(23), 'night');
  });

  test('alarm voice follows language, type, and ASMR mode', () {
    expect(
      alarmVoiceAsset(
        language: AppLanguage.chinese,
        type: AlarmReminderType.task,
        asmr: false,
        hour: 13,
        variantSeed: 7,
      ),
      'assets/audio/alarm/voices/zh-tw_normal_task_daytime_3.m4a',
    );
    expect(
      alarmVoiceAsset(
        language: AppLanguage.japanese,
        type: AlarmReminderType.playWithMe,
        asmr: true,
        hour: 22,
        variantSeed: 9,
      ),
      'assets/audio/alarm/voices/ja_whisper_playWithMe_night_10.m4a',
    );
  });

  test('alarm type and voice style can be recovered from an alarm asset', () {
    const path = 'assets/audio/alarm/voices/en_whisper_wellDone_evening_2.m4a';
    expect(alarmReminderTypeFromAsset(path), AlarmReminderType.wellDone);
    expect(alarmAssetUsesWhisper(path), isTrue);
  });
}
