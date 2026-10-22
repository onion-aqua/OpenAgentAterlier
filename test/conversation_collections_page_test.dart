import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/conversation_collection_store.dart';
import 'package:ryza_chat_mvp/src/conversation_collections_page.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const audioChannels = [
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ];
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const companionChannel = MethodChannel('agent_atelier_r/companion_runtime');
  const companionEvents = MethodChannel(
    'agent_atelier_r/companion_runtime/events',
  );
  final playerEventChannels = <String>{};
  final audioMethods = <String>[];

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('collection-page-test-');
    messenger.setMockMethodCallHandler(pathChannel, (_) async => root.path);
    messenger.setMockMethodCallHandler(
      companionChannel,
      (_) async => {'running': true},
    );
    messenger.setMockMethodCallHandler(companionEvents, (_) async => null);
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        audioMethods.add(call.method);
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final events = 'xyz.luan/audioplayers/events/$id';
          playerEventChannels.add(events);
          messenger.setMockMethodCallHandler(
            MethodChannel(events),
            (_) async => null,
          );
        }
        return 1;
      });
    }
    await AudioPlayer.global.ensureInitialized();
    final store = await ConversationCollectionStore.open();
    await store.collect([
      {
        'key': 'page-test',
        'text': '主题测试',
        'isUser': true,
        'saveText': true,
        'saveVoice': false,
      },
    ], name: '收藏主题测试');
  });
  tearDownAll(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(companionChannel, null);
    messenger.setMockMethodCallHandler(companionEvents, null);
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    for (final name in playerEventChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    await root.delete(recursive: true);
  });

  testWidgets('collection cards follow both themes and the live glass switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    for (final brightness in Brightness.values) {
      controller.setLiquidGlassChatUi(false);
      await tester.pumpWidget(
        MaterialApp(
          theme: atelierTheme(AppAccentTheme.jade, brightness),
          home: ConversationCollectionsPage(controller: controller),
        ),
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        if (find.byType(GlassContentCard).evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      final card = find.byType(GlassContentCard);
      expect(card, findsOneWidget);
      final surface = find.descendant(
        of: card,
        matching: find.byType(GlassSurface),
      );
      final widget = tester.widget<GlassSurface>(surface);
      expect(
        widget.tone,
        brightness == Brightness.light ? GlassTone.light : GlassTone.dark,
      );
      expect(
        widget.fallbackColor.computeLuminance(),
        brightness == Brightness.light ? greaterThan(.8) : lessThan(.1),
      );
      controller.setLiquidGlassChatUi(true);
      await tester.pumpAndSettle();
      expect(tester.widget<GlassSurface>(surface).liquidGlass, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'open collections page follows model scope without leaking cards',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const first = CharacterAppearance(
        id: 'collection_scope_a',
        label: '模型甲',
        description: '',
        promptDescription: '',
        assetName: 'collection_scope_a',
        animated: true,
        idleAnimations: [],
        live2dModelDirectory: 'test/collection-a',
        live2dModelFileName: 'a.model3.json',
      );
      const second = CharacterAppearance(
        id: 'collection_scope_b',
        label: '模型乙',
        description: '',
        promptDescription: '',
        assetName: 'collection_scope_b',
        animated: true,
        idleAnimations: [],
        live2dModelDirectory: 'test/collection-b',
        live2dModelFileName: 'b.model3.json',
      );
      characterAppearances.addAll([first, second]);
      addTearDown(
        () => characterAppearances.removeWhere(
          (appearance) => [first.id, second.id].contains(appearance.id),
        ),
      );
      late ModelPackageStore packages;
      final controller = (await tester.runAsync(() async {
        packages = ModelPackageStore.forTesting();
        await packages.initialize(storageDirectory: root);
        for (final model in [first, second]) {
          await packages.ensureModel(
            modelId: model.id,
            format: 'live2d',
            label: model.label,
            ownerCharacterId: model.characterId,
            files: {'model.json': Uint8List.fromList('{}'.codeUnits)},
          );
          final store = await ConversationCollectionStore.open(
            characterId: model.characterId,
            modelId: model.id,
          );
          await store.collect([
            {
              'key': model.id,
              'text': '${model.label}的专属内容',
              'isUser': true,
              'saveText': true,
              'saveVoice': false,
            },
          ], name: '${model.label}收藏');
        }
        final controller = await AppController.load(modelPackages: packages);
        await controller.setCharacterAppearance(first.id);
        return controller;
      }))!;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ConversationCollectionsPage(controller: controller)),
      );
      Future<void> waitForCard(String title) async {
        for (var attempt = 0; attempt < 40; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          if (find.text(title).evaluate().isNotEmpty) return;
        }
        expect(find.text(title), findsOneWidget);
      }

      await waitForCard('模型甲收藏');
      expect(find.text('模型乙收藏'), findsNothing);
      final stopsBeforeSwitch = audioMethods
          .where((method) => method == 'stop')
          .length;

      await tester.runAsync(() => controller.setCharacterAppearance(second.id));
      await tester.pump();
      expect(controller.activeCharacterId, first.characterId);
      expect(controller.activeModelId, second.id);
      expect(find.text('模型甲收藏'), findsNothing);
      await waitForCard('模型乙收藏');
      expect(find.byType(GlassContentCard), findsOneWidget);
      expect(
        audioMethods.where((method) => method == 'stop').length,
        greaterThan(stopsBeforeSwitch),
      );

      await tester.runAsync(() => controller.setCharacterAppearance(first.id));
      await tester.pump();
      expect(find.text('模型乙收藏'), findsNothing);
      await waitForCard('模型甲收藏');
      expect(find.byType(GlassContentCard), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(packages.flush);
    },
  );
}
