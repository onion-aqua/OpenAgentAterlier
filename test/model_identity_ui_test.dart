import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_avatar.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';
import 'package:ryza_chat_mvp/src/character_loading_indicator.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/local_skin_store.dart';
import 'package:ryza_chat_mvp/src/protected_character_assets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final requests = <String>[];
  final modelIds = <String>[];
  late Directory directory;
  late Uint8List orangePreview;
  late Uint8List bluePreview;

  Future<Uint8List> preview(Color color) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(color, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 2);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  Future<String> importPreview(Uint8List bytes) async {
    final archive = Archive();
    for (final entry in <String, List<int>>{
      'avatar.atlas': utf8.encode('avatar.png\nsize:2,2\n'),
      'avatar.png': bytes,
      'avatar_preview.png': bytes,
      'avatar.skel': [...List.filled(8, 0), 7, ...ascii.encode('4.2.43'), 0],
      'avatar_gesture.json': utf8.encode(
        '{"emotionalGesture":{"MotionGroups":[]}}',
      ),
    }.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    final record = await LocalSkinStore.instance.importPackage(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    final id = record['id']!;
    modelIds.add(id);
    characterAppearances.add(
      CharacterAppearance(
        id: id,
        label: 'Imported preview',
        description: '',
        promptDescription: '',
        assetName: id,
        animated: false,
        idleAnimations: const [],
      ),
    );
    return id;
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('model_identity_ui_');
    SharedPreferences.setMockInitialValues({});
    await LocalSkinStore.instance.initialize(storageDirectory: directory);
    orangePreview = await preview(Colors.orange);
    bluePreview = await preview(Colors.blue);
    await importPreview(orangePreview);
    await importPreview(bluePreview);
  });

  setUp(() {
    requests.clear();
    PaintingBinding.instance.imageCache.clear();
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final path = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      requests.add(path);
      if (path == 'AssetManifest.bin') {
        return const StandardMessageCodec().encodeMessage(<String, Object?>{});
      }
      return null;
    });
  });

  tearDownAll(() async {
    messenger.setMockMessageHandler('flutter/assets', null);
    LocalSkinStore.instance.skins.removeWhere(
      (record) => modelIds.contains(record['id']),
    );
    characterAppearances.removeWhere((model) => modelIds.contains(model.id));
    ProtectedCharacterAssets.clearCache();
    await directory.delete(recursive: true);
  });

  void expectNoLegacyAssets() {
    expect(
      requests.where(
        (path) =>
            path.contains('ryza') ||
            path.contains('sophie') ||
            path.contains('character_switch') ||
            path.endsWith('.gif') ||
            path.endsWith('.webp'),
      ),
      isEmpty,
    );
  }

  testWidgets(
    'same legacy owner uses each imported model preview independently',
    (tester) async {
      Future<void> show(String id, String name, Uint8List expected) async {
        expect(
          importedModelAppearances().map((model) => model.id),
          contains(id),
        );
        final loaded = await tester.runAsync(
          () => ProtectedCharacterAssets.previewFor(id),
        );
        expect(tester.takeException(), isNull);
        expect(loaded, orderedEquals(expected));
        await tester.pumpWidget(
          MaterialApp(
            home: CharacterAvatar(
              profile: characterRuntimeNeutralProfile(
                modelId: id,
                displayName: name,
              ),
              language: AppLanguage.chinese,
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(find.byType(FutureBuilder<Uint8List>), findsOneWidget);
        final image = tester.widget<Image>(find.byType(Image));
        expect(image.image, isA<MemoryImage>());
        expect((image.image as MemoryImage).bytes, orderedEquals(expected));
        expectNoLegacyAssets();
        expect(tester.takeException(), isNull);
      }

      expect(orangePreview, isNot(orderedEquals(bluePreview)));
      await show(modelIds.first, '橘', orangePreview);
      await show(modelIds.last, '星见', bluePreview);
      await show(modelIds.first, '橘改名', orangePreview);
    },
  );

  testWidgets('avatar initials and accessible names follow model identity', (
    tester,
  ) async {
    const first = CharacterAppearance(
      id: 'initials_one',
      label: '橘',
      description: '',
      promptDescription: '',
      assetName: 'initials_one',
      animated: true,
      idleAnimations: [],
      hasPreview: false,
      live2dModelDirectory: 'test/one',
    );
    const second = CharacterAppearance(
      id: 'initials_two',
      label: '星见',
      description: '',
      promptDescription: '',
      assetName: 'initials_two',
      animated: true,
      idleAnimations: [],
      hasPreview: false,
      live2dModelDirectory: 'test/two',
    );
    characterAppearances.addAll([first, second]);
    addTearDown(
      () => characterAppearances.removeWhere(
        (appearance) => [first.id, second.id].contains(appearance.id),
      ),
    );
    final semantics = tester.ensureSemantics();
    for (final (model, name, initial) in [
      (first, '橘', '橘'),
      (second, '星见', '星'),
      (first, '新名字', '新'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: CharacterAvatar(
            profile: characterRuntimeNeutralProfile(
              modelId: model.id,
              displayName: name,
            ),
            language: AppLanguage.chinese,
          ),
        ),
      );
      expect(find.bySemanticsLabel(RegExp('^$name')), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('character-avatar-initial')),
            )
            .data,
        initial,
      );
      expect(find.byType(Image), findsNothing);
    }
    expectNoLegacyAssets();
    semantics.dispose();
  });

  testWidgets('unbound and legacy profiles never request bundled portraits', (
    tester,
  ) async {
    for (final profile in [
      characterRuntimeNeutralProfile(),
      characterRuntimeNeutralProfile(legacyId: 'sophie'),
      characterRuntimeProfileById('ryza'),
      characterRuntimeProfileById('sophie'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: CharacterAvatar(
            profile: profile,
            language: AppLanguage.chinese,
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
    }
    expectNoLegacyAssets();
  });

  testWidgets(
    'loading panel shows current model and never loads old animation',
    (tester) async {
      for (final name in ['橘', '星见', '']) {
        await tester.pumpWidget(
          MaterialApp(
            home: CharacterLoadingPanel(
              language: AppLanguage.chinese,
              characterName: name,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.text(name.isEmpty ? '加载中…' : '正在加载$name…'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      }
      expectNoLegacyAssets();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('character camera announces the supplied model name', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: CharacterCamera(
          semanticLabel: '橘，点击触发互动',
          onTap: (_) {},
          child: const SizedBox.expand(),
        ),
      ),
    );
    expect(find.bySemanticsLabel('橘，点击触发互动'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('莱莎|苏菲')), findsNothing);
    expectNoLegacyAssets();
    semantics.dispose();
  });
}
