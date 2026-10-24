import 'dart:convert';
import 'dart:io';

import 'package:alarm/alarm.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_alarm_coordinator.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AlarmAccess implements CharacterAlarmAccess {
  final alarms = <int, AlarmSettings>{};
  final stopped = <int>[];
  final restored = <int>[];
  @override
  Future<List<AlarmSettings>> getAlarms() async => alarms.values.toList();
  @override
  Future<bool> set(AlarmSettings alarm) async {
    restored.add(alarm.id);
    alarms[alarm.id] = alarm;
    return true;
  }

  @override
  Future<bool> stop(int id) async {
    stopped.add(id);
    alarms.remove(id);
    return true;
  }
}

AlarmSettings _alarm(int id, String? payload, {String? path}) => AlarmSettings(
  id: id,
  dateTime: DateTime.now().add(const Duration(hours: 2)),
  assetAudioPath: path ?? 'C:/reminders/$id.wav',
  payload: payload,
  volumeSettings: const VolumeSettings.fixed(volume: .8),
  notificationSettings: const NotificationSettings(
    title: 'Reminder',
    body: 'Time',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  const a = CharacterAppearance(
    id: 'alarm_model_a',
    label: 'Model A',
    description: '',
    promptDescription: '',
    assetName: 'alarm_model_a',
    animated: true,
    idleAnimations: [],
    live2dModelDirectory: 'test/a',
    live2dModelFileName: 'a.model3.json',
  );
  const b = CharacterAppearance(
    id: 'alarm_model_b',
    label: 'Model B',
    description: '',
    promptDescription: '',
    assetName: 'alarm_model_b',
    animated: true,
    idleAnimations: [],
    live2dModelDirectory: 'test/b',
    live2dModelFileName: 'b.model3.json',
  );
  late Directory directory;
  late ModelPackageStore packages;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('imported-model-alarms-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? directory.path
              : null,
        );
    packages = ModelPackageStore.forTesting();
    await packages.initialize(storageDirectory: directory);
    characterAppearances.addAll([a, b]);
    for (final model in [a, b]) {
      await packages.ensureModel(
        modelId: model.id,
        format: 'live2d',
        label: model.label,
        ownerCharacterId: model.characterId,
        files: {'model.json': Uint8List.fromList(utf8.encode('{}'))},
      );
    }
  });
  tearDown(() async {
    characterAppearances.removeWhere(
      (model) => [a.id, b.id].contains(model.id),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await packages.flush();
    await directory.delete(recursive: true);
  });

  test('empty framework pauses old bundled voices without restoring a legacy identity', () async {
    final controller = await AppController.load(modelPackages: packages);
    addTearDown(controller.dispose);
    final access = _AlarmAccess();
    access.alarms[1] = _alarm(
      1,
      null,
      path: 'assets/audio/alarm/voices/legacy.m4a',
    );
    access.alarms[2] = _alarm(2, CharacterAlarmCoordinator.ryzaVoicePayload);
    access.alarms[3] = _alarm(3, 'unrelated');
    await controller.initializeAlarmRuntime(access: access);
    expect(access.stopped, [1, 2]);
    expect(access.alarms.keys, [3]);
    await controller.setActiveCharacter('ryza');
    expect(controller.activeModelId, isNull);
    expect(access.restored, isEmpty);
  });

  test(
    'controller switches suspend and restore independent imported model alarms',
    () async {
      final controller = await AppController.load(modelPackages: packages);
      addTearDown(controller.dispose);
      await controller.setCharacterAppearance(a.id);
      final access = _AlarmAccess();
      access.alarms[1] = _alarm(
        1,
        CharacterAlarmCoordinator.payloadForModel(a.id),
      );
      await controller.initializeAlarmRuntime(access: access);
      await controller.setCharacterAppearance(b.id);
      expect(controller.activeModelId, b.id);
      expect(access.alarms, isEmpty);
      access.alarms[2] = _alarm(
        2,
        CharacterAlarmCoordinator.payloadForModel(b.id),
      );
      await controller.setCharacterAppearance(a.id);
      expect(access.alarms.keys, [1]);
      expect(access.restored, [1]);
      await controller.setCharacterAppearance(b.id);
      expect(access.alarms.keys, [2]);
      expect(access.restored, [1, 2]);
    },
  );

  test(
    'restart keeps a paused model isolated until the same model is selected',
    () async {
      final controller = await AppController.load(modelPackages: packages);
      await controller.setCharacterAppearance(a.id);
      final access = _AlarmAccess();
      access.alarms[1] = _alarm(
        1,
        CharacterAlarmCoordinator.payloadForModel(a.id),
      );
      await controller.initializeAlarmRuntime(access: access);
      await controller.setCharacterAppearance(b.id);
      await controller.flushModelSession();
      controller.dispose();
      final restarted = await AppController.load(modelPackages: packages);
      addTearDown(restarted.dispose);
      await restarted.initializeAlarmRuntime(access: access);
      expect(restarted.activeModelId, b.id);
      expect(access.alarms, isEmpty);
      await restarted.setCharacterAppearance(a.id);
      expect(access.alarms.keys, [1]);
    },
  );
}
