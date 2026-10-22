import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/local_live2d_store.dart';
import 'package:ryza_chat_mvp/src/local_skin_store.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late List<CharacterAppearance> originalAppearances;
  final skinStore = LocalSkinStore.instance;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'aar_appearance_registry_',
    );
    SharedPreferences.setMockInitialValues({});
    await skinStore.initialize(storageDirectory: directory);
    await LocalLive2dStore.instance.initialize(storageDirectory: directory);
    originalAppearances = [...characterAppearances];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProvider,
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? directory.path
              : null,
        );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
    });
    skinStore.skins.clear();
    characterAppearances
      ..clear()
      ..addAll(originalAppearances);
  });

  tearDownAll(() async {
    skinStore.skins.clear();
    characterAppearances
      ..clear()
      ..addAll(originalAppearances);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await directory.delete(recursive: true);
  });

  test('an explicit control template wins over a conflicting known base', () {
    skinStore.skins.add({
      'id': 'local_explicit_standing',
      'base': 'crf_skn_002_0001_01',
      'templateId': 'standing_99',
      'characterId': 'sophie',
      'label': 'Imported standing model',
    });
    registerLocalSkinAppearances();
    final appearance = characterAppearanceById(
      'local_explicit_standing',
      characterId: 'sophie',
    );
    expect(appearance.baseAppearanceId, 'standing_99');
    expect(appearance.isStanding, isTrue);
    expect(appearance.characterId, 'sophie');
    expect(
      appearance.assetRoot,
      'assets/character/sophie/local_explicit_standing',
    );
    expect(appearance.hasImportedSpine, isTrue);
    expect(
      appearance.idleAnimations,
      characterAppearanceById('standing_99').idleAnimations,
    );
  });

  test(
    'known bases retain their template when none was explicitly selected',
    () {
      skinStore.skins.add({
        'id': 'local_automatic_summer',
        'base': 'crf_skn_002_0002_01',
        'characterId': 'ryza',
        'label': 'Imported seated model',
      });
      registerLocalSkinAppearances();
      final appearance = characterAppearanceById('local_automatic_summer');
      expect(appearance.baseAppearanceId, 'summer_yellow_01');
      expect(appearance.isStanding, isFalse);
      expect(
        importedCharacterAppearances('ryza').map((item) => item.id),
        contains(appearance.id),
      );
      expect(
        importedCharacterAppearances('sophie').map((item) => item.id),
        isNot(contains(appearance.id)),
      );
    },
  );

  test('mapped Spine appearance uses declared runtime metadata', () {
    skinStore.skins.add({
      'id': 'local_mapped_json',
      'spineVersion': '3.6.53',
      'base': 'data',
      'characterId': 'sophie',
      'label': 'Mapped model',
      'skeletonExtension': 'json',
      'rigProfile': 'generic_spine',
      'posture': 'mapped',
      'idleAnimations': jsonEncode(['wait', 'wait1']),
    });
    registerLocalSkinAppearances();
    final appearance = characterAppearanceById(
      'local_mapped_json',
      characterId: 'sophie',
    );
    expect(appearance.rigProfile, 'generic_spine');
    expect(appearance.spineVersion, '3.6.53');
    expect(appearance.posture, 'mapped');
    expect(appearance.skeletonExtension, 'json');
    expect(appearance.skeletonAsset, endsWith('/local_mapped_json.json'));
    expect(appearance.idleAnimations, ['wait', 'wait1']);
    expect(appearance.baseAppearanceId, isNull);
    expect(appearance.isStanding, isFalse);
  });

  test(
    'missing and foreign IDs produce an isolated placeholder with the same ID',
    () {
      for (final (id, characterId) in [
        ('local_missing_after_restore', 'ryza'),
        ('local_missing_after_restore', 'sophie'),
        ('seated_01', 'sophie'),
      ]) {
        final appearance = characterAppearanceById(
          id,
          characterId: characterId,
        );
        expect(appearance.id, id);
        expect(appearance.characterId, characterId);
        expect(appearance.hasImportedSpine, isFalse);
        expect(appearance.isLive2d, isFalse);
        expect(appearance.animated, isFalse);
        expect(appearance.idleAnimations, isEmpty);
      }
      // Template rows are not model resources until a ZIP has been imported.
      expect(importedCharacterAppearances('ryza'), isEmpty);
      expect(characterAppearanceById('seated_01').hasImportedSpine, isFalse);
    },
  );

  test(
    'unified model selection rejects unknown IDs and accepts every old owner',
    () async {
      skinStore.skins.addAll([
        {
          'id': 'local_ryza_only',
          'base': 'ryza_custom',
          'characterId': 'ryza',
          'label': 'Ryza',
        },
        {
          'id': 'local_sophie_only',
          'base': 'sophie_custom',
          'characterId': 'sophie',
          'label': 'Sophie',
        },
      ]);
      for (final (id, owner) in [
        ('local_ryza_only', 'ryza'),
        ('local_sophie_only', 'sophie'),
      ]) {
        await ModelPackageStore.instance.ensureModel(
          modelId: id,
          format: 'spine',
          label: id,
          ownerCharacterId: owner,
          files: {'model.json': Uint8List.fromList(utf8.encode('{}'))},
        );
      }
      registerLocalSkinAppearances();
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      expect(controller.activeCharacterId, 'sophie');
      final previous = controller.selectedCharacterAppearanceId;
      await controller.setCharacterAppearance('local_unknown');
      expect(controller.selectedCharacterAppearanceId, previous);
      await controller.setCharacterAppearance('local_ryza_only');
      expect(controller.selectedCharacterAppearanceId, 'local_ryza_only');
      expect(controller.activeModelId, 'local_ryza_only');
      expect(controller.activeCharacterId, 'ryza');
      await controller.setCharacterAppearance('local_sophie_only');
      expect(controller.selectedCharacterAppearanceId, 'local_sophie_only');
      expect(controller.activeModelId, 'local_sophie_only');
      expect(controller.activeCharacterId, 'sophie');
    },
  );

  test(
    'registered Live2D models keep their owner and entry directory',
    () async {
      final model = {
        'Version': 3,
        'FileReferences': {
          'Moc': 'sample.moc3',
          'Textures': ['texture.png'],
        },
      };
      final files = <String, List<int>>{
        'nested/sample.model3.json': utf8.encode(jsonEncode(model)),
        'nested/sample.moc3': [1, 2, 3],
        'nested/texture.png': [1, 2, 3],
      };
      final archive = Archive();
      for (final entry in files.entries) {
        archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
      }
      final imported = await LocalLive2dStore.instance.importPackage(
        Uint8List.fromList(ZipEncoder().encode(archive)),
        characterId: 'sophie',
      );
      registerLocalSkinAppearances();
      final appearance = characterAppearanceById(
        imported.id,
        characterId: 'sophie',
      );
      expect(appearance.isLive2d, isTrue);
      expect(appearance.hasImportedSpine, isFalse);
      expect(appearance.live2dModelDirectory, imported.directory);
      expect(appearance.live2dModelFileName, 'sample.model3.json');
      expect(
        importedCharacterAppearances('sophie').map((item) => item.id),
        contains(imported.id),
      );
      final foreign = characterAppearanceById(imported.id, characterId: 'ryza');
      expect(foreign.id, imported.id);
      expect(foreign.isLive2d, isFalse);
      expect(foreign.live2dModelDirectory, isNull);
    },
  );
}
