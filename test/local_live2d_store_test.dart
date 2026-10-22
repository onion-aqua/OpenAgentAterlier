import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/local_live2d_store.dart';

Map<String, Object?> _model() => {
  'Version': 3,
  'FileReferences': {
    'Moc': 'sample.moc3',
    'Textures': ['textures/texture_00.png'],
    'Physics': 'sample.physics3.json',
    'Pose': 'sample.pose3.json',
    'DisplayInfo': 'sample.cdi3.json',
    'UserData': 'sample.userdata3.json',
    'Motions': {
      'Idle': [
        {'File': 'motions/idle.motion3.json'},
      ],
      'Wave': [
        {'File': 'motions/wave.motion3.json'},
      ],
    },
    'Expressions': [
      {'Name': 'neutral', 'File': 'expressions/neutral.exp3.json'},
    ],
  },
};

Map<String, List<int>> _files({bool manifest = true}) => {
  'nested/model/sample.model3.json': utf8.encode(jsonEncode(_model())),
  'nested/model/sample.moc3': [1, 2, 3],
  'nested/model/textures/texture_00.png': [1, 2, 3],
  'nested/model/sample.physics3.json': utf8.encode('{}'),
  'nested/model/sample.pose3.json': utf8.encode('{}'),
  'nested/model/sample.cdi3.json': utf8.encode('{}'),
  'nested/model/sample.userdata3.json': utf8.encode('{}'),
  'nested/model/motions/idle.motion3.json': utf8.encode('{}'),
  'nested/model/motions/wave.motion3.json': utf8.encode('{}'),
  'nested/model/expressions/neutral.exp3.json': utf8.encode('{}'),
  if (manifest)
    'nested/model/performance.manifest.json': utf8.encode(
      jsonEncode({
        'actions': {
          'wave': {'group': 'Wave', 'index': 0},
        },
        'parameters': {'mouthOpen': 'ParamMouthOpenY'},
      }),
    ),
};

Uint8List _zip(Map<String, List<int>> files, {ArchiveFile? extra}) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  if (extra != null) archive.addFile(extra);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<Uint8List> _performanceMapping(Uint8List source) async {
  final digest = (await Sha256().hash(source)).bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'sourceFingerprint': digest,
        'format': 'live2d',
        'label': 'Mapped Live2D',
        'idle': 'motion:Idle:0',
        'actions': {
          'wave': {
            'target': 'motion:Wave:0',
            'description': 'wave',
            'confidence': .98,
            'evidence': 'catalog',
          },
        },
        'expressions': {
          'neutral': {
            'target': 'expression:neutral',
            'description': 'neutral',
            'confidence': 1,
            'evidence': 'catalog',
          },
        },
        'parameters': {
          'mouthOpen': {
            'target': 'parameter:ParamMouthOpenY',
            'description': 'mouth',
            'confidence': 1,
            'evidence': 'catalog',
          },
        },
        'notes': <String>[],
      }),
    ),
  );
}

