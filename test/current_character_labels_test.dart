import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alchemy_screen.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/mission_screen.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:ryza_chat_mvp/src/quest_models.dart';
import 'package:ryza_chat_mvp/src/shop_catalog.dart';
import 'package:ryza_chat_mvp/src/shop_screen.dart';
import 'package:ryza_chat_mvp/src/world_map_localization.dart';
import 'package:ryza_chat_mvp/src/world_travel_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const models = [
    CharacterAppearance(
      id: 'labels_sun',
      label: '橘',
      description: '',
      promptDescription: '',
      assetName: 'labels_sun',
      animated: true,
      idleAnimations: [],
      live2dModelDirectory: 'test/sun',
      live2dModelFileName: 'sun.model3.json',
    ),
    CharacterAppearance(
      id: 'labels_moon',
      label: '星见',
      description: '',
      promptDescription: '',
      assetName: 'labels_moon',
      animated: true,
      idleAnimations: [],
      live2dModelDirectory: 'test/moon',
      live2dModelFileName: 'moon.model3.json',
    ),
  ];
  late Directory directory;
  late ModelPackageStore packages;
  late AppController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('character_labels_');
    SharedPreferences.setMockInitialValues({'liquid_glass_chat_ui': false});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => directory.path);
    packages = ModelPackageStore.forTesting();
    await packages.initialize(storageDirectory: directory);
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
    controller = await AppController.load(modelPackages: packages);
    await controller.setCharacterAppearance(models.first.id);
  });

  tearDown(() async {
    await controller.flushModelSession();
    controller.dispose();
    await packages.flush();
    characterAppearances.removeWhere((model) => models.contains(model));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await directory.delete(recursive: true);
  });

  testWidgets('shop and inventory follow renames and isolate model items', (
    tester,
  ) async {
    await tester.runAsync(() async {
      controller.relationshipPoints = 200;
      expect(controller.buyShopItem('ryza_gift'), isTrue);
      await controller.flushModelSession();
    });
    await tester.pumpWidget(
      MaterialApp(home: ShopScreen(controller: controller)),
    );
    expect(find.text('给橘的礼物'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(home: AlchemyScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('给橘的礼物 × 1'), findsOneWidget);
    expect(find.textContaining('橘的物品与使用记录'), findsOneWidget);
    expect(find.textContaining('让莱莎'), findsNothing);
    expect(find.textContaining('尚未配置聊天入包'), findsOneWidget);

    await tester.runAsync(() => controller.setModelDisplayName('橘子'));
    await tester.pumpAndSettle();
    expect(find.text('给橘子的礼物 × 1'), findsOneWidget);
    expect(find.text('给橘的礼物 × 1'), findsNothing);
    await tester.runAsync(() async {
      expect(controller.useShopItem('ryza_gift'), isTrue);
      await controller.flushModelSession();
    });
    expect(controller.characterState.reason, contains('橘子'));
    expect(controller.characterState.reason, isNot(contains('莱莎')));

    await tester.runAsync(
      () => controller.setCharacterAppearance(models.last.id),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('星见的物品与使用记录'), findsOneWidget);
    expect(controller.preciousItems, isEmpty);
    expect(find.textContaining('橘子'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quest UI uses the current name without inherited story', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: MissionScreen(controller: controller)),
    );
    expect(find.text('橘委托'), findsOneWidget);
    expect(find.text('橘尚未配置主线任务。'), findsOneWidget);
    expect(find.text('越过湖面'), findsNothing);
    await tester.tap(find.text('橘委托'));
    await tester.pumpAndSettle();
    expect(find.text('还没有橘委托'), findsOneWidget);
    expect(find.textContaining('尚未配置任务创建'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('localized content uses supplied names and neutral fallbacks', () {
    for (final appearance in characterAppearances) {
      expect(appearance.promptDescription, isNot(matches('莱莎|Ryza|ライザ')));
      expect(appearance.description, isNot(matches('莱莎|Ryza|ライザ')));
    }
    const home = WorldTravelDestination(
      areaId: 'area_01',
      areaName: '测试区域',
      fieldId: 'field_01_001',
      fieldName: '测试地区',
      stageId: 'stage_01_001_04',
      stageName: 'ライザの家',
    );
    for (final language in AppLanguage.values) {
      for (final item in ShopCatalog.items) {
        for (final text in [
          item.name(language, characterName: '星见'),
          item.description(language, characterName: '星见'),
        ]) {
          expect(text, isNot(matches('莱莎|Ryza|ライザ')));
          expect(text, isNot(contains('{character}')));
        }
      }
      expect(
        ShopCatalog.byId('ryza_gift')!.name(language, characterName: '星见'),
        contains('星见'),
      );
      expect(
        builtInStoryQuests[1].description(language, characterName: '星见'),
        contains('星见'),
      );
      expect(
        localizedWorldPlaceName(
          id: 'stage_01_001_04',
          fallback: 'ライザの家',
          language: language,
          characterName: '星见',
        ),
        contains('星见'),
      );
      expect(
        localizedWorldPlaceName(
          id: 'stage_01_001_04',
          fallback: 'ライザの家',
          language: language,
        ),
        isNot(matches('莱莎|Ryza|ライザ')),
      );
      expect(
        home.toToolJson(language, characterName: '星见')['stage_name'],
        contains('星见'),
      );
    }
    expect(
      const WorldTravelCatalog([home])
          .search(query: '星见的家', currentAreaId: 'area_01', characterName: '星见'),
      contains(home),
    );
  });
}
