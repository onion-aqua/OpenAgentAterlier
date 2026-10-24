import 'dart:convert';

import 'package:alarm/alarm.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class CharacterAlarmAccess {
  Future<List<AlarmSettings>> getAlarms();
  Future<bool> set(AlarmSettings settings);
  Future<bool> stop(int id);
}

class PluginCharacterAlarmAccess implements CharacterAlarmAccess {
  const PluginCharacterAlarmAccess();

  @override
  Future<List<AlarmSettings>> getAlarms() => Alarm.getAlarms();

  @override
  Future<bool> set(AlarmSettings settings) =>
      Alarm.set(alarmSettings: settings);

  @override
  Future<bool> stop(int id) => Alarm.stop(id);
}

class CharacterAlarmCoordinator {
  CharacterAlarmCoordinator(
    this._preferences, {
    this.access = const PluginCharacterAlarmAccess(),
  });

  static const _pausedRyzaAlarmsKey = 'paused_ryza_voice_alarms_v1';
  static const _pausedModelAlarmsKey = 'paused_model_voice_alarms_v1';
  static const ryzaVoicePayload = 'character:ryza';
  static const _legacyRyzaVoicePath = 'assets/audio/alarm/voices/';
  static const _modelPayloadPrefix = 'character:model:';

  static String payloadForModel(String modelId) {
    if (modelId.trim().isEmpty) throw ArgumentError.value(modelId, 'modelId');
    return '$_modelPayloadPrefix$modelId';
  }

  static bool isAlarmForModel(AlarmSettings settings, String modelId) =>
      settings.payload == payloadForModel(modelId);

  final SharedPreferences _preferences;
  final CharacterAlarmAccess access;
  Future<void> _pending = Future<void>.value();

  Future<void> syncForCharacter(String characterId) {
    final next = _pending.then((_) => _syncModel(characterId));
    _pending = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  static bool isRyzaVoiceAlarm(AlarmSettings settings) =>
      settings.payload == ryzaVoicePayload ||
      (settings.assetAudioPath?.startsWith(_legacyRyzaVoicePath) ?? false);

  List<AlarmSettings> _readPausedAlarms([String key = _pausedModelAlarmsKey]) {
    final stored = _preferences.getString(key);
    if (stored == null || stored.isEmpty) return const [];
    final decoded = jsonDecode(stored);
    if (decoded is! List) {
      throw const FormatException('Paused voice alarm data is invalid');
    }
    return decoded
        .map(
          (entry) =>
              AlarmSettings.fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList(growable: false);
  }

  Future<void> _writePausedAlarms(List<AlarmSettings> alarms) async {
    final written = await _preferences.setString(
      _pausedModelAlarmsKey,
      jsonEncode(alarms.map((alarm) => alarm.toJson()).toList()),
    );
    if (!written) throw StateError('Could not save paused voice alarms');
  }

  Future<void> _syncModel(String scope) async {
    final activePayload =
        scope.startsWith('model:') &&
            scope.length > 'model:'.length &&
            scope != 'model:pending' &&
            scope != 'model:null'
        ? 'character:$scope'
        : null;
    final paused = <int, AlarmSettings>{
      for (final alarm in _readPausedAlarms(_pausedRyzaAlarmsKey))
        alarm.id: alarm,
      for (final alarm in _readPausedAlarms()) alarm.id: alarm,
    };
    final scheduled = await access.getAlarms();
    final alreadyScheduledIds = scheduled.map((alarm) => alarm.id).toSet();
    final toPause = scheduled
        .where(
          (alarm) =>
              isRyzaVoiceAlarm(alarm) ||
              ((alarm.payload?.startsWith(_modelPayloadPrefix) ?? false) &&
                  alarm.payload != activePayload),
        )
        .toList();
    for (final alarm in toPause) {
      paused[alarm.id] = alarm;
    }
    // Persist before native changes so a failed stop remains recoverable.
    await _writePausedAlarms(paused.values.toList());
    Object? failure;
    for (final alarm in toPause) {
      try {
        if (!await access.stop(alarm.id)) {
          failure ??= StateError('Could not pause model alarm ${alarm.id}');
        }
      } on Object catch (error) {
        failure ??= error;
      }
    }
    // Never restore another model while a previous model might still ring.
    if (failure != null) throw failure;
    final now = DateTime.now();
    final remaining = <AlarmSettings>[];
    for (final alarm in paused.values) {
      if (!alarm.dateTime.isAfter(now)) continue;
      if (alarm.payload != activePayload || activePayload == null) {
        remaining.add(alarm);
        continue;
      }
      // A failed pause may have left this native alarm alive. Reselecting its
      // model must clear the paused snapshot without restarting that playback.
      if (alreadyScheduledIds.contains(alarm.id)) continue;
      try {
        if (!await access.set(
          alarm.copyWith(allowSameSecondScheduling: true),
        )) {
          remaining.add(alarm);
          failure ??= StateError('Could not restore model alarm ${alarm.id}');
        }
      } on Object catch (error) {
        remaining.add(alarm);
        failure ??= error;
      }
    }
    await _writePausedAlarms(remaining);
    if (failure != null) throw failure;
  }
}
