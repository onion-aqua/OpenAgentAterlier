import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/local_skin_store.dart';
import 'package:ryza_chat_mvp/src/model_mapping_persistence.dart';
import 'package:ryza_chat_mvp/src/model_performance_mapping.dart';
import 'package:ryza_chat_mvp/src/model_resource_catalog.dart';
import 'package:ryza_chat_mvp/src/protected_character_assets.dart';
import 'package:ryza_chat_mvp/src/spine_control_templates.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _png(int width, int height) {
  final bytes = Uint8List(33);
  bytes.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
  bytes.setAll(12, ascii.encode('IHDR'));
  ByteData.sublistView(bytes)
    ..setUint32(16, width)
    ..setUint32(20, height);
  return bytes;
}

Uint8List _zip({
  String base = 'custom_rig',
  bool gesture = true,
  bool preview = false,
  bool invalidSkeleton = false,
  bool mismatchedAtlas = false,
  String prefix = 'model/',
}) {
  final archive = Archive();
  void add(String name, List<int> bytes) =>
      archive.addFile(ArchiveFile('$prefix$name', bytes.length, bytes));
  add(
    '$base.atlas',
    utf8.encode('$base.png\nsize:${mismatchedAtlas ? 3 : 2},3\n'),
  );
  add('$base.png', _png(2, 3));
  add('$base.skel', [
    ...List.filled(8, 0),
    7,
    ...ascii.encode(invalidSkeleton ? '4.1.43' : '4.2.43'),
    0,
  ]);
  if (gesture) {
    add(
      '${base}_gesture.json',
      utf8.encode('{"emotionalGesture":{"MotionGroups":[]},"custom":true}'),
    );
  }
  if (preview) add('preview.png', _png(4, 5));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _jsonZip({String version = '4.2.43', bool includeBinary = false}) {
  final archive = Archive();
  void add(String name, List<int> bytes) =>
      archive.addFile(ArchiveFile('nested/$name', bytes.length, bytes));
  add('json_rig.atlas', utf8.encode('json_rig.png\nsize:2,3\n'));
  add('json_rig.png', _png(2, 3));
  add(
    'json_rig.json',
    utf8.encode(
      jsonEncode({
        'skeleton': {'spine': version},
        'bones': [
          {'name': 'root'},
        ],
        'slots': [],
        'skins': [],
        'animations': {'wait': {}},
      }),
    ),
  );
  if (includeBinary) {
    add('json_rig.skel', [
      ...List.filled(8, 0),
      7,
      ...ascii.encode('4.2.43'),
      0,
    ]);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _mappedGesture() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'emotionalGesture': {
        'MotionGroups': [
          {'GroupId': 'wave', 'AnimName_1': 'hello', 'OccupancyLetters': 'B'},
        ],
      },
      'ModelMapping.Runtime': {
        'idleAnimations': ['wait'],
        'posture': 'mapped',
        'rigProfile': 'generic_spine',
        'actions': {'wave': 'hello'},
        'expressions': {'happy': 'face_smile'},
        'parameters': {'mouthOpen': 'lip_smile'},
      },
    }),
  ),
);

