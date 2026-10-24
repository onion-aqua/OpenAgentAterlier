import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/image_generation_config.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:ryza_chat_mvp/src/personality/personality_presets.dart';
import 'package:ryza_chat_mvp/src/personality/personality_profile.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_records.dart';
import 'package:ryza_chat_mvp/src/shop_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;
  late ModelPackageStore packages;
  const first = CharacterAppearance(
    id: 'ported_features_moon',
    label: '月见',
    description: '',
    promptDescription: '',
    assetName: 'ported_features_moon',
    animated: true,
    idleAnimations: [],
    live2dModelDirectory: 'fixture/moon',
    live2dModelFileName: 'model.model3.json',
  );
  // The same historical owner must never make the two imported models share data.
  const second = CharacterAppearance(
    id: 'ported_features_star',
    label: '星见',
    description: '',
    promptDescription: '',
    assetName: 'ported_features_star',
    animated: true,
    idleAnimations: [],
    live2dModelDirectory: 'fixture/star',
    live2dModelFileName: 'model.model3.json',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('ported_model_features_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    packages = ModelPackageStore.forTesting();
    await packages.initialize(storageDirectory: directory);
    characterAppearances.addAll([first, second]);
    for (final appearance in [first, second]) {
      await packages.ensureModel(
        modelId: appearance.id,
        format: 'live2d',
        label: appearance.label,
        ownerCharacterId: appearance.characterId,
        files: {'model.json': Uint8List.fromList(utf8.encode('{}'))},
      );
    }
  });

  tearDown(() async {
    characterAppearances.removeWhere(
      (appearance) => [first.id, second.id].contains(appearance.id),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await packages.flush();
    await directory.delete(recursive: true);
  });

  Future<AppController> load() async {
    final controller = await AppController.load(modelPackages: packages);
    addTearDown(controller.dispose);
    return controller;
  }

  PersonalityConfiguration selectedPersonality(String scope) {
    final profile = PersonalityPresets.create(
      'tsundere',
      scope,
      profileId: 'model-specific-profile',
    ).copyWith(name: '月见专属人格');
    return PersonalityConfiguration(
      characterId: scope,
      activeProfileId: profile.profileId,
      enabled: true,
      profiles: [profile],
    );
  }

  test(
    'same-owner models isolate personality and oath-ring consequences',
    () async {
      final controller = await load();
      await controller.setCharacterAppearance(first.id);
      await controller.savePersonalityConfiguration(
        selectedPersonality(first.id),
      );
      controller.relationshipPoints = 20000;
      expect(controller.buyShopItem(ShopCatalog.oathRingId), isTrue);
      expect(
        controller.loseOathRing(expectedRevision: controller.dataRevision),
        isTrue,
      );
      expect(controller.characterState.values['mood'], -500);
      expect(
        controller.canBuyShopItem(ShopCatalog.reconciliationVoucherId),
        isFalse,
      );
      expect(controller.buildCharacterPrompt(), contains('当前扮演指令'));
      await controller.saveToLocalSlot(0, name: '人格与戒指');

      await controller.setCharacterAppearance(second.id);
      expect(controller.personalityEnabled, isFalse);
      expect(controller.personalityConfiguration.characterId, second.id);
      expect(controller.characterState.reconciliationPurchaseBlocked, isFalse);
      expect(controller.preciousItems[ShopCatalog.oathRingId], isNull);
      expect(controller.localSaveSlots[0], isNull);
      expect(controller.buildCharacterPrompt(), isNot(contains('月见专属人格')));

      await controller.setCharacterAppearance(first.id);
      expect(controller.personalityEnabled, isTrue);
      expect(controller.personalityConfiguration.activeProfile.name, '月见专属人格');
      expect(controller.characterState.values['mood'], -500);
      expect(controller.characterState.reconciliationPurchaseBlocked, isTrue);
      expect(controller.localSaveSlots[0]!.name, '人格与戒指');
      expect(controller.usesBuiltInCharacterWorld, isFalse);
    },
  );

  test('portable personality rebinds its scope and excludes image connection settings', () async {
    final controller = await load();
    await controller.setCharacterAppearance(first.id);
    await controller.savePersonalityConfiguration(
      selectedPersonality(first.id),
    );
    controller.saveCallRecord(
      CallRecord(
        id: 'portable-call',
        contactId: 'primary:${first.id}',
        contactName: first.label,
        startedAt: DateTime.utc(2026, 10, 24),
        incoming: false,
        turns: const [
          {'user': '记得明天看月亮', 'assistant': '我们明天一起看月亮。'},
        ],
      ),
      expectedRevision: controller.dataRevision,
    );
    controller.configureImageGeneration(
      const ImageGenerationConfig(
        enabled: true,
        baseUrl: 'https://device-image.invalid/v1',
        model: 'device-image-model',
      ),
    );
    await controller.saveToLocalSlot(0, name: '带人格的模型快照');
    await controller.flushModelSession();
    final decoded = ModelPackageStore.decodePackage(
      await packages.packageBytes(first.id),
    );
    expect(jsonEncode(decoded.session), contains('月见专属人格'));
    expect(
      jsonEncode(decoded.session),
      isNot(contains('device-image.invalid')),
    );
    await controller.restoreModelPackageData(
      second.id,
      session: decoded.session,
      saveSlots: decoded.saveSlots,
    );
    await controller.setCharacterAppearance(second.id);
    expect(controller.personalityConfiguration.characterId, second.id);
    expect(
      controller.personalityConfiguration.activeProfile.characterId,
      second.id,
    );
    expect(controller.personalityConfiguration.activeProfile.name, '月见专属人格');
    expect(controller.personalityEnabled, isTrue);
    expect(controller.callRecords.single.contactId, 'primary:${second.id}');
    expect(
      controller.callMemoryFor('primary:${second.id}'),
      contains('我们明天一起看月亮'),
    );
    expect(
      controller.imageGeneration.baseUrl,
      'https://device-image.invalid/v1',
    );
    await controller.loadFromLocalSlot(0);
    expect(controller.activeModelId, second.id);
    expect(controller.personalityConfiguration.characterId, second.id);
    expect(controller.callRecords.single.contactId, 'primary:${second.id}');
  });

  test(
    'generated-image tasks have separate durable model directories',
    () async {
      final controller = await load();
      await controller.setCharacterAppearance(first.id);
      final firstStore = controller.imageGenerationStore;
      final task = await firstStore.createTask(prompt: '月见的月光画面');
      await controller.setCharacterAppearance(second.id);
      final secondStore = controller.imageGenerationStore;
      expect(identical(firstStore, secondStore), isFalse);
      await secondStore.load();
      expect(secondStore.tasks, isEmpty);
      await secondStore.createTask(prompt: '星见的星空画面');
      await controller.setCharacterAppearance(first.id);
      expect(identical(controller.imageGenerationStore, firstStore), isTrue);
      expect(firstStore.tasks.single.id, task.id);
      expect(firstStore.tasks.single.prompt, '月见的月光画面');
      expect(
        await Directory('${directory.path}/image_generation_v1/${first.id}')
            .exists(),
        isTrue,
      );
      expect(
        await Directory('${directory.path}/image_generation_v1/${second.id}')
            .exists(),
        isTrue,
      );
    },
  );

  test(
    'saved user voice IDs survive switching and AppController.load',
    () async {
      final controller = await load();
      await controller.setCharacterAppearance(first.id);
      controller.configureFishAudio(
        enabled: true,
        model: 's2-pro',
        referenceId: 'user-moon-rest-voice',
        asmrReferenceId: 'user-moon-rest-asmr',
      );
      controller.configureFishMcp(
        model: 's2-pro',
        autoFallback: false,
        voice: 'user-moon-mcp-voice',
        asmrVoice: 'user-moon-mcp-asmr',
      );
      await controller.flushModelSession();
      await controller.setCharacterAppearance(second.id);
      expect(controller.fishAudioReferenceId, isEmpty);
      expect(controller.fishMcpVoice, isEmpty);
      controller.configureFishAudio(
        enabled: true,
        model: 's2-pro',
        referenceId: 'user-star-rest-voice',
        asmrReferenceId: 'user-star-rest-asmr',
      );
      controller.configureFishMcp(
        model: 's2-pro',
        autoFallback: false,
        voice: 'user-star-mcp-voice',
        asmrVoice: 'user-star-mcp-asmr',
      );
      await controller.flushModelSession();
      final restored = await load();
      expect(restored.activeModelId, second.id);
      expect(restored.fishAudioReferenceId, 'user-star-rest-voice');
      expect(restored.fishAudioAsmrReferenceId, 'user-star-rest-asmr');
      expect(restored.fishMcpVoice, 'user-star-mcp-voice');
      expect(restored.fishMcpAsmrVoice, 'user-star-mcp-asmr');
      await restored.setCharacterAppearance(first.id);
      expect(restored.fishAudioReferenceId, 'user-moon-rest-voice');
      expect(restored.fishAudioAsmrReferenceId, 'user-moon-rest-asmr');
      expect(restored.fishMcpVoice, 'user-moon-mcp-voice');
      expect(restored.fishMcpAsmrVoice, 'user-moon-mcp-asmr');
    },
  );
}