/// Mutate only declared central-directory lengths; no large test allocation.
Uint8List _declaredSizes(Uint8List zip, List<int> sizes) {
  final result = Uint8List.fromList(zip);
  final view = ByteData.sublistView(result);
  var index = 0;
  for (
    var offset = 0;
    offset < result.length - 46 && index < sizes.length;
    offset++
  ) {
    if (view.getUint32(offset, Endian.little) != 0x02014b50) continue;
    view.setUint32(offset + 24, sizes[index++], Endian.little);
  }
  expect(index, sizes.length);
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late LocalLive2dStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aar_live2d_');
    store = LocalLive2dStore.forTesting();
    await store.initialize(storageDirectory: directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'canonical ZIP retains nested paths and restores missing runtime files',
    () async {
      final model = await store.importPackage(
        _zip(_files()),
        characterId: 'custom',
      );
      final bytes = await store.packageBytesFor(
        model.id,
        characterId: 'custom',
      );
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(
        archive.findFile('model/nested/model/sample.model3.json'),
        isNotNull,
      );
      expect(
        archive
            .findFile('model/nested/model/textures/texture_00.png')!
            .readBytes(),
        [1, 2, 3],
      );
      await File('${model.directory}/textures/texture_00.png').delete();
      final restarted = LocalLive2dStore.forTesting();
      await restarted.initialize(storageDirectory: directory);
      final restored = restarted.byId(model.id, characterId: 'custom')!;
      expect(
        await File('${restored.directory}/textures/texture_00.png')
            .readAsBytes(),
        [1, 2, 3],
      );
      expect(restored.directory, model.directory);
      expect(restarted.byId(model.id, characterId: 'ryza'), isNull);
    },
  );

  test(
    'canonical Live2D ZIP restores an entirely removed extraction cache',
    () async {
      final model = await store.importPackage(
        _zip(_files()),
        characterId: 'custom',
      );
      await Directory('${directory.path}/imported_live2d/custom/${model.id}')
          .delete(recursive: true);
      final restarted = LocalLive2dStore.forTesting();
      await restarted.initialize(storageDirectory: directory);
      expect(restarted.byId(model.id, characterId: 'custom'), isNotNull);
      expect(await File('${model.directory}/sample.moc3').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'removing one imported Live2D model preserves the older package',
    () async {
      final older = await store.importPackage(
        _zip(_files()),
        characterId: 'custom',
      );
      final added = await store.importPackage(
        _zip(_files()),
        characterId: 'custom',
      );
      expect(
        await store.removeImportedModel(added.id, characterId: 'ryza'),
        isFalse,
      );
      expect(
        await store.removeImportedModel(added.id, characterId: 'custom'),
        isTrue,
      );
      expect(
        await store.removeImportedModel(added.id, characterId: 'custom'),
        isFalse,
      );
      expect(store.models.single.id, older.id);
      expect(await Directory(added.directory).exists(), isFalse);
      expect(
        await File('${directory.path}/model_packages/${added.id}.zip').exists(),
        isFalse,
      );
      expect(
        await File('${directory.path}/model_packages/${older.id}.zip').exists(),
        isTrue,
      );
      final restarted = LocalLive2dStore.forTesting();
      await restarted.initialize(storageDirectory: directory);
      expect(restarted.models.single.id, older.id);
    },
  );

  test(
    'failed Live2D removal index leaves all model resources recoverable',
    () async {
      final model = await store.importPackage(
        _zip(_files()),
        characterId: 'custom',
      );
      final index = File('${directory.path}/imported_live2d/models.json');
      final originalIndex = await index.readAsBytes();
      await index.delete();
      await Directory(index.path).create();
      await expectLater(
        store.removeImportedModel(model.id, characterId: 'custom'),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.models.single.id, model.id);
      expect(await File('${model.directory}/sample.moc3').exists(), isTrue);
      expect(
        await File('${directory.path}/model_packages/${model.id}.zip').exists(),
        isTrue,
      );
      await Directory(index.path).delete();
      await index.writeAsBytes(originalIndex);
      final restarted = LocalLive2dStore.forTesting();
      await restarted.initialize(storageDirectory: directory);
      expect(restarted.models.single.id, model.id);
      expect(
        await restarted.removeImportedModel(model.id, characterId: 'custom'),
        isTrue,
      );
    },
  );

  test(
    'imports nested model files and restores an isolated character index',
    () async {
      final first = await store.importPackage(
        _zip(_files()),
        characterId: 'ryza',
        label: '  My Live2D  ',
      );
      expect(first.label, 'My Live2D');
      expect(first.characterId, 'ryza');
      expect(first.modelFileName, 'sample.model3.json');
      expect(first.manifestFileName, 'performance.manifest.json');
      expect(first.directory, endsWith('/nested/model'));
      expect(
        await File('${first.directory}/textures/texture_00.png').readAsBytes(),
        [1, 2, 3],
      );
      expect(store.modelsFor('sophie'), isEmpty);
      expect(store.byId(first.id, characterId: 'sophie'), isNull);
      expect(
        store.byId(first.id, characterId: 'ryza')!.directory,
        first.directory,
      );
      expect(() => store.models.clear(), throwsUnsupportedError);

      final second = await store.importPackage(
        _zip(_files()),
        characterId: 'sophie',
      );
      expect(second.id, isNot(first.id));
      expect(second.directory, isNot(first.directory));
      expect(second.label, 'sample');
      final reloaded = LocalLive2dStore.forTesting();
      await reloaded.initialize(storageDirectory: directory);
      expect(reloaded.models, hasLength(2));
      expect(reloaded.modelsFor('ryza').single.id, first.id);
      expect(reloaded.modelsFor('sophie').single.id, second.id);
      final indexText = await File(
        '${directory.path}/imported_live2d/models.json',
      ).readAsString();
      expect(
        indexText,
        isNot(contains(directory.path.replaceAll('\\', '\\\\'))),
      );
    },
  );

  test('supports no manifest and manifest.json next to the model', () async {
    final noManifest = await store.importPackage(
      _zip(_files(manifest: false)),
      characterId: 'ryza',
    );
    expect(noManifest.manifestFileName, isNull);
    final files = _files(manifest: false)
      ..['nested/model/manifest.json'] = utf8.encode('{}');
    final result = await store.importPackage(_zip(files), characterId: 'ryza');
    expect(result.manifestFileName, 'manifest.json');
  });

  test(
    'validated manifest override and source mapping survive restart',
    () async {
      final source = _zip(_files(manifest: false));
      final mapping = await _performanceMapping(source);
      final result = await store.importPackage(
        source,
        characterId: 'sophie',
        manifestOverride: {
          'idle': {'group': 'Idle', 'index': 0},
          'actions': {
            'wave': {'group': 'Wave', 'index': 0, 'description': 'wave'},
          },
          'expressions': {
            'neutral': {'name': 'neutral'},
          },
          'parameters': {'mouthOpen': 'ParamMouthOpenY'},
        },
        performanceMapping: mapping,
      );
      expect(result.label, 'Mapped Live2D');
      expect(result.manifestFileName, 'performance.manifest.json');
      expect(result.performanceMappingFileName, 'performance.mapping.json');
      expect(result.sourceFingerprint, hasLength(64));
      final manifest = jsonDecode(
        await File('${result.directory}/performance.manifest.json')
            .readAsString(),
      ) as Map;
      expect(manifest['actions']['wave']['group'], 'Wave');
      expect(manifest['idle'], {'group': 'Idle', 'index': 0});
      expect(
        await File('${result.directory}/performance.mapping.json')
            .readAsBytes(),
        mapping,
      );

      final restored = LocalLive2dStore.forTesting();
      await restored.initialize(storageDirectory: directory);
      expect(
        restored.models.single.performanceMappingFileName,
        'performance.mapping.json',
      );
      expect(
        restored.models.single.sourceFingerprint,
        result.sourceFingerprint,
      );
    },
  );

  test(
    'rejects override references absent from the model before writing',
    () async {
      final source = _zip(_files(manifest: false));
      await expectLater(
        store.importPackage(
          source,
          characterId: 'ryza',
          manifestOverride: {
            'actions': {
              'wave': {'group': 'Missing', 'index': 9},
            },
          },
        ),
        throwsFormatException,
      );
      expect(store.models, isEmpty);
    },
  );

  test(
    'rejects an unknown or malformed idle override before writing',
    () async {
      final source = _zip(_files(manifest: false));
      await expectLater(
        store.importPackage(
          source,
          characterId: 'ryza',
          manifestOverride: {
            'idle': {'group': 'Missing', 'index': 0},
          },
        ),
        throwsFormatException,
      );
      await expectLater(
        store.importPackage(
          source,
          characterId: 'ryza',
          manifestOverride: {'idle': 'Idle[0]'},
        ),
        throwsFormatException,
      );
      expect(store.models, isEmpty);
    },
  );

  test('rejects a performance mapping for another archive', () async {
    final source = _zip(_files(manifest: false));
    final other = _zip({
      ..._files(manifest: false),
      'extra.png': [1],
    });
    await expectLater(
      store.importPackage(
        source,
        characterId: 'ryza',
        performanceMapping: await _performanceMapping(other),
      ),
      throwsFormatException,
    );
    expect(store.models, isEmpty);
  });

  for (final extension in ['wav', 'mp3']) {
    test(
      'preserves a referenced motion Sound .$extension inside the package',
      () async {
        final model = _model();
        final references = model['FileReferences'] as Map<String, Object?>;
        final motions = references['Motions'] as Map<String, Object?>;
        ((motions['Wave'] as List).single as Map<String, Object?>)['Sound'] =
            'audio/wave.$extension';
        final files = _files()
          ..['nested/model/sample.model3.json'] = utf8.encode(jsonEncode(model))
          ..['nested/model/audio/wave.$extension'] = [1, 2, 3, 4];
        final record = await store.importPackage(
          _zip(files),
          characterId: 'ryza',
        );
        expect(
          await File('${record.directory}/audio/wave.$extension').readAsBytes(),
          [1, 2, 3, 4],
        );
        files.remove('nested/model/audio/wave.$extension');
        await expectLater(
          store.importPackage(_zip(files), characterId: 'ryza'),
          throwsFormatException,
        );
        expect(store.models, hasLength(1));
      },
    );
  }

  test('keeps concurrent imports rather than losing an index update', () async {
    final imported = await Future.wait([
      store.importPackage(_zip(_files()), characterId: 'ryza'),
      store.importPackage(_zip(_files()), characterId: 'ryza'),
    ]);
    expect(imported.map((model) => model.id).toSet(), hasLength(2));
    final reloaded = LocalLive2dStore.forTesting();
    await reloaded.initialize(storageDirectory: directory);
    expect(reloaded.models, hasLength(2));
  });

  for (final path in [
    '../escape.png',
    '/absolute.png',
    'C:/outside.png',
    'nested/../../escape.png',
    'nested\\..\\escape.png',
    'nested/file.png:stream',
    'nested/NUL.png',
    'nested/ending. /image.png',
  ]) {
    test('rejects unsafe archive path $path before writing files', () async {
      final files = _files()..[path] = [1];
      await expectLater(
        store.importPackage(_zip(files), characterId: 'ryza'),
        throwsFormatException,
      );
      expect(store.models, isEmpty);
      expect(
        await Directory('${directory.path}/imported_live2d').list().toList(),
        isEmpty,
      );
    });
  }

  test(
    'rejects normalized duplicate paths and file-directory collisions',
    () async {
      final duplicates = _files()..['NESTED/model/sample.moc3'] = [1];
      await expectLater(
        store.importPackage(_zip(duplicates), characterId: 'ryza'),
        throwsFormatException,
      );
      final collision = _files()..['nested/model/sample.moc3/other.png'] = [1];
      await expectLater(
        store.importPackage(_zip(collision), characterId: 'ryza'),
        throwsFormatException,
      );
    },
  );

  test('rejects links and non-whitelisted files', () async {
    final link = ArchiveFile.bytes('link.png', utf8.encode('../outside.png'))
      ..mode = 0xa1ff;
    await expectLater(
      store.importPackage(_zip(_files(), extra: link), characterId: 'ryza'),
      throwsFormatException,
    );
    final executable = _files()..['run.exe'] = [1];
    await expectLater(
      store.importPackage(_zip(executable), characterId: 'ryza'),
      throwsFormatException,
    );
  });

  test('requires exactly one model3 entry', () async {
    final none = _files()..remove('nested/model/sample.model3.json');
    final two = _files()
      ..['second.model3.json'] = utf8.encode(jsonEncode(_model()));
    await expectLater(
      store.importPackage(_zip(none), characterId: 'ryza'),
      throwsFormatException,
    );
    await expectLater(
      store.importPackage(_zip(two), characterId: 'ryza'),
      throwsFormatException,
    );
  });

  for (final missing in [
    'sample.moc3',
    'textures/texture_00.png',
    'sample.physics3.json',
    'sample.pose3.json',
    'sample.cdi3.json',
    'sample.userdata3.json',
    'motions/idle.motion3.json',
    'expressions/neutral.exp3.json',
  ]) {
    test('requires referenced file $missing', () async {
      final files = _files()..remove('nested/model/$missing');
      await expectLater(
        store.importPackage(_zip(files), characterId: 'ryza'),
        throwsFormatException,
      );
      expect(store.models, isEmpty);
    });
  }

  test(
    'rejects traversal in model references and malformed manifests',
    () async {
      final model = _model();
      (model['FileReferences'] as Map<String, Object?>)['Moc'] =
          '../sample.moc3';
      final files = _files()
        ..['nested/model/sample.model3.json'] = utf8.encode(jsonEncode(model));
      await expectLater(
        store.importPackage(_zip(files), characterId: 'ryza'),
        throwsFormatException,
      );
      files['nested/model/sample.model3.json'] = utf8.encode(
        jsonEncode(_model()),
      );
      files['nested/model/performance.manifest.json'] = utf8.encode('[]');
      await expectLater(
        store.importPackage(_zip(files), characterId: 'ryza'),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects malformed motion references that a catalog parser can skip',
    () async {
      final model = _model();
      (model['FileReferences'] as Map<String, Object?>)['Motions'] = {
        'Wave': [
          {'File': 'motions/wave.motion3.json'},
          {'File': null},
        ],
      };
      final files = _files()
        ..['nested/model/sample.model3.json'] = utf8.encode(jsonEncode(model));
      await expectLater(
        store.importPackage(_zip(files), characterId: 'ryza'),
        throwsFormatException,
      );
    },
  );

  test(
    'bounds actual inflation even when a ZIP understates output size',
    () async {
      final zip = _declaredSizes(_zip(_files()), [1]);
      await expectLater(
        store.importPackage(zip, characterId: 'ryza'),
        throwsFormatException,
      );
      expect(store.models, isEmpty);
    },
  );

  test('enforces entry, individual-file and total expansion limits before inflation', () async {
    final files = _files();
    for (var i = files.length; i <= maxLive2dArchiveEntries; i++) {
      files['extra/$i.png'] = [1];
    }
    await expectLater(
      store.importPackage(_zip(files), characterId: 'ryza'),
      throwsFormatException,
    );
    await expectLater(
      store.importPackage(
        _declaredSizes(_zip(_files()), [maxLive2dFileBytes + 1]),
        characterId: 'ryza',
      ),
      throwsFormatException,
    );
    await expectLater(
      store.importPackage(
        _declaredSizes(_zip(_files()), [
          100 * 1024 * 1024,
          100 * 1024 * 1024,
          100 * 1024 * 1024,
        ]),
        characterId: 'ryza',
      ),
      throwsFormatException,
    );
    expect(store.models, isEmpty);
  });

  test('rejects corrupt payloads and invalid character IDs', () async {
    await expectLater(
      store.importPackage(Uint8List.fromList([1, 2, 3]), characterId: 'ryza'),
      throwsFormatException,
    );
    await expectLater(
      store.importPackage(_zip(_files()), characterId: '../ryza'),
      throwsFormatException,
    );
    expect(store.models, isEmpty);
  });

  test(
    'cleans a complete package when atomic index replacement fails',
    () async {
      final first = await store.importPackage(
        _zip(_files()),
        characterId: 'ryza',
      );
      final root = Directory('${directory.path}/imported_live2d');
      await File('${root.path}/models.json').delete();
      await Directory('${root.path}/models.json').create();
      await expectLater(
        store.importPackage(_zip(_files()), characterId: 'ryza'),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.models.single.id, first.id);
      final packages = await Directory('${root.path}/ryza').list().toList();
      expect(packages, hasLength(1));
      final canonical = await Directory('${directory.path}/model_packages')
          .list()
          .where((entry) => entry.path.endsWith('.zip'))
          .toList();
      expect(canonical, hasLength(1));
      expect(canonical.single.path, endsWith('${first.id}.zip'));
      final topLevelNames = (await root.list().toList()).map(
        (entity) => entity.path.split(Platform.pathSeparator).last,
      );
      expect(
        topLevelNames.any(
          (name) => name.startsWith('.staging_') || name.startsWith('.models_'),
        ),
        isFalse,
      );
    },
  );

  test(
    'does not restore metadata that redirects outside its character folder',
    () async {
      final first = await store.importPackage(
        _zip(_files()),
        characterId: 'ryza',
      );
      final index = File('${directory.path}/imported_live2d/models.json');
      final data = jsonDecode(await index.readAsString()) as Map;
      final row = (data['models'] as List).single as Map;
      row['modelPath'] = '../../outside.model3.json';
      await index.writeAsString(jsonEncode(data));
      final reloaded = LocalLive2dStore.forTesting();
      await reloaded.initialize(storageDirectory: directory);
      expect(reloaded.models, isEmpty);
      expect(
        await File('${first.directory}/${first.modelFileName}').exists(),
        isTrue,
      );
    },
  );
}
