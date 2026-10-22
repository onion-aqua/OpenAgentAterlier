import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/alchemy_screen.dart';
import 'package:ryza_chat_mvp/src/appearance_picker_page.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_avatar.dart';
import 'package:ryza_chat_mvp/src/character_spine_view.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/local_live2d_store.dart';
import 'package:ryza_chat_mvp/src/local_scene_store.dart';
import 'package:ryza_chat_mvp/src/local_skin_store.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:ryza_chat_mvp/src/mission_screen.dart';
import 'package:ryza_chat_mvp/src/protected_character_assets.dart';
import 'package:ryza_chat_mvp/src/skin_import_controls.dart';
import 'package:ryza_chat_mvp/src/shop_screen.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';
import 'package:ryza_chat_mvp/src/world_map_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

/// Uses the real ChatScreen and phone routes. Only OS audio/storage bridges
/// and the few unrelated UI images are fixtures; no character model is loaded.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final audioChannels = <String>{
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
    'agent_atelier_r/companion_runtime/events',
  };
  late Directory support;
  final images = <String, ByteData>{};
  final assetRequests = <String>[];

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('aar_no_model_screen_');
    SharedPreferences.setMockInitialValues({});
    await LocalSkinStore.instance.initialize(storageDirectory: support);
    await LocalLive2dStore.instance.initialize(storageDirectory: support);
    await LocalSceneStore.instance.initialize(storageDirectory: support);
    messenger.setMockMethodCallHandler(pathProvider, (_) async => support.path);
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final channel = 'xyz.luan/audioplayers/events/$id';
          audioChannels.add(channel);
          messenger.setMockMethodCallHandler(
            MethodChannel(channel),
            (_) async => null,
          );
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('agent_atelier_r/companion_runtime'),
      (_) async => {
        'running': true,
        'starting': false,
        'stopRequested': false,
        'muted': false,
      },
    );
    for (final path in [
      'assets/images/virtual_phone/bg1.png',
      'assets/images/virtual_phone/dynamic_island.png',
      'assets/images/virtual_phone/signal_0.png',
      'assets/images/virtual_phone/signal_4.png',
      'assets/images/virtual_phone/battery_5.png',
    ]) {
      images[path] = ByteData.sublistView(await File(path).readAsBytes());
    }
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final path = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      assetRequests.add(path);
      if (path == 'AssetManifest.bin') {
        return const StandardMessageCodec().encodeMessage(<String, Object?>{});
      }
      final jsonFixture = switch (path) {
        'assets/data/runtime_prompts.json' => '{"characters":{}}',
        'assets/world_map/npc_placement.json' => '{"npcs":[]}',
        'assets/world_map/world_hierarchy.json' => '{"areas":[]}',
        _ => null,
      };
      if (jsonFixture != null) {
        return ByteData.sublistView(
          Uint8List.fromList(utf8.encode(jsonFixture)),
        );
      }
      return images[path];
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
      'ai_enabled': false,
      'fish_tts_enabled': false,
      'liquid_glass_chat_ui': false,
    });
    assetRequests.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDownAll(() async {
    messenger.setMockMessageHandler('flutter/assets', null);
    messenger.setMockMethodCallHandler(pathProvider, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('agent_atelier_r/companion_runtime'),
      null,
    );
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    await ModelPackageStore.instance.flush();
    await support.delete(recursive: true);
  });

  Future<(AppController, ValueNotifier<bool>)> mount(
    WidgetTester tester, {
    String? modelId,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.reset);
    final controller = (await tester.runAsync(() => AppController.load()))!;
    if (modelId != null) {
      await tester.runAsync(() => controller.setCharacterAppearance(modelId));
      await tester.runAsync(
        () => ProtectedCharacterAssets.bundleFor(
          modelId,
          characterId: controller.activeCharacterId,
        ),
      );
    }
    // Static test previews isolate route/UI behavior from native rig startup.
    final ready = ValueNotifier(modelId != null);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(controller.flushModelSession);
      controller.dispose();
      ready.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: ready,
          builder: (context, isReady, _) => Stack(
            fit: StackFit.expand,
            children: [
              AnimatedBuilder(
                animation: controller,
                builder: (context, _) => ChatScreen(
                  controller: controller,
                  onMenuPressed: () {},
                  onShopPressed: () {},
                  hideUi: false,
                  onCharacterReady: () => ready.value = true,
                ),
              ),
              if (!isReady)
                const Positioned.fill(
                  child: AbsorbPointer(
                    key: ValueKey('startup-gate'),
                    child: ColoredBox(color: Colors.black),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return (controller, ready);
  }

  void expectNoModelRuntime(WidgetTester tester) {
    expect(find.byType(SpineWidget), findsNothing);
    expect(find.byType(CharacterSpineView), findsNothing);
    expect(
      assetRequests.where(
        (path) =>
            path.endsWith('.skel') ||
            path.endsWith('.atlas') ||
            path.contains('/protected/') ||
            path.contains('/character_switch/') ||
            path.contains('sophie_portrait') ||
            path.contains('ryza_loading') ||
            path.contains('/world_map/') && path.endsWith('.png'),
      ),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  }

  Future<String> staticModel(
    WidgetTester tester, {
    required String name,
  }) async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lS8AAAAASUVORK5CYII=',
    );
    final archive = Archive();
    for (final entry in <String, List<int>>{
      'custom.atlas': utf8.encode('custom.png\nsize:1,1\n'),
      'custom.png': png,
      'custom_preview.png': png,
      'custom.skel': [...List.filled(8, 0), 7, ...ascii.encode('4.2.43'), 0],
      'custom_gesture.json': utf8.encode(
        '{"emotionalGesture":{"MotionGroups":[]}}',
      ),
    }.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    final record = (await tester.runAsync(
      () => LocalSkinStore.instance.importPackage(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      ),
    ))!;
    final id = record['id']!;
    await tester.runAsync(() async {
      await ProtectedCharacterAssets.bundleFor(id);
      await ProtectedCharacterAssets.previewFor(id);
    });
    // A user-imported static preview exercises identity and phone routes
    // without handing a deliberately minimal skeleton to the native renderer.
    characterAppearances.add(
      CharacterAppearance(
        id: id,
        label: name,
        description: 'UI test model',
        promptDescription: '',
        assetName: id,
        animated: false,
        idleAnimations: const [],
      ),
    );
    addTearDown(() {
      LocalSkinStore.instance.skins.removeWhere((record) => record['id'] == id);
      characterAppearances.removeWhere((appearance) => appearance.id == id);
      ProtectedCharacterAssets.clearCache();
    });
    return id;
  }

  Future<void> openPhone(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> expectWorldAppsUnconfigured(
    WidgetTester tester,
    String name,
  ) async {
    await openPhone(tester);
    for (final app in [
      VirtualPhoneApp.shop,
      VirtualPhoneApp.worldMap,
      VirtualPhoneApp.alchemy,
      VirtualPhoneApp.missions,
    ]) {
      await tester.tap(find.byKey(ValueKey('virtual-phone-app-${app.name}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
      final placeholder = find.byKey(
        ValueKey('model-world-unconfigured-${app.name}'),
      );
      expect(placeholder, findsOneWidget);
      expect(tester.widget<Text>(placeholder).data, contains(name));
      expect(find.byType(ShopScreen), findsNothing);
      expect(find.byType(WorldMapScreen), findsNothing);
      expect(find.byType(AlchemyScreen), findsNothing);
      expect(find.byType(MissionScreen), findsNothing);
      for (final leaked in ['莱莎', '苏菲', '库肯岛', '给莱莎的礼物', '和好券']) {
        expect(find.textContaining(leaked), findsNothing);
      }
      expectNoModelRuntime(tester);
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
    }
  }

  testWidgets('no model releases the startup gate and still sends demo chat', (
    tester,
  ) async {
    final (controller, ready) = await mount(tester);
    expect(ready.value, isTrue);
    expect(find.byKey(const ValueKey('startup-gate')), findsNothing);
    expect(
      find.byKey(const ValueKey('character-model-import-placeholder')),
      findsOneWidget,
    );
    expect(controller.aiEnabled, isFalse);
    expectNoModelRuntime(tester);
    final before = controller.messages.length;
    final input = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '和当前角色说点什么…',
    );
    await tester.enterText(input, '没有模型也能聊天吗');
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump();
    expect(
      controller.messages.where((message) => message.isUser).last.text,
      '发言：没有模型也能聊天吗',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(controller.messages, hasLength(before + 2));
    expect(controller.messages.last.isUser, isFalse);
    expectNoModelRuntime(tester);
  });

  testWidgets(
    'legacy storage owner starts with a neutral, model-free identity',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'active_character_id_v1': 'ryza',
        'ai_enabled': false,
        'fish_tts_enabled': false,
      });
      final (controller, ready) = await mount(tester);
      expect(controller.activeCharacterId, 'ryza');
      expect(controller.selectedCharacterAppearanceId, 'no_model');
      expect(ready.value, isTrue);
      expect(find.byKey(const ValueKey('startup-gate')), findsNothing);
      expect(
        find.byKey(const ValueKey('character-model-import-placeholder')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == '和当前角色说点什么…',
        ),
        findsOneWidget,
      );
      expectNoModelRuntime(tester);
    },
  );

  testWidgets('main import button opens the real resource type chooser', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.widgetWithText(FilledButton, '导入模型'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.byType(SkinImportControls), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-outfit-zip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(find.text('导入资源'), findsOneWidget);
    expect(find.text('Live2D · Cubism model3'), findsOneWidget);
    expect(find.text('Spine · AI 映射'), findsOneWidget);
    expect(find.text('场景 / 座椅 Spine 包'), findsOneWidget);
    expectNoModelRuntime(tester);
  });

  testWidgets('unbound phone world apps never open legacy world or shop data', (
    tester,
  ) async {
    await mount(tester);
    await expectWorldAppsUnconfigured(tester, '当前角色');
  });

  testWidgets('imported model phone apps use its own unconfigured world', (
    tester,
  ) async {
    final id = await staticModel(tester, name: '橘');
    final (controller, _) = await mount(tester, modelId: id);
    expect(controller.activeModelId, id);
    expect(controller.activeCharacterId, 'ryza');
    expect(controller.usesBuiltInCharacterWorld, isFalse);
    await expectWorldAppsUnconfigured(tester, '橘');
  });

  testWidgets(
    'same-owner model switches and rename refresh historical speaker names',
    (tester) async {
      final first = await staticModel(tester, name: '橘');
      final second = await staticModel(tester, name: '星见');
      final (controller, _) = await mount(tester, modelId: first);
      await tester.runAsync(() async {
        controller.addAssistantMessage('主角：这是橘的聊天记录。');
        await controller.flushModelSession();
      });
      await tester.pump();
      expect(find.text('橘'), findsWidgets);
      expect(
        tester
            .widgetList<CharacterAvatar>(find.byType(CharacterAvatar))
            .every((avatar) => avatar.profile.names.chinese == '橘'),
        isTrue,
      );
      await tester.runAsync(() => controller.setCharacterAppearance(second));
      await tester.runAsync(() async {
        controller.addAssistantMessage('主角：这是星见的聊天记录。');
        await controller.flushModelSession();
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('星见'), findsWidgets);
      expect(find.text('橘'), findsNothing);
      expect(find.textContaining('这是橘的聊天记录'), findsNothing);
      final avatars = tester.widgetList<CharacterAvatar>(
        find.byType(CharacterAvatar),
      );
      expect(avatars, isNotEmpty);
      expect(
        avatars.every((avatar) => avatar.profile.names.chinese == '星见'),
        isTrue,
      );
      await tester.runAsync(() => controller.setModelDisplayName('星见改名'));
      await tester.pump();
      expect(find.text('星见改名'), findsWidgets);
      expect(find.text('星见'), findsNothing);
      expectNoModelRuntime(tester);
    },
  );

  testWidgets('virtual phone empty outfits page keeps a usable import card', (
    tester,
  ) async {
    await mount(tester);
    expect(importedCharacterAppearances('sophie'), isEmpty);
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-outfit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byType(AppearancePickerPage), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
    final importCard = find.byKey(const ValueKey('import-outfit-zip'));
    expect(importCard.hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('outfit-equip-button')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(importCard);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('导入资源'), findsOneWidget);
    expectNoModelRuntime(tester);
  });

  testWidgets('a Sophie texture card loads its own character bundle', (
    tester,
  ) async {
    final store = LocalSkinStore.instance;
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lS8AAAAASUVORK5CYII=',
    );
    final archive = Archive();
    final files = <String, List<int>>{
      'custom.atlas': utf8.encode('custom.png\nsize:1,1\n'),
      'custom.png': png,
      'custom.skel': [...List.filled(8, 0), 7, ...ascii.encode('4.2.43'), 0],
      'custom_gesture.json': utf8.encode(
        '{"emotionalGesture":{"MotionGroups":[]}}',
      ),
    };
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    final record = await tester.runAsync(() async {
      final record = await store.importPackage(
        Uint8List.fromList(ZipEncoder().encode(archive)),
        characterId: 'sophie',
      );
      await store.importTexture(record['id']!, png, png);
      return record;
    });
    final id = record!['id']!;
    addTearDown(() {
      store.skins.removeWhere((record) => record['id'] == id);
      characterAppearances.removeWhere((appearance) => appearance.id == id);
      ProtectedCharacterAssets.clearCache();
    });
    registerLocalSkinAppearances();
    late Future<ProtectedCharacterAssetBundle> expectedFuture;
    final bundle = await tester.runAsync(() {
      expectedFuture = ProtectedCharacterAssets.bundleFor(
        id,
        characterId: 'sophie',
      );
      return expectedFuture;
    });
    await mount(tester);
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-outfit')));
    await tester.pump();
    final preview = tester.widget<FutureBuilder<ProtectedCharacterAssetBundle>>(
      find.byType(FutureBuilder<ProtectedCharacterAssetBundle>),
    );
    // The actual phone card must reuse Sophie's cached loader, never the
    // default Ryza namespace. Stop before rendering the header-only test rig.
    expect(preview.future, same(expectedFuture));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      await bundle!.load('assets/character/sophie/$id/$id.skel'),
      isA<ByteData>(),
    );
    await expectLater(
      bundle.load('assets/character/ryza/$id/$id.skel'),
      throwsFlutterError,
    );
    expect(tester.takeException(), isNull);
  });
}
