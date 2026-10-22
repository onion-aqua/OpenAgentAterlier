import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/mimo_tts_config.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:ryza_chat_mvp/src/settings_slots.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;
  late ModelPackageStore packages;

  const a = CharacterAppearance(
    id: 'scope_model_a',
    label: '月见',
    description: '',
    promptDescription: '',
    assetName: 'scope_model_a',
    animated: true,
    idleAnimations: [],
    live2dModelDirectory: 'test/a',
    live2dModelFileName: 'a.model3.json',
  );
  const b = CharacterAppearance(
    id: 'scope_model_b',
    label: '星见',
    description: '',
    promptDescription: '',
    assetName: 'scope_model_b',
    animated: true,
    idleAnimations: [],
    characterId: 'sophie',
    live2dModelDirectory: 'test/b',
    live2dModelFileName: 'b.model3.json',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('model_scope_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathChannel,
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
    characterAppearances.removeWhere((item) => [a.id, b.id].contains(item.id));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await packages.flush();
    await directory.delete(recursive: true);
  });

  test('fresh framework has no built-in persona or world', () async {
    final c = await AppController.load(modelPackages: packages);
    addTearDown(c.dispose);
    expect(c.activeModelId, isNull);
    expect(c.messages.single.text, contains('先导入模型'));
    expect(c.buildCharacterPrompt(), isNot(contains('莱莎')));
    expect(c.buildCharacterPrompt(), isNot(contains('苏菲')));
    expect(c.npcChatContacts, isEmpty);
  });

  test(
    'models isolate conversations, settings and save slots across old owners',
    () async {
      final c = await AppController.load(modelPackages: packages);
      c.configureAi(
        enabled: true,
        baseUrl: 'https://shared.invalid/v1',
        model: 'shared-llm',
      );
      await c.setCharacterAppearance(a.id);
      await c.setModelDisplayName('月见本人');
      c.setCharacterPersona('只属于月见的人物设定');
      c.setWorldSetting('月见所在的月面世界');
      c.configureLongTermMemory(enabled: true, summary: '约好在月面见面');
      c.configureUserProfile(
        address: '旅人',
        portrait: '月见的朋友',
        relationshipRole: UserRelationshipRole.familiarPartner,
        interactionStyle: UserInteractionStyle.balanced,
        boundaries: '',
      );
      c.configureLanguages(
        interface: AppLanguage.english,
        narrator: AppLanguage.japanese,
        characterReply: AppLanguage.japanese,
        translation: TranslationLanguage.chinese,
      );
      c.configureFishAudio(
        enabled: true,
        model: 'drama-3',
        baseUrl: 'https://shared-tts.invalid/v1/tts',
        referenceId: 'moon-voice',
      );
      c.configureFishMcp(
        model: 'drama-3',
        voice: 'moon-mcp',
        asmrVoice: 'moon-asmr',
        autoFallback: false,
      );
      c.addUserMessage('只有月见知道的暗号');
      c.addAssistantMessage('主角：覚えたよ。');
      await c.attachTranslation(c.messages.last, '译文：我记住了。');
      final bank = c.settingsSlots(SettingsSlotKind.world);
      bank.entries[2] = {'text': '月见的备用世界'};
      c.saveSettingsSlots(SettingsSlotKind.world, bank);
      await c.saveToLocalSlot(0, name: '月见存档');
      final oldRevision = c.dataRevision;

      await c.setCharacterAppearance(b.id);
      expect(c.activeCharacterId, 'sophie');
      expect(c.activeModelId, b.id);
      expect(c.activeConversationScopeId, b.id);
      expect(c.activeCharacterProfile.names.chinese, '星见');
      expect(c.messages.map((m) => m.text).join(), isNot(contains('暗号')));
      expect(c.memorySummary, isEmpty);
      expect(c.characterPersona, isEmpty);
      expect(c.worldSetting, isEmpty);
      expect(c.userAddress, isNot('旅人'));
      expect(c.localSaveSlots.every((slot) => slot == null), isTrue);
      expect(c.settingsSlots(SettingsSlotKind.world).entries[2], isNull);
      expect(c.fishAudioReferenceId, isEmpty);
      expect(c.fishAudioAsmrReferenceId, isEmpty);
      expect(c.fishMcpVoice, isEmpty);
      expect(c.fishMcpAsmrVoice, isEmpty);
      expect(c.narratorLanguage, AppLanguage.chinese);
      expect(c.translationLanguage, TranslationLanguage.none);
      expect(c.interfaceLanguage, AppLanguage.english);
      expect(c.openAiModel, 'shared-llm');
      expect(c.fishAudioBaseUrl, 'https://shared-tts.invalid/v1/tts');
      expect(c.fishAudioModel, 'drama-3');
      expect(c.ttsProvider, TtsProvider.fishAudioMcp);
      expect(c.npcChatContacts, isEmpty);
      expect(c.worldTravelCatalog.destinations, isEmpty);
      expect(c.buildCharacterPrompt(), contains('主角：'));
      expect(c.buildCharacterPrompt(), isNot(contains('莱莎')));
      expect(c.buildCharacterPrompt(), isNot(contains('苏菲')));
      expect(c.queryContextTool('lookup_character', {}), isNot(contains('苏菲')));
      expect(
        c.settleCharacterState('late', {'emotion': 'sad'}, oldRevision),
        isFalse,
      );
      c.addUserMessage('只有星见知道的内容');
      await c.saveToLocalSlot(0, name: '星见存档');
      final bSlot = c.exportLocalSlot(0);

      await c.setCharacterAppearance(a.id);
      expect(c.activeCharacterId, 'ryza');
      expect(c.activeModelDisplayName, '月见本人');
      expect(c.memorySummary, '约好在月面见面');
      expect(c.characterPersona, '只属于月见的人物设定');
      expect(c.userAddress, '旅人');
      expect(c.narratorLanguage, AppLanguage.japanese);
      expect(c.fishMcpVoice, 'moon-mcp');
      expect(c.localSaveSlots[0]!.name, '月见存档');
      expect(c.messages.last.translatedText, '译文：我记住了。');
      expect(
        c.settingsSlots(SettingsSlotKind.world).entries[2]!['text'],
        '月见的备用世界',
      );
      await expectLater(c.importLocalSlot(1, bSlot), throwsFormatException);
      await c.createLocalSlot(1, name: '月见新档');
      expect(c.activeModelId, a.id);
      expect(c.selectedCharacterAppearanceId, a.id);
      expect(c.activeModelDisplayName, '月见本人');
      expect(c.buildCharacterPrompt(), isNot(contains('莱莎')));
      await c.flushModelSession();
      c.dispose();

      final restored = await AppController.load(modelPackages: packages);
      addTearDown(restored.dispose);
      expect(restored.activeModelId, a.id);
      expect(restored.activeModelDisplayName, '月见本人');
      expect(restored.localSaveSlots[0]!.name, '月见存档');
      expect(restored.localSaveSlots[1]!.name, '月见新档');
      await restored.setCharacterAppearance(b.id);
      expect(restored.messages.last.text, '只有星见知道的内容');
      expect(restored.localSaveSlots[0]!.name, '星见存档');
    },
  );

  test(
    'portable session excludes services and local reference paths',
    () async {
      final c = await AppController.load(modelPackages: packages);
      addTearDown(c.dispose);
      await c.setCharacterAppearance(a.id);
      c.configureMimoTts(
        config: const MimoTtsConfig(
          baseUrl: 'https://private-service.invalid/v1',
          referencePath: 'C:/private/moon.wav',
          referenceName: 'moon.wav',
          instructions: '月见的声音',
        ),
        enabled: true,
        emotionIntensity: TtsEmotionIntensity.natural,
        cueDensity: TtsCueDensity.normal,
        previewText: '你好',
      );
      await c.flushModelSession();
      final encoded = jsonEncode(await packages.readSession(a.id));
      expect(encoded, contains('月见的声音'));
      expect(encoded, isNot(contains('private-service')));
      expect(encoded, isNot(contains('C:/private')));
      await c.setCharacterAppearance(b.id);
      expect(c.mimoTts.referencePath, isEmpty);
      await c.setCharacterAppearance(a.id);
      expect(c.mimoTts.referencePath, 'C:/private/moon.wav');
    },
  );

  test(
    'legacy session and slots migrate only to the previously active model',
    () async {
      final legacy = await AppController.load(modelPackages: packages);
      legacy.addUserMessage('旧的约定');
      legacy.setCharacterPersona('旧人物设定');
      legacy.configureLongTermMemory(enabled: true, summary: '旧长期记忆');
      await legacy.saveToLocalSlot(0, name: '旧存档');
      await legacy.flushModelSession();
      legacy.dispose();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_character_appearance', a.id);
      await prefs.remove('model_scope_migration_v1');
      final migrated = await AppController.load(modelPackages: packages);
      addTearDown(migrated.dispose);
      expect(migrated.activeModelId, a.id);
      expect(migrated.memorySummary, '旧长期记忆');
      expect(migrated.characterPersona, '旧人物设定');
      expect(migrated.localSaveSlots[0]!.name, '旧存档');
      await migrated.setCharacterAppearance(b.id);
      expect(migrated.memorySummary, isEmpty);
      expect(migrated.characterPersona, isEmpty);
      expect(migrated.localSaveSlots[0], isNull);
    },
  );

  test(
    'portable model session remaps owner and slots without selecting it',
    () async {
      final c = await AppController.load(modelPackages: packages);
      addTearDown(c.dispose);
      await c.setCharacterAppearance(a.id);
      c.setCharacterPersona('包里的角色');
      c.addUserMessage('包里的约定');
      await c.saveToLocalSlot(0, name: '包里的存档');
      await c.flushModelSession();
      final sourceSession = await packages.readSession(a.id);
      final sourceSlots = await packages.readSaveSlots(a.id);
      await c.restoreModelPackageData(
        b.id,
        session: sourceSession,
        saveSlots: sourceSlots,
      );
      expect(c.activeModelId, a.id);
      await c.setCharacterAppearance(b.id);
      expect(c.activeModelId, b.id);
      expect(c.activeCharacterId, 'sophie');
      expect(c.characterPersona, '包里的角色');
      expect(c.messages.last.text, '包里的约定');
      final snapshot = c.exportLocalSlot(0)['snapshot'] as Map;
      expect(snapshot['modelId'], b.id);
      expect(snapshot['characterId'], 'sophie');
      expect(snapshot['selectedCharacterAppearanceId'], b.id);
      await c.loadFromLocalSlot(0);
      expect(c.activeModelId, b.id);
    },
  );

  test('failed canonical package write leaves previous model active', () async {
    final failing = _FailingModelPackages();
    await failing.initialize(storageDirectory: directory);
    final c = await AppController.load(modelPackages: failing);
    addTearDown(c.dispose);
    await c.setCharacterAppearance(a.id);
    c.addUserMessage('不能丢失的旧会话');
    await c.flushModelSession();
    failing.rejectModelId = b.id;
    await expectLater(c.setCharacterAppearance(b.id), throwsStateError);
    expect(c.activeModelId, a.id);
    expect(c.messages.last.text, '不能丢失的旧会话');
    expect(c.activeCharacterId, 'ryza');
    await failing.flush();
  });

  test(
    'resource-only portable package retains its manifest display name',
    () async {
      final c = await AppController.load(modelPackages: packages);
      addTearDown(c.dispose);
      await c.setCharacterAppearance(a.id);
      await c.restoreModelPackageData(b.id, displayName: '  新的独立角色  ');
      expect(c.activeModelId, a.id);
      await c.setCharacterAppearance(b.id);
      expect(c.activeModelDisplayName, '新的独立角色');
    },
  );

  test(
    'unavailable selected model cannot leak its state into an empty framework',
    () async {
      final c = await AppController.load(modelPackages: packages);
      await c.setCharacterAppearance(a.id);
      c.setCharacterPersona('消失模型的私人身份');
      c.configureLongTermMemory(enabled: true, summary: '消失模型的私人记忆');
      c.addUserMessage('消失模型的会话');
      await c.flushModelSession();
      c.dispose();
      characterAppearances.remove(a);
      final restored = await AppController.load(modelPackages: packages);
      addTearDown(restored.dispose);
      expect(restored.activeModelId, isNull);
      expect(restored.modelScopeRestoreError, isNotNull);
      expect(restored.characterPersona, isEmpty);
      expect(restored.memorySummary, isEmpty);
      expect(
        restored.messages.map((m) => m.text).join(),
        isNot(contains('消失模型')),
      );
      expect(restored.usesBuiltInCharacterWorld, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('unavailable_model_recovery_v1.${a.id}'),
        contains('私人记忆'),
      );
      expect(jsonEncode(await packages.readSession(a.id)), contains('私人记忆'));
    },
  );

  test('model backup cannot overwrite device service configuration', () async {
    final c = await AppController.load(modelPackages: packages);
    addTearDown(c.dispose);
    await c.setCharacterAppearance(a.id);
    c.configureAi(
      enabled: true,
      baseUrl: 'https://old.invalid/v1',
      model: 'old',
    );
    final backup = c.exportData();
    c.configureAi(
      enabled: true,
      baseUrl: 'https://current.invalid/v1',
      model: 'current',
    );
    await c.importData(backup);
    expect(c.activeModelId, a.id);
    expect(c.openAiBaseUrl, 'https://current.invalid/v1');
    expect(c.openAiModel, 'current');
  });

  test(
    'delayed backup hydration cannot reapply a model after switching away',
    () async {
      final c = await AppController.load(modelPackages: packages);
      addTearDown(c.dispose);
      await c.setCharacterAppearance(a.id);
      final backup = c.exportData();
      backup['messages'] = [
        ChatMessage(
          text: '旧模型的附件',
          isUser: true,
          attachments: [
            ChatAttachment(
              name: 'a.png',
              mimeType: 'image/png',
              size: 4,
              thumbnailBytes: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ],
        ).toJson(includeAttachmentThumbnails: true),
      ];
      final requested = Completer<void>();
      final resume = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, (call) {
            if (call.method == 'getApplicationSupportDirectory') {
              if (!requested.isCompleted) requested.complete();
              return resume.future;
            }
            return Future<Object?>.value(null);
          });
      final pending = c.importData(backup);
      final expectedFailure = expectLater(pending, throwsStateError);
      await requested.future;
      await c.setCharacterAppearance(b.id);
      c.addUserMessage('新模型的会话');
      resume.complete(directory.path);
      await expectedFailure;
      expect(c.activeModelId, b.id);
      expect(c.messages.last.text, '新模型的会话');
      await c.flushModelSession();
    },
  );
}

class _FailingModelPackages extends ModelPackageStore {
  _FailingModelPackages() : super.forTesting();
  String? rejectModelId;

  @override
  Future<void> saveSession(
    String modelId,
    Map<String, dynamic> session, {
    Map<String, dynamic>? saveSlots,
  }) {
    if (modelId == rejectModelId) throw StateError('simulated disk failure');
    return super.saveSession(modelId, session, saveSlots: saveSlots);
  }
}
