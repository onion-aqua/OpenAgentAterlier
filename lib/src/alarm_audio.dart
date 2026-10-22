import 'app_localization.dart';

enum AlarmReminderType { goodMorning, playWithMe, task, wellDone }

extension AlarmReminderTypeDetails on AlarmReminderType {
  String label(AppLanguage language) => switch (this) {
    AlarmReminderType.goodMorning => language.text(
      '早安唤醒',
      'Morning wake-up',
      'おはよう',
    ),
    AlarmReminderType.playWithMe => language.text(
      '陪伴邀请',
      'Spend time together',
      '一緒に遊ぶ',
    ),
    AlarmReminderType.task => language.text('任务提醒', 'Task reminder', 'タスク通知'),
    AlarmReminderType.wellDone => language.text('完成鼓励', 'Well done', 'お疲れさま'),
  };

  String description(AppLanguage language) => switch (this) {
    AlarmReminderType.goodMorning => language.text(
      '使用角色语音叫你起床',
      'Wake up to the character voice',
      'キャラクターの声で目覚める',
    ),
    AlarmReminderType.playWithMe => language.text(
      '提醒你暂停忙碌，陪她一会儿',
      'A reminder to take a break together',
      'ひと休みして一緒に過ごす通知です',
    ),
    AlarmReminderType.task => language.text(
      '提醒你完成预定任务',
      'A reminder for a scheduled task',
      '予定したタスクの通知です',
    ),
    AlarmReminderType.wellDone => language.text(
      '完成任务后的鼓励与问候',
      'Encouragement after finishing something',
      'やり遂げたあとの労いです',
    ),
  };
}

String alarmAudioLocale(AppLanguage language) => switch (language) {
  AppLanguage.chinese => 'zh-tw',
  AppLanguage.english => 'en',
  AppLanguage.japanese => 'ja',
};

String alarmTimePeriod(int hour) {
  if (hour >= 5 && hour < 11) return 'morning';
  if (hour >= 11 && hour < 17) return 'daytime';
  if (hour >= 17 && hour < 22) return 'evening';
  return 'night';
}

String alarmVoiceAsset({
  required AppLanguage language,
  required AlarmReminderType type,
  required bool asmr,
  required int hour,
  required int variantSeed,
}) {
  final locale = alarmAudioLocale(language);
  final style = asmr ? 'whisper' : 'normal';
  final clipCount = locale == 'ja' ? 10 : 5;
  final clip = variantSeed.abs() % clipCount + 1;
  return 'assets/audio/alarm/voices/'
      '${locale}_${style}_${type.name}_${alarmTimePeriod(hour)}_$clip.m4a';
}

AlarmReminderType alarmReminderTypeFromAsset(String assetPath) {
  for (final type in AlarmReminderType.values) {
    if (assetPath.contains('_${type.name}_') ||
        assetPath.contains('/${type.name}/')) {
      return type;
    }
  }
  return AlarmReminderType.goodMorning;
}

bool alarmAssetUsesWhisper(String assetPath) =>
    assetPath.contains('_whisper_') || assetPath.contains('/whisper/');