Future<Uint8List> _performanceMapping(Uint8List source) async {
  final digest = (await Sha256().hash(source)).bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'sourceFingerprint': digest,
        'format': 'spine',
        'label': 'Mapped JSON rig',
        'idle': 'motion:wait',
        'actions': {
          'wave': {
            'target': 'motion:hello',
            'description': 'wave',
            'confidence': .98,
            'evidence': 'catalog',
          },
        },
        'expressions': {},
        'parameters': {},
        'notes': <String>[],
      }),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProtectedCharacterAssets.clearCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final key = utf8.decode(
            message!.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          if (!key.startsWith('assets/data/spine_templates/')) return null;
          final bytes = await File(key).readAsBytes();
          return ByteData.sublistView(bytes);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    ProtectedCharacterAssets.clearCache();
  });

  test(
    'all seven templates retain controls without embedded model paths',
    () async {
      expect(SpineControlTemplates.all.map((template) => template.id), [
        'seated_01',
        'standing_99',
        'summer_yellow_01',
        'summer_black_01',
        'relaxed_shirt_01',
        'crf_skn_002_0005_01',
        'crf_skn_002_0006_01',
      ]);
      for (final template in SpineControlTemplates.all) {
        expect(
          SpineControlTemplates.templateForBase(template.sourceBase),
          template,
        );
        final json = jsonDecode(
          utf8.decode(await SpineControlTemplates.read(template.id)),
        ) as Map;
        expect(json.containsKey('atlasPath'), isFalse);
        expect(json.containsKey('skeletonPath'), isFalse);
        expect(json['rigConfig'], isA<Map>());
        expect(json['emotionalGesture']['MotionGroups'], isNotEmpty);
        expect(json['emotionalGesture']['EmotionProfilesV4'], isA<Map>());
      }
      expect(SpineControlTemplates.templateForBase('unknown'), isNull);
      await expectLater(
        SpineControlTemplates.read('../unknown'),
        throwsFormatException,
      );
    },
  );

  test(
    'prepare resolves a known rig without saving or requiring a gesture',
    () async {
      final store = LocalSkinStore.forTesting();
      final files = await store.preparePackage(
        _zip(base: 'crf_skn_002_0001_01', gesture: false),
      );
      expect(files, hasLength(4));
      final gesture = jsonDecode(
        utf8.decode(files['crf_skn_002_0001_01_gesture.json']!),
      ) as Map;
      expect(gesture['emotionalGesture']['MotionGroups'], isNotEmpty);
      expect(store.skins, isEmpty);
      await expectLater(
        store.preparePackage(_zip(gesture: false)),
        throwsFormatException,
      );
    },
  );

  test(
    'custom mapping wins unless the user explicitly chooses a template',
    () async {
      final store = LocalSkinStore.forTesting();
      final own = await store.preparePackage(_zip(base: 'crf_skn_002_0001_01'));
      final ownGesture = jsonDecode(
        utf8.decode(own['crf_skn_002_0001_01_gesture.json']!),
      ) as Map;
      expect(ownGesture['custom'], isTrue);
      expect(ownGesture['emotionalGesture']['MotionGroups'], isEmpty);
      expect(ownGesture['emotionalGesture']['DriverDefs'], isNotEmpty);
      final selected = await store.preparePackage(
        _zip(gesture: false),
        templateId: 'standing_99',
      );
      expect(
        jsonDecode(
          utf8.decode(selected['custom_rig_gesture.json']!),
        )['emotionalGesture']['MotionGroups'],
        isNotEmpty,
      );
      final overridden = await store.preparePackage(
        _zip(),
        templateId: 'seated_01',
      );
      expect(
        jsonDecode(
          utf8.decode(overridden['custom_rig_gesture.json']!),
        )['custom'],
        isNull,
      );
      await expectLater(
        store.preparePackage(_zip(), templateId: 'not-a-template'),
        throwsFormatException,
      );
    },
  );

  test('known base can preserve its complete trusted template with mapped evidence', () async {
    const base = 'crf_skn_002_0001_01';
    final source = _zip(base: base);
    final mappingBytes = await _performanceMapping(source);
    final trusted = jsonDecode(
      utf8.decode(await SpineControlTemplates.read('seated_01')),
    ) as Map;
    final store = LocalSkinStore.forTesting();

    final prepared = await store.preparePackage(
      source,
      performanceMapping: mappingBytes,
      preserveCompatibleTemplate: true,
    );
    final gesture =
        jsonDecode(utf8.decode(prepared['${base}_gesture.json']!)) as Map;
    final actualPerformance = gesture['emotionalGesture'] as Map;
    final trustedPerformance = trusted['emotionalGesture'] as Map;
    expect(
      actualPerformance['MotionGroups'],
      trustedPerformance['MotionGroups'],
    );
    expect(actualPerformance['DriverDefs'], trustedPerformance['DriverDefs']);
    expect(actualPerformance['MotionGroups'], isNotEmpty);
    expect(actualPerformance['DriverDefs'], isNotEmpty);
    expect(prepared[importedPerformanceMappingFileName], mappingBytes);

    final directory = await Directory.systemTemp.createTemp(
      'aar_preserved_template_',
    );
    addTearDown(() => directory.delete(recursive: true));
    await store.initialize(storageDirectory: directory);
    final record = await store.importPackage(
      source,
      performanceMapping: mappingBytes,
      preserveCompatibleTemplate: true,
    );
    final mapping = jsonDecode(utf8.decode(mappingBytes)) as Map;
    expect(record['templateId'], 'seated_01');
    expect(record['rigProfile'], 'ryza');
    expect(record['sourceFingerprint'], mapping['sourceFingerprint']);
    final saved = (await store.filesFor(record['id']!))!;
    expect(
      saved.keys,
      contains(
        'assets/character/ryza/${record['id']}/performance.mapping.json',
      ),
    );
    final restored = LocalSkinStore.forTesting();
    await restored.initialize(storageDirectory: directory);
    expect(restored.skins.single['templateId'], 'seated_01');
    expect(restored.skins.single['rigProfile'], 'ryza');
    expect(
      restored.skins.single['sourceFingerprint'],
      mapping['sourceFingerprint'],
    );
  });

  test('preserved template mode rejects every non-exact invocation', () async {
    final store = LocalSkinStore.forTesting();
    final known = _zip(base: 'crf_skn_002_0001_01');
    final knownMapping = await _performanceMapping(known);
    final unknown = _zip(base: 'unknown_rig');

    await expectLater(
      store.preparePackage(
        unknown,
        performanceMapping: await _performanceMapping(unknown),
        preserveCompatibleTemplate: true,
      ),
      throwsFormatException,
    );
    final directory = await Directory.systemTemp.createTemp(
      'aar_unknown_preserved_template_',
    );
    addTearDown(() => directory.delete(recursive: true));
    await store.initialize(storageDirectory: directory);
    await expectLater(
      store.importPackage(
        unknown,
        performanceMapping: await _performanceMapping(unknown),
        preserveCompatibleTemplate: true,
      ),
      throwsFormatException,
    );
    expect(store.skins, isEmpty);
    await expectLater(
      store.preparePackage(known, preserveCompatibleTemplate: true),
      throwsFormatException,
    );
    await expectLater(
      store.preparePackage(
        known,
        gestureMapping: _mappedGesture(),
        performanceMapping: knownMapping,
        preserveCompatibleTemplate: true,
      ),
      throwsFormatException,
    );
    await expectLater(
      store.preparePackage(
        known,
        templateId: 'standing_99',
        performanceMapping: knownMapping,
        preserveCompatibleTemplate: true,
      ),
      throwsFormatException,
    );
  });

  test(
    'selecting a template preserves atlas, version and ZIP safety checks',
    () async {
      final store = LocalSkinStore.forTesting();
      for (final bytes in [
        _zip(gesture: false, invalidSkeleton: true),
        _zip(gesture: false, mismatchedAtlas: true),
        _zip(gesture: false, prefix: '../'),
      ]) {
        await expectLater(
          store.preparePackage(bytes, templateId: 'seated_01'),
          throwsFormatException,
        );
      }
    },
  );

  test('accepts exactly one Spine 4.2 JSON skeleton', () async {
    final files = decodeSkinZip(_jsonZip(), gestureTemplate: _mappedGesture());
    expect(files.keys, contains('json_rig.json'));
    expect(files.keys, isNot(contains('json_rig.skel')));
    expect(
      () => decodeSkinZip(
        _jsonZip(includeBinary: true),
        gestureTemplate: _mappedGesture(),
      ),
      throwsFormatException,
    );
  });

  test('accepts unchanged Spine 3.6 JSON for the legacy player', () {
    final files = decodeSkinZip(
      _jsonZip(version: '3.6.53'),
      gestureTemplate: _mappedGesture(),
    );
    expect(
      jsonDecode(utf8.decode(files['json_rig.json']!))['skeleton']['spine'],
      '3.6.53',
    );
  });

  test(
    'mapped JSON skeleton metadata and original mapping survive restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aar_json_mapping_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = _jsonZip(version: '3.6.53');
      final catalog = await inspectModelResources(
        source,
        format: ModelResourceFormat.spine,
      );
      final mapping = ModelPerformanceMapping.fromJson({
        'schemaVersion': 1,
        'sourceFingerprint': catalog.sourceFingerprint,
        'format': 'spine',
        'label': 'Mapped JSON rig',
        'idle': 'animation:wait',
        'actions': <String, Object?>{},
        'expressions': <String, Object?>{},
        'parameters': <String, Object?>{},
        'notes': <String>[],
      }, catalog: catalog);
      final gestureBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(mapping.toSpineGesture(catalog))),
      );
      final mappingBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(mapping.toJson())),
      );
      final store = LocalSkinStore.forTesting();
      await store.initialize(storageDirectory: directory);
      final record = await store.importPackage(
        source,
        characterId: 'sophie',
        gestureMapping: gestureBytes,
        performanceMapping: mappingBytes,
      );
      expect(record['skeletonExtension'], 'json');
      expect(record['spineVersion'], '3.6.53');
      expect(record['rigProfile'], 'generic_spine');
      expect(record['posture'], 'mapped');
      expect(jsonDecode(record['idleAnimations']!), ['wait']);
      expect(record['label'], 'Mapped JSON rig');
      final id = record['id']!;
      final bundle = (await store.filesFor(id, characterId: 'sophie'))!;
      expect(
        bundle.keys,
        containsAll([
          'assets/character/sophie/$id/$id.json',
          'assets/character/sophie/$id/performance.mapping.json',
        ]),
      );
      expect(bundle.keys, everyElement(isNot(endsWith('$id.skel'))));

      final restored = LocalSkinStore.forTesting();
      await restored.initialize(storageDirectory: directory);
      expect(restored.skins.single['skeletonExtension'], 'json');
      expect(restored.skins.single['spineVersion'], '3.6.53');
      expect(
        (await restored.filesFor(id, characterId: 'sophie'))!.keys,
        contains('assets/character/sophie/$id/$id.json'),
      );
    },
  );

  test('mapping fingerprint must match the complete source ZIP', () async {
    final source = _jsonZip();
    final mapping = jsonDecode(
      utf8.decode(await _performanceMapping(source)),
    ) as Map<String, dynamic>;
    mapping['sourceFingerprint'] = List.filled(64, '0').join();
    final store = LocalSkinStore.forTesting();
    await expectLater(
      store.preparePackage(
        source,
        gestureMapping: _mappedGesture(),
        performanceMapping: Uint8List.fromList(
          utf8.encode(jsonEncode(mapping)),
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'generated Spine runtime must carry the same source fingerprint',
    () async {
      final source = _jsonZip();
      final catalog = await inspectModelResources(
        source,
        format: ModelResourceFormat.spine,
      );
      final mapping = ModelPerformanceMapping.fromJson({
        'schemaVersion': 1,
        'sourceFingerprint': catalog.sourceFingerprint,
        'format': 'spine',
        'label': 'Mapped JSON rig',
        'idle': 'animation:wait',
        'actions': <String, Object?>{},
        'expressions': <String, Object?>{},
        'parameters': <String, Object?>{},
        'notes': <String>[],
      }, catalog: catalog);
      final gesture = mapping.toSpineGesture(catalog);
      (gesture['ModelMapping.Runtime'] as Map)['sourceFingerprint'] =
          List.filled(64, '0').join();
      final store = LocalSkinStore.forTesting();
      await expectLater(
        store.preparePackage(
          source,
          gestureMapping: Uint8List.fromList(utf8.encode(jsonEncode(gesture))),
          performanceMapping: Uint8List.fromList(
            utf8.encode(jsonEncode(mapping.toJson())),
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test('characters own separate models and previews across restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'aar_character_import_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = LocalSkinStore.forTesting();
    await store.initialize(storageDirectory: directory);
    final ryza = await store.importPackage(_zip(preview: true));
    final sophie = await store.importPackage(
      _zip(preview: true),
      characterId: 'sophie',
    );
    final id = sophie['id']!;
    expect(store.skinsFor('ryza').single['id'], ryza['id']);
    expect(store.skinsFor('sophie').single['id'], id);
    expect(await store.filesFor(id), isNull);
    expect(await store.previewFor(id), isNull);
    expect(
      (await store.filesFor(id, characterId: 'sophie'))!.keys,
      everyElement(startsWith('assets/character/sophie/$id/')),
    );
    expect(await store.previewFor(id, characterId: 'sophie'), _png(4, 5));
    expect(
      await File('${directory.path}/imported_skins/sophie/$id/custom_rig.skel')
          .exists(),
      isTrue,
    );
    final reloaded = LocalSkinStore.forTesting();
    await reloaded.initialize(storageDirectory: directory);
    expect(await reloaded.filesFor(id), isNull);
    expect(reloaded.containsPackage(id, characterId: 'sophie'), isTrue);
    expect(await reloaded.previewFor(id, characterId: 'sophie'), _png(4, 5));
    await expectLater(
      store.importPackage(_zip(), characterId: '../ryza'),
      throwsFormatException,
    );
  });

  test(
    'legacy flat packages belong to Ryza and keep their existing files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aar_legacy_import_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final folder = await Directory(
        '${directory.path}/imported_skins/local_legacy',
      ).create(recursive: true);
      for (final entry in decodeSkinZip(_zip(preview: true)).entries) {
        await File('${folder.path}/${entry.key}').writeAsBytes(entry.value);
      }
      SharedPreferences.setMockInitialValues({
        'localSkinPackages': [
          jsonEncode({
            'id': 'local_legacy',
            'base': 'custom_rig',
            'label': 'Legacy',
            'preview': 'preview.png',
          }),
        ],
      });
      final store = LocalSkinStore.forTesting();
      await store.initialize(storageDirectory: directory);
      expect(store.skins.single['characterId'], 'ryza');
      expect(await store.filesFor('local_legacy'), isNotNull);
      expect(
        await store.filesFor('local_legacy', characterId: 'sophie'),
        isNull,
      );
      expect(await store.previewFor('local_legacy'), _png(4, 5));
      expect(await folder.exists(), isTrue);
    },
  );

  test(
    'loader never falls back to bundled models or crosses character caches',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aar_external_only_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalSkinStore.instance;
      await store.initialize(storageDirectory: directory);
      final record = await store.importPackage(
        _zip(preview: true),
        characterId: 'sophie',
      );
      final id = record['id']!;
      await expectLater(
        ProtectedCharacterAssets.originalFilesFor('crf_skn_002_0001_01'),
        throwsA(isA<MissingImportedCharacterAssets>()),
      );
      await expectLater(
        ProtectedCharacterAssets.bundleFor(id),
        throwsA(isA<MissingImportedCharacterAssets>()),
      );
      final bundle = await ProtectedCharacterAssets.bundleFor(
        id,
        characterId: 'sophie',
      );
      expect(
        await bundle.load('assets/character/sophie/$id/$id.skel'),
        isA<ByteData>(),
      );
      await expectLater(
        ProtectedCharacterAssets.previewFor(id),
        throwsA(isA<MissingImportedCharacterAssets>()),
      );
      expect(
        await ProtectedCharacterAssets.previewFor(id, characterId: 'sophie'),
        _png(4, 5),
      );
    },
  );
}
