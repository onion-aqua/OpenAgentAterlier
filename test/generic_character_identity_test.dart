import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const appearances = [
    CharacterAppearance(
      id: 'identity_sun',
      label: '橘',
      description: '',
      promptDescription: '',
      assetName: 'identity_sun',
      animated: true,
      idleAnimations: [],
      live2dModelDirectory: 'test/sun',
      live2dModelFileName: 'sun.model3.json',
    ),
    CharacterAppearance(
      id: 'identity_mano',
      label: 'Māno / マノ',
      description: '',
      promptDescription: '',
      assetName: 'identity_mano',
      animated: true,
      idleAnimations: [],
      characterId: 'sophie',
      live2dModelDirectory: 'test/mano',
      live2dModelFileName: 'mano.model3.json',
    ),
  ];
  late Directory directory;
  late ModelPackageStore packages;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('generic_identity_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathChannel,
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? directory.path
              : null,
        );
    packages = ModelPackageStore.forTesting();
    await packages.initialize(storageDirectory: directory);
    characterAppearances.addAll(appearances);
    for (final appearance in appearances) {
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
      (item) => appearances.any((appearance) => appearance.id == item.id),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await packages.flush();
    await directory.delete(recursive: true);
  });

  void expectNoPresetIdentity(String text) {
    for (final value in [
      '莱莎',
      '莱沙',
      '苏菲',
      'Ryza',
      'Sophie',
      'ライザ',
      'ソフィー',
      '库肯岛',
    ]) {
      expect(text, isNot(contains(value)), reason: 'Unexpected preset: $value');
    }
  }

  test(
    'unbound legacy workspace keeps text without implied preset identity',
    () async {
      SharedPreferences.setMockInitialValues({
        'active_character_id_v1': 'sophie',
        'chat_messages': jsonEncode([
          const ChatMessage(text: '保留之前的约定', isUser: true).toJson(),
          const ChatMessage(text: '主角：我会记住。', isUser: false).toJson(),
        ]),
        'memory_summary': '我们约好明天见面',
        'selected_area_name': '旧世界的地图',
      });
      final controller = await AppController.load(modelPackages: packages);
      addTearDown(() async {
        await controller.flushModelSession();
        controller.dispose();
      });
      expect(controller.messages.first.text, '保留之前的约定');
      expect(controller.memorySummary, contains('我们约好明天见面'));
      expect(controller.activeModelId, isNull);
      expect(controller.activeCharacterProfile.names.chinese, '当前角色');
      expect(controller.activeCharacterProfile.staticPortraitAsset, isEmpty);
      expect(controller.selectedCharacterAppearanceId, 'no_model');
      expect(controller.fishAudioReferenceId, isEmpty);
      expect(controller.fishAudioAsmrReferenceId, isEmpty);
      expect(controller.npcChatContacts, isEmpty);
      expect(controller.usesBuiltInCharacterWorld, isFalse);
      expect(controller.currentStoryQuest, isNull);
      expect(controller.virtualPhoneCarrierName, startsWith('虚拟'));
      expectNoPresetIdentity(controller.buildCharacterPrompt());
      expectNoPresetIdentity(controller.buildUserReplySuggestionPrompt());
      expectNoPresetIdentity(controller.demoReply('你好'));
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('legacy_unbound_workspace_v1.sophie'),
        contains('保留之前的约定'),
      );
      await controller.createLocalSlot(0);
      expect(controller.selectedAreaName, '未设置');
      expect(controller.selectedStageName, '未设置');
    },
  );

  test(
    'legacy appearance IDs cannot activate a preset in the empty framework',
    () async {
      final controller = await AppController.load(modelPackages: packages);
      addTearDown(() async {
        await controller.flushModelSession();
        controller.dispose();
      });
      await controller.setCharacterAppearance('seated_01');
      expect(controller.activeModelId, isNull);
      expect(controller.selectedCharacterAppearanceId, 'no_model');
      expectNoPresetIdentity(controller.buildCharacterPrompt());
      await controller.setActiveCharacter('sophie');
      expect(controller.activeCharacterProfile.names.chinese, '当前角色');
      expect(controller.fishAudioReferenceId, isEmpty);
      expectNoPresetIdentity(controller.buildCharacterPrompt());
    },
  );

  test(
    'explicit legacy persona and world remain editable during migration',
    () async {
      SharedPreferences.setMockInitialValues({
        'active_character_id_v1': 'ryza',
        'character_persona': '用户自己写的角色档案',
        'world_setting': '用户自己写的宇宙世界',
        'chat_messages': jsonEncode([
          const ChatMessage(text: '旧存档中的对话', isUser: true).toJson(),
        ]),
      });
      final controller = await AppController.load(modelPackages: packages);
      addTearDown(() async {
        await controller.flushModelSession();
        controller.dispose();
      });
      expect(controller.editableCharacterPersona, '用户自己写的角色档案');
      expect(controller.editableWorldSetting, '用户自己写的宇宙世界');
      final prompt = controller.buildCharacterPrompt();
      expect(prompt, contains('用户自己写的角色档案'));
      expect(prompt, contains('用户自己写的宇宙世界'));
      expectNoPresetIdentity(prompt);
      await controller.flushModelSession();
      final restored = await AppController.load(modelPackages: packages);
      addTearDown(() async {
        await restored.flushModelSession();
        restored.dispose();
      });
      expect(restored.characterPersona, '用户自己写的角色档案');
      expectNoPresetIdentity(restored.activeCharacterProfile.defaultPersona);
    },
  );

  test(
    'selected model supplies identity across language and speech modes',
    () async {
      final controller = await AppController.load(modelPackages: packages);
      addTearDown(() async {
        await controller.flushModelSession();
        controller.dispose();
      });
      for (final appearance in appearances) {
        await controller.setCharacterAppearance(appearance.id);
        controller.setCharacterPersona('${appearance.label}是独立的天文观测员。');
        controller.setWorldSetting('${appearance.label}居住在星空观测站。');
        controller.configureLanguages(
          interface: AppLanguage.chinese,
          narrator: AppLanguage.japanese,
          characterReply: AppLanguage.japanese,
          translation: TranslationLanguage.chinese,
        );
        controller.configureFishAudio(
          enabled: true,
          model: 'drama-3',
          referenceId: 'normal-${appearance.id}',
          asmrReferenceId: 'asmr-${appearance.id}',
        );
        controller.setTtsVoiceMode(TtsVoiceMode.asmr);
        for (final compatibility in [false, true]) {
          controller.llmContextCompatibility = compatibility;
          for (final injectPersona in [false, true]) {
            controller.characterPersonaInjectionEnabled = injectPersona;
            for (final independent in [false, true]) {
              final prompt = controller.buildCharacterPrompt(
                currentInput: '请轻声和我说话',
                independentPerformance: independent,
              );
              expect(prompt, contains(appearance.label));
              expect(prompt, contains('主角：'));
              expect(prompt, contains('日语'));
              expect(prompt, contains('轻声'));
              expectNoPresetIdentity(prompt);
            }
          }
        }
        expect(
          controller.activeCharacterProfile.renderMode,
          CharacterRenderMode.live2d,
        );
        expect(
          controller.buildUserReplySuggestionPrompt(),
          contains(appearance.label),
        );
        expectNoPresetIdentity(controller.buildUserReplySuggestionPrompt());
        expectNoPresetIdentity(controller.demoReply('你好'));
        expect(
          controller.queryContextTool('lookup_character', {}),
          contains(appearance.label),
        );
        expect(
          controller.queryContextTool('travel_to_location', {}),
          contains('未配置'),
        );
        expect(controller.currentStoryQuest, isNull);
        expect(controller.npcChatContacts, isEmpty);
        expect(controller.virtualPhoneCarrierName, startsWith('虚拟'));
        controller.selectedAreaId = 'area_01';
        controller.selectedAreaName = '未设置地点';
        expect(controller.virtualPhoneCarrierName, startsWith('虚拟'));
        controller.selectedAreaName = '星空观测站';
        expect(controller.virtualPhoneCarrierName, startsWith('星空观测站'));
      }
    },
  );

  test(
    'current model never advertises previous model actions after a switch',
    () async {
      final controller = await AppController.load(modelPackages: packages);
      addTearDown(() async {
        await controller.flushModelSession();
        controller.dispose();
      });
      await controller.setCharacterAppearance(appearances.first.id);
      final originalCapabilities = CharacterPerformancePromptContext(
        appearanceId: appearances.first.id,
        posture: 'standing',
        revision: 1,
        resourcesReady: true,
        playableActionDescriptions: const {'wave': '仅旧模型可用的招手'},
      );
      expect(
        controller.buildCharacterPrompt(
          performanceContext: originalCapabilities,
        ),
        contains('仅旧模型可用的招手'),
      );
      await controller.setCharacterAppearance(appearances.last.id);
      final prompt = controller.buildCharacterPrompt(
        performanceContext: originalCapabilities,
      );
      expect(prompt, contains('"status":"stale"'));
      expect(prompt, isNot(contains('仅旧模型可用的招手')));
      expect(prompt, contains(appearances.last.label));
      expectNoPresetIdentity(prompt);
    },
  );

  test('imported ASMR prompt keeps delivery scope and disabled cues', () async {
    final controller = await AppController.load(modelPackages: packages);
    addTearDown(() async {
      await controller.flushModelSession();
      controller.dispose();
    });
    await controller.setCharacterAppearance(appearances.first.id);
    controller.fishTtsEnabled = true;
    controller.independentSpeechPerformance = false;
    controller.ttsVoiceMode = TtsVoiceMode.asmr;
    controller.ttsProvider = TtsProvider.fishAudio;
    controller.ttsCueDensity = TtsCueDensity.normal;
    var prompt = controller.buildCharacterPrompt();
    expect(prompt, contains('整段清晰连贯的耳语'));
    expect(prompt, contains('使用whispering'));
    expectNoPresetIdentity(prompt);
    controller.ttsProvider = TtsProvider.fishAudioMcp;
    controller.fishMcpModel = 'drama-3';
    prompt = controller.buildCharacterPrompt();
    expect(prompt, contains('使用whisper，'));
    controller.ttsCueDensity = TtsCueDensity.off;
    prompt = controller.buildCharacterPrompt();
    expect(prompt, contains('不输出句内耳语、停顿或气声控制标签'));
    expect(prompt, isNot(contains('使用whisper，')));
    controller.ttsCueDensity = TtsCueDensity.normal;
    controller.independentSpeechPerformance = true;
    prompt = controller.buildCharacterPrompt();
    expect(prompt, contains('不输出句内耳语、停顿或气声控制标签'));
  });

  test(
    'imported prompt respects inactive profile drafts and on-demand memory',
    () async {
      final controller = await AppController.load(modelPackages: packages);
      addTearDown(() async {
        await controller.flushModelSession();
        controller.dispose();
      });
      await controller.setCharacterAppearance(appearances.first.id);
      controller.configureUserProfile(
        address: '伙伴',
        portrait: '',
        relationshipRole: UserRelationshipRole.familiarPartner,
        interactionStyle: UserInteractionStyle.balanced,
        boundaries: '',
        relationshipCustom: '尚未启用的关系草稿',
        interactionCustom: '尚未启用的互动草稿',
        preferCustom: false,
      );
      expect(controller.buildCharacterPrompt(), isNot(contains('尚未启用')));
      controller.setPreferCustomUserProfile(true);
      expect(controller.buildCharacterPrompt(), contains('尚未启用的关系草稿'));
      controller.longTermMemoryEnabled = true;
      controller.memorySummary = '模型专属历史事实';
      controller.setAgentEnabled(true);
      final prompt = controller.buildCharacterPrompt();
      expect(prompt, isNot(contains('模型专属历史事实')));
      expect(prompt, contains('search_memory'));
      expect(
        controller.queryContextTool('search_memory', {'query': '历史事实'}),
        contains('模型专属历史事实'),
      );
      controller.setLongTermMemoryEnabled(false);
      expect(
        controller.queryContextTool('search_memory', {'query': '历史事实'}),
        isNot(contains('模型专属历史事实')),
      );
    },
  );
}
