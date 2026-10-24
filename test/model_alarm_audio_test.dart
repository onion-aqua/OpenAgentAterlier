import 'dart:io';

import 'package:alarm/alarm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alarm_audio.dart';
import 'package:ryza_chat_mvp/src/character_alarm_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ModelAlarmAccess implements CharacterAlarmAccess {
  final scheduled = <int, AlarmSettings>{};
  final stopped = <int>[];
  final restored = <int>[];
  final stopFailures = <int>{};
  final restoreFailures = <int>{};

  @override
  Future<List<AlarmSettings>> getAlarms() async => scheduled.values.toList();
  @override
  Future<bool> set(AlarmSettings settings) async {
    if (restoreFailures.contains(settings.id)) return false;
    restored.add(settings.id);
    scheduled[settings.id] = settings;
    return true;
  }

  @override
  Future<bool> stop(int id) async {
    stopped.add(id);
    if (stopFailures.contains(id)) return false;
    scheduled.remove(id);
    return true;
  }
}

AlarmSettings _alarm(int id, String payload, {bool expired = false}) =>
    AlarmSettings(
      id: id,
      dateTime: DateTime.now().add(Duration(hours: expired ? -1 : 1)),
      assetAudioPath: 'C:/local-reminders/$id.wav',
      payload: payload,
      volumeSettings: const VolumeSettings.fixed(volume: .8),
      notificationSettings: const NotificationSettings(
        title: 'Reminder',
        body: 'Time',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    directory = await Directory.systemTemp.createTemp('model-reminder-test-');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'audio is copied into model storage and remains independent of its source',
    () async {
      final source = File('${directory.path}/source.wav');
      await source.writeAsBytes([1, 2, 3, 4]);
      final store = ModelAlarmAudioStore(
        directory: directory,
        preferences: preferences,
      );
      final path = await store.importFile('../model A', source);
      expect(
        path.startsWith('${directory.path}/model_alarm_audio_v1/'),
        isTrue,
      );
      await source.delete();
      expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
      expect(await store.audioPath('../model A'), path);
      expect(await store.audioPath('model B'), isNull);
      final replacement = await store.importBytes('../model A', [
        4,
        3,
        2,
        1,
      ], 'WAV');
      expect(replacement, isNot(path));
      expect(
        await File(path).exists(),
        isTrue,
      ); // Scheduled alarms keep their old audio.
      expect(await store.audioPath('../model A'), replacement);
    },
  );

  test('missing, oversized, unsupported and empty audio never becomes a model setting', () async {
    final store = ModelAlarmAudioStore(
      directory: directory,
      preferences: preferences,
    );
    await expectLater(
      store.importBytes('model A', [], 'wav'),
      throwsFormatException,
    );
    await expectLater(
      store.importBytes('model A', [1], 'exe'),
      throwsFormatException,
    );
    final large = await File('${directory.path}/large.wav')
        .open(mode: FileMode.write);
    await large.truncate(ModelAlarmAudioStore.maxBytes + 1);
    await large.close();
    await expectLater(
      store.importFile('model A', File('${directory.path}/large.wav')),
      throwsFormatException,
    );
    expect(await store.audioPath('model A'), isNull);
  });

  test('switches pause one model and restore only the newly active model after restart', () async {
    final access = _ModelAlarmAccess();
    access.scheduled[1] = _alarm(
      1,
      CharacterAlarmCoordinator.payloadForModel('A'),
    );
    access.scheduled[2] = _alarm(
      2,
      CharacterAlarmCoordinator.payloadForModel('B'),
    );
    access.scheduled[3] = _alarm(3, 'unrelated');
    await CharacterAlarmCoordinator(
      preferences,
      access: access,
    ).syncForCharacter('model:A');
    expect(access.stopped, [2]);
    expect(access.scheduled.keys, containsAll([1, 3]));
    final restarted = CharacterAlarmCoordinator(preferences, access: access);
    await restarted.syncForCharacter('model:B');
    expect(access.scheduled.keys, containsAll([2, 3]));
    expect(access.scheduled.containsKey(1), isFalse);
    expect(access.restored, [2]);
    await restarted.syncForCharacter('model:B');
    expect(access.restored, [2]);
  });

  test('legacy identity aliases and missing models never restore legacy or other model voices', () async {
    final access = _ModelAlarmAccess();
    access.scheduled[1] = _alarm(1, CharacterAlarmCoordinator.ryzaVoicePayload);
    access.scheduled[2] = _alarm(
      2,
      CharacterAlarmCoordinator.payloadForModel('A'),
    );
    final coordinator = CharacterAlarmCoordinator(preferences, access: access);
    await coordinator.syncForCharacter('model:null');
    await coordinator.syncForCharacter('ryza');
    await coordinator.syncForCharacter('model:pending');
    expect(access.scheduled, isEmpty);
    expect(access.restored, isEmpty);
  });

  test('failed native stop preserves snapshot for retry and blocks another model restore', () async {
    final access = _ModelAlarmAccess();
    access.scheduled[1] = _alarm(
      1,
      CharacterAlarmCoordinator.payloadForModel('A'),
    );
    access.scheduled[2] = _alarm(
      2,
      CharacterAlarmCoordinator.payloadForModel('B'),
    );
    final coordinator = CharacterAlarmCoordinator(preferences, access: access);
    await coordinator.syncForCharacter('model:A');
    access.stopFailures.add(1);
    await expectLater(
      coordinator.syncForCharacter('model:B'),
      throwsStateError,
    );
    expect(access.scheduled.keys, [1]);
    expect(access.restored, isEmpty);
    await coordinator.syncForCharacter('model:A');
    expect(access.restored, isEmpty);
    access.stopFailures.clear();
    await coordinator.syncForCharacter('model:B');
    expect(access.scheduled.keys, [2]);
  });

  test(
    'expired paused alarms are dropped and failed restores can retry',
    () async {
      final access = _ModelAlarmAccess();
      access.scheduled[1] = _alarm(
        1,
        CharacterAlarmCoordinator.payloadForModel('A'),
        expired: true,
      );
      access.scheduled[2] = _alarm(
        2,
        CharacterAlarmCoordinator.payloadForModel('A'),
      );
      final coordinator = CharacterAlarmCoordinator(
        preferences,
        access: access,
      );
      await coordinator.syncForCharacter('model:B');
      access.restoreFailures.add(2);
      await expectLater(
        coordinator.syncForCharacter('model:A'),
        throwsStateError,
      );
      expect(access.restored, isEmpty);
      access.restoreFailures.clear();
      await coordinator.syncForCharacter('model:A');
      expect(access.restored, [2]);
    },
  );
}
