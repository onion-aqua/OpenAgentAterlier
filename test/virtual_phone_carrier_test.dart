import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_carrier.dart';
import 'package:ryza_chat_mvp/src/world_travel_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDirectory;
  late ModelPackageStore packages;
  const models = [
    CharacterAppearance(
      id: 'carrier_model_a',
      label: '星见',
      description: '',
      promptDescription: '',
      assetName: 'carrier_model_a',
      animated: true,
      idleAnimations: [],
      live2dModelDirectory: 'test/a',
      live2dModelFileName: 'a.model3.json',
    ),
    CharacterAppearance(
      id: 'carrier_model_b',
      label: 'Agent B',
      description: '',
      promptDescription: '',
      assetName: 'carrier_model_b',
      animated: true,
      idleAnimations: [],
      characterId: CharacterRuntimeIds.sophie,
      live2dModelDirectory: 'test/b',
      live2dModelFileName: 'b.model3.json',
    ),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    supportDirectory = await Directory.systemTemp.createTemp('aar_carrier_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return call.method == 'getApplicationSupportDirectory'
              ? supportDirectory.path
              : null;
        });
    packages = ModelPackageStore.forTesting();
    await packages.initialize(storageDirectory: supportDirectory);
    characterAppearances.addAll(models);
    for (final model in models) {
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
    characterAppearances.removeWhere((item) => models.contains(item));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await packages.flush();
    await supportDirectory.delete(recursive: true);
  });

  Future<AppController> loadModel({String? modelId}) async {
    final controller = await AppController.load(modelPackages: packages);
    if (modelId != null) await controller.setCharacterAppearance(modelId);
    addTearDown(() async {
      await controller.flushModelSession();
      controller.dispose();
    });
    return controller;
  }

  test('region mapping follows exact world catalog areas and Sophie', () async {
    final catalog = await WorldTravelCatalog.load();
    const expected = {
      'area_01': '库肯岛',
      'area_02': '克莱利亚',
      'area_03': '内米德',
      'area_04': '异界',
      'area_05': '王都',
    };
    for (final area in expected.entries) {
      final stage = catalog.destinations.firstWhere(
        (item) => item.areaId == area.key,
      );
      expect(
        VirtualPhoneCarrier.regionForLocation(
          catalog: catalog,
          characterId: CharacterRuntimeIds.ryza,
          areaId: 'wrong_area',
          stageId: stage.stageId,
        ),
        area.value,
      );
    }
    expect(
      VirtualPhoneCarrier.regionForLocation(
        catalog: catalog,
        characterId: CharacterRuntimeIds.ryza,
        areaId: 'area_03',
        stageId: 'stage_02_fake',
      ),
      '内米德',
    );
    expect(
      VirtualPhoneCarrier.regionForLocation(
        catalog: catalog,
        characterId: CharacterRuntimeIds.sophie,
        areaId: 'sophie_erde_wiege',
        stageId: 'sophie_roytale',
      ),
      '异界',
    );
    expect(
      VirtualPhoneCarrier.regionForLocation(
        catalog: catalog,
        characterId: CharacterRuntimeIds.ryza,
        areaId: 'unknown',
        stageId: 'stage_01_fake',
      ),
      '异界',
    );
  });

  test(
    'new carriers choose a valid suffix without requiring different draws',
    () {
      final random = Random(18);
      final choices = List.generate(
        30,
        (_) => VirtualPhoneCarrier.create(region: '库肯岛', random: random),
      );
      expect(
        choices.map((carrier) => carrier.suffix),
        everyElement(isIn(VirtualPhoneCarrier.suffixes)),
      );
      expect(choices.map((carrier) => carrier.suffix).toSet().length, 3);
      final original = choices.first;
      final restored = VirtualPhoneCarrier.fromJson(original.toJson());
      expect(restored.name, original.name);
      expect(
        () => VirtualPhoneCarrier.fromJson({
          'region': '库肯岛',
          'suffix': 'invalid',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'model location changes display region while its saved suffix stays fixed',
    () async {
      final controller = await loadModel(modelId: models.first.id);
      final suffix = controller.virtualPhoneCarrier.suffix;
      expect(controller.virtualPhoneCarrierName, '虚拟$suffix');
      expect(
        VirtualPhoneCarrier.suffixes,
        contains(controller.virtualPhoneCarrier.suffix),
      );
      controller.selectLocation(
        areaId: 'custom_sky',
        stageId: 'custom_observatory',
        areaName: '星空站',
        stageName: '观测室',
      );
      expect(controller.virtualPhoneCarrierName, '星空站$suffix');
      expect(controller.messages.last.text, isNot(contains('莱莎')));
      expect(controller.gatheringSceneReady, isFalse);
      expect(controller.virtualPhoneCarrier.suffix, suffix);
      await controller.saveToLocalSlot(0);
      final restarted = await loadModel();
      expect(restarted.virtualPhoneCarrierName, '星空站$suffix');
      expect(restarted.virtualPhoneCarrier.suffix, suffix);
      expect(
        (controller.exportLocalSlot(0)['snapshot']
            as Map)['virtualPhoneCarrier'],
        controller.virtualPhoneCarrier.toJson(),
      );
    },
  );

  test(
    'new saves reset location and store an independent fixed carrier',
    () async {
      final controller = await loadModel(modelId: models.first.id);
      final existing = controller.exportData()
        ..['selectedAreaId'] = 'custom_sky'
        ..['selectedStageId'] = 'custom_observatory'
        ..['selectedAreaName'] = '星空站'
        ..['selectedStageName'] = '观测室'
        ..['virtualPhoneCarrier'] = {'region': '异界', 'suffix': '电信'};
      await controller.importData(existing);
      await controller.saveToLocalSlot(0);
      await controller.createLocalSlot(1);
      expect(controller.selectedAreaId, isEmpty);
      expect(controller.selectedAreaName, '未设置');
      final freshSuffix = controller.virtualPhoneCarrier.suffix;
      expect(VirtualPhoneCarrier.suffixes, contains(freshSuffix));
      expect(controller.virtualPhoneCarrierName, '虚拟$freshSuffix');
      controller.selectLocation(
        areaId: 'custom_port',
        stageId: 'custom_coast',
        areaName: '星港',
        stageName: '海岸',
      );
      await controller.saveToLocalSlot(1);
      await controller.loadFromLocalSlot(0);
      expect(controller.virtualPhoneCarrierName, '星空站电信');
      await controller.loadFromLocalSlot(1);
      expect(controller.virtualPhoneCarrierName, '星港$freshSuffix');
      expect(controller.virtualPhoneCarrier.suffix, freshSuffix);
      await controller.createLocalSlot(2);
      expect(controller.virtualPhoneCarrierName, startsWith('虚拟'));
      await controller.loadFromLocalSlot(0);
      expect(controller.virtualPhoneCarrierName, '星空站电信');
      await controller.loadFromLocalSlot(1);
      expect(controller.virtualPhoneCarrierName, '星港$freshSuffix');
    },
  );

  test('backup and slot import keep carrier data without affecting the active slot', () async {
    final controller = await loadModel(modelId: models.first.id);
    final original = controller.exportData()
      ..['selectedAreaId'] = 'custom_port'
      ..['selectedStageId'] = 'custom_coast'
      ..['selectedAreaName'] = '星港'
      ..['selectedStageName'] = '海岸'
      ..['virtualPhoneCarrier'] = {'region': '异界', 'suffix': '联通'};
    await controller.importData(original);
    await controller.saveToLocalSlot(0);
    final slot = controller.exportLocalSlot(
      0,
      includeConversationHistory: false,
    );
    await controller.createLocalSlot(1);
    final current = controller.virtualPhoneCarrierName;
    await controller.importLocalSlot(2, slot);
    expect(controller.virtualPhoneCarrierName, current);
    await controller.loadFromLocalSlot(2);
    expect(controller.virtualPhoneCarrierName, '星港联通');
    await controller.importData(original);
    expect(controller.virtualPhoneCarrierName, '星港联通');
    expect(
      controller.exportData()['virtualPhoneCarrier'],
      original['virtualPhoneCarrier'],
    );
  });

  test(
    'legacy slot migration is stable across load, restart, export and import',
    () async {
      final controller = await loadModel();
      controller.selectLocation(areaId: 'area_02', stageId: 'stage_02_001_01');
      await controller.saveToLocalSlot(0);
      final preferences = await SharedPreferences.getInstance();
      final legacy = controller.exportLocalSlot(0);
      (legacy['snapshot'] as Map).remove('virtualPhoneCarrier');
      await preferences.setString('local_save_slot_0', jsonEncode(legacy));
      final exportedBeforeLoad = controller.exportLocalSlot(0);
      final migrated =
          (exportedBeforeLoad['snapshot'] as Map)['virtualPhoneCarrier'];
      expect((migrated as Map)['region'], '克莱利亚');
      await controller.loadFromLocalSlot(0);
      final name = controller.virtualPhoneCarrierName;
      expect(controller.virtualPhoneCarrier.toJson(), migrated);
      expect(
        (jsonDecode(preferences.getString('local_save_slot_0')!)['snapshot']
            as Map)['virtualPhoneCarrier'],
        migrated,
      );
      await controller.importLocalSlot(1, legacy);
      await controller.loadFromLocalSlot(1);
      expect(controller.virtualPhoneCarrierName, name);
      final restarted = await loadModel();
      expect(restarted.virtualPhoneCarrierName, name);
      await restarted.loadFromLocalSlot(0);
      expect(restarted.virtualPhoneCarrierName, name);
    },
  );

  test(
    'different imported model sessions preserve separate regions and carriers',
    () async {
      final controller = await loadModel(modelId: models.first.id);
      final first = controller.exportData()
        ..['selectedAreaId'] = 'custom_sky'
        ..['selectedStageId'] = 'custom_observatory'
        ..['selectedAreaName'] = '星空站'
        ..['selectedStageName'] = '观测室'
        ..['virtualPhoneCarrier'] = {'region': '异界', 'suffix': '移动'};
      await controller.importData(first);
      await controller.saveToLocalSlot(0);
      await controller.setCharacterAppearance(models.last.id);
      expect(controller.virtualPhoneCarrierName, startsWith('虚拟'));
      await controller.createLocalSlot(0);
      controller.selectLocation(
        areaId: 'custom_moon',
        stageId: 'custom_landing',
        areaName: '月面基地',
        stageName: '登陆点',
      );
      await controller.saveToLocalSlot(0);
      final second = controller.virtualPhoneCarrierName;
      expect(second, startsWith('月面基地'));
      await controller.setCharacterAppearance(models.first.id);
      expect(controller.virtualPhoneCarrierName, '星空站移动');
      await controller.setCharacterAppearance(models.last.id);
      expect(controller.virtualPhoneCarrierName, second);
      await controller.loadFromLocalSlot(0);
      expect(controller.virtualPhoneCarrierName, second);
      final restarted = await loadModel();
      expect(restarted.activeModelId, models.last.id);
      expect(restarted.virtualPhoneCarrierName, second);
      await restarted.setCharacterAppearance(models.first.id);
      expect(restarted.virtualPhoneCarrierName, '星空站移动');
    },
  );
}
