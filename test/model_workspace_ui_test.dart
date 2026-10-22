import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/conversation_collection_store.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:ryza_chat_mvp/src/model_workspace_page.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late ModelPackageStore packages;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('model_workspace_ui_');
    packages = ModelPackageStore.forTesting();
    await packages.initialize(storageDirectory: directory);
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
      'ai_enabled': false,
      'fish_tts_enabled': false,
      'liquid_glass_chat_ui': false,
    });
    messenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => directory.path,
    );
  });

  tearDown(() async {
    await packages.flush();
    messenger.setMockMethodCallHandler(pathProvider, null);
    await directory.delete(recursive: true);
  });

  Future<AppController> openSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = (await tester.runAsync(
      () => AppController.load(modelPackages: packages),
    ))!;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(controller: controller, onMenuPressed: () {}),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> openWorkspace(WidgetTester tester) async {
    final entry = find.text('模型档案与数据');
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(ModelWorkspacePage), findsOneWidget);
  }

  testWidgets(
    'settings starts with model workspace rather than built-in character choices',
    (tester) async {
      await openSettings(tester);
      expect(
        find.byKey(const ValueKey('settings-character-switcher')),
        findsNothing,
      );
      expect(find.text('莱莎'), findsNothing);
      expect(find.text('苏菲'), findsNothing);
      final builtInPortraits = tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => image.image)
          .whereType<AssetImage>()
          .map((image) => image.assetName);
      expect(
        builtInPortraits,
        isNot(contains('assets/images/character_switch/ryza.png')),
      );
      expect(
        builtInPortraits,
        isNot(contains('assets/images/character_switch/sophie.png')),
      );
      await openWorkspace(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'without a selected model the workspace offers import and disables ZIP export',
    (tester) async {
      final controller = await openSettings(tester);
      expect(controller.activeModelId, isNull);
      await openWorkspace(tester);
      expect(find.text('尚未选择导入模型'), findsOneWidget);
      final export = tester.widget<FilledButton>(
        find.byKey(const ValueKey('export-model-package')),
      );
      final import = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('import-model-package')),
      );
      expect(export.onPressed, isNull);
      expect(import.onPressed, isNotNull);
      expect(find.text('导入模型或模型与数据 ZIP'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('neutral protagonist label keeps primary dialogue and its translation separate', () {
    final parsed = parseAssistantSegments(
      '旁白：彼女は小さく手を振った。\n'
      '主角：こんにちは。一緒に新しい世界を探検しよう。\n'
      '译文：你好。一起探索新的世界吧。',
      defaultPrimaryCharacterId: 'sophie',
    );
    final speech = parsed
        .where((segment) => segment.speaker == ChatSpeaker.ryza)
        .single;
    expect(speech.primaryCharacterId, 'sophie');
    expect(speech.characterId, isNull);
    expect(speech.text, 'こんにちは。一緒に新しい世界を探検しよう。');
    expect(
      parsed
          .where((segment) => segment.speaker == ChatSpeaker.translation)
          .single
          .text,
      '你好。一起探索新的世界吧。',
    );
    expect(
      parsed
          .where((segment) => segment.speaker == ChatSpeaker.narrator)
          .single
          .text,
      '彼女は小さく手を振った。',
    );
    expect(
      parsed.where((segment) => segment.speaker == ChatSpeaker.character),
      isEmpty,
    );
    expect(collectionTextCounts('主角：Hello.\n译文：你好。', false).dialogue, 1);
  });

  test('models sharing a legacy character keep favorites and voice caches separate', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final a = await ConversationCollectionStore.open(
      characterId: 'sophie',
      modelId: 'model_a_$suffix',
    );
    final b = await ConversationCollectionStore.open(
      characterId: 'sophie',
      modelId: 'model_b_$suffix',
    );
    final sourceA = await File('${directory.path}/source_a.wav')
        .writeAsBytes([1, 2, 3]);
    final sourceB = await File('${directory.path}/source_b.wav')
        .writeAsBytes([4, 5, 6]);
    await a.cacheVoice('same-message-id', [sourceA.path], texts: ['Model A']);
    await a.collect([
      {
        'key': 'same-message-id',
        'text': '主角：Model A\n译文：模型甲',
        'isUser': false,
        'saveText': true,
        'saveVoice': true,
      },
    ], name: 'A favorite');
    expect(await b.cards(), isEmpty);
    expect(await b.availableVoiceKeys(), isEmpty);
    expect(await b.voiceSegments('same-message-id'), isEmpty);
    await b.cacheVoice('same-message-id', [sourceB.path], texts: ['Model B']);
    await b.collect([
      {
        'key': 'same-message-id',
        'text': '主角：Model B\n译文：模型乙',
        'isUser': false,
        'saveText': true,
        'saveVoice': true,
      },
    ], name: 'B favorite');
    final reopenedA = ConversationCollectionStore(a.directory);
    final reopenedB = ConversationCollectionStore(b.directory);
    expect((await reopenedA.cards()).single['name'], 'A favorite');
    expect((await reopenedB.cards()).single['name'], 'B favorite');
    expect(
      (await reopenedA.voiceSegments('same-message-id')).single.text,
      'Model A',
    );
    expect(
      (await reopenedB.voiceSegments('same-message-id')).single.text,
      'Model B',
    );
    expect(
      await File((await reopenedA.voiceSegments('same-message-id')).single.path)
          .readAsBytes(),
      [1, 2, 3],
    );
    expect(
      await File((await reopenedB.voiceSegments('same-message-id')).single.path)
          .readAsBytes(),
      [4, 5, 6],
    );
  });
}
