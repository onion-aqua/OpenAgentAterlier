import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';

Map<String, dynamic> session(String id, {String text = 'hello'}) => {
  'format': 'agent-atelier-model-session',
  'version': 1,
  'modelId': id,
  'identity': {'displayName': 'My character'},
  'data': {
    'modelId': id,
    'characterId': 'ryza',
    'messages': [
      {'id': '1', 'role': 'user', 'text': text},
    ],
    'userProfile': {'address': 'Player'},
    'settingsSlots': {
      'user': {'active': 0, 'entries': []},
    },
    'preferences': {
      'characterPersona': 'A new independent character',
      'worldSetting': 'A new world',
      'fishMcpVoice': 'public-voice-id',
      'mimoTts': {'voice': 'clone', 'referenceName': 'sample.wav'},
    },
  },
};

Map<String, dynamic> slots(String id) => {
  'active': 0,
  'slots': {
    '0': {
      'format': 'agent-atelier-r-save-slot',
      'version': 1,
      'name': 'Beginning',
      'savedAt': '2026-10-21T00:00:00.000Z',
      'messageCount': 1,
      'preview': 'hello',
      'location': 'A new world',
      'snapshot': {
        'format': 'agent-atelier-r-game-save',
        'version': 1,
        'modelId': id,
        'characterId': 'ryza',
        'messages': [],
        'roleSettings': {
          'userProfile': {'address': 'Player'},
          'characterPersona': 'Independent',
          'worldSetting': 'My world',
        },
      },
    },
  },
};

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

Uint8List zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

Map<String, List<int>> zipFiles(Uint8List encoded) => {
  for (final file in ZipDecoder().decodeBytes(encoded))
    if (file.isFile) file.name: file.readBytes()!,
};

Uint8List compressedEntry(Uint8List encoded, String name) {
  final directory = ZipDirectory()..read(InputMemoryStream(encoded));
  final entry = directory.fileHeaders.singleWhere(
    (row) => row.filename == name,
  );
  return entry.file!.getStream(decompress: false).toUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late ModelPackageStore store;
  final resources = <String, Uint8List>{
    'nested/model.json': bytes('{"skeleton":{"spine":"4.2.0"}}'),
    'nested/model.atlas': bytes('model.png'),
    'nested/model.png': Uint8List.fromList(List.generate(8192, (i) => i % 255)),
  };

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('model_package_test_');
    store = ModelPackageStore.forTesting();
    await store.initialize(storageDirectory: temp);
  });
  tearDown(() async {
    await store.flush();
    await temp.delete(recursive: true);
  });

  Future<void> create(String id, {String format = 'spine'}) async {
    await store.ensureModel(
      modelId: id,
      format: format,
      label: 'Imported character',
      ownerCharacterId: 'ryza',
      files: resources,
    );
  }

  test('one ZIP roundtrips original nested model, session, role settings and saves', () async {
    await create('character_a');
    await store.saveSession(
      'character_a',
      session('character_a'),
      saveSlots: slots('character_a'),
    );
    final encoded = await store.packageBytes('character_a');
    final decoded = ModelPackageStore.decodePackage(encoded);
    expect(decoded.manifest['type'], ModelPackageStore.packageType);
    expect(decoded.manifest['sourceFingerprint'], hasLength(64));
    expect(decoded.modelFiles, resources);
    expect(decoded.session, session('character_a'));
    expect(decoded.saveSlots, slots('character_a'));
    expect(zipFiles(decoded.modelZip), resources);
    expect(
      await File('${temp.path}/model_packages/character_a.zip').exists(),
      isTrue,
    );
    expect(await store.exists('character_a'), isTrue);
    expect(store.models.single.ownerCharacterId, 'ryza');
  });

  test(
    'durable writes restore after process restart and use independent models',
    () async {
      await create('character_a');
      await create('character_b');
      await store.saveSession('character_a', session('character_a', text: 'A'));
      await store.saveSession('character_b', session('character_b', text: 'B'));
      final restarted = ModelPackageStore.forTesting();
      await restarted.initialize(storageDirectory: temp);
      expect(restarted.models, hasLength(2));
      expect(
        await restarted.readSession('character_a'),
        session('character_a', text: 'A'),
      );
      expect(
        await restarted.readSession('character_b'),
        session('character_b', text: 'B'),
      );
      final restored = (await restarted.readSession('character_a'))!;
      (restored['identity'] as Map)['displayName'] = 'Changed outside';
      expect((await restarted.readSession('character_a'))!['identity'], {
        'displayName': 'My character',
      });
    },
  );

  test('model updates retain session, saves, attachments and never recompress unchanged assets', () async {
    await create('character_a');
    await store.saveSession(
      'character_a',
      session('character_a'),
      saveSlots: slots('character_a'),
    );
    await store.saveAttachments('character_a', {
      'texture.png': bytes('replacement-image'),
      'texture-state.json': bytes('{"enabled":true}'),
    });
    final initial = await store.packageBytes('character_a');
    final compressed = compressedEntry(initial, 'model/nested/model.png');
    await store.saveSession(
      'character_a',
      session('character_a', text: 'updated'),
    );
    await create('character_a');
    final updated = await store.packageBytes('character_a');
    expect(compressedEntry(updated, 'model/nested/model.png'), compressed);
    expect(await store.modelFiles('character_a'), resources);
    expect(await store.readSaveSlots('character_a'), slots('character_a'));
    expect(
      await store.readAttachment('character_a', 'texture.png'),
      bytes('replacement-image'),
    );
    expect(
      ModelPackageStore.decodePackage(updated)
          .attachments['texture-state.json'],
      bytes('{"enabled":true}'),
    );
    await store.saveAttachment('character_a', 'texture.png', null);
    expect(await store.readAttachment('character_a', 'texture.png'), isNull);
    expect(
      await store.readSession('character_a'),
      session('character_a', text: 'updated'),
    );
  });

  test(
    'concurrent updates serialize and retain slots and attachment changes',
    () async {
      await create('character_a');
      final first = store.saveSession(
        'character_a',
        session('character_a', text: 'first'),
        saveSlots: slots('character_a'),
      );
      final attachment = store.saveAttachment(
        'character_a',
        'texture.png',
        bytes('image'),
      );
      final last = store.saveSession(
        'character_a',
        session('character_a', text: 'last'),
      );
      await Future.wait([first, attachment, last]);
      await store.flush();
      expect(
        await store.readSession('character_a'),
        session('character_a', text: 'last'),
      );
      expect(
        await store.readAttachment('character_a', 'texture.png'),
        bytes('image'),
      );
      expect(await store.readSaveSlots('character_a'), slots('character_a'));
    },
  );

  test(
    'preserves resource streams compressed by an external encoder',
    () async {
      await create('character_a');
      final files = zipFiles(await store.packageBytes('character_a'));
      final archive = Archive();
      for (final entry in files.entries) {
        archive.add(ArchiveFile.bytes(entry.key, entry.value));
      }
      final external = ZipEncoder().encodeBytes(archive, level: 9);
      final target = File('${temp.path}/model_packages/character_a.zip');
      await target.writeAsBytes(external);
      final restarted = ModelPackageStore.forTesting();
      await restarted.initialize(storageDirectory: temp);
      await restarted.saveSession('character_a', session('character_a'));
      final saved = await restarted.packageBytes('character_a');
      expect(
        compressedEntry(saved, 'model/nested/model.png'),
        compressedEntry(external, 'model/nested/model.png'),
      );
    },
  );

  test(
    'unsafe session or credentials reject without replacing last valid package',
    () async {
      await create('character_a');
      await store.saveSession('character_a', session('character_a'));
      final before = await store.packageBytes('character_a');
      final bad = session('character_a');
      (bad['data'] as Map)['preferences'] = {
        'openAiBaseUrl': 'https://private.invalid',
      };
      await expectLater(
        store.saveSession('character_a', bad),
        throwsFormatException,
      );
      final nestedSecret = session('character_a');
      (nestedSecret['data'] as Map)['userProfile'] = {
        'api_key': 'do-not-write',
      };
      await expectLater(
        store.saveSession('character_a', nestedSecret),
        throwsFormatException,
      );
      final mimoSecret = session('character_a');
      ((mimoSecret['data'] as Map)['preferences'] as Map)['mimoTts'] = {
        'baseUrl': 'private',
      };
      await expectLater(
        store.saveSession('character_a', mimoSecret),
        throwsFormatException,
      );
      await expectLater(
        store.saveSession('character_a', session('other')),
        throwsFormatException,
      );
      await expectLater(
        store.saveSession(
          'character_a',
          session('character_a'),
          saveSlots: slots('other'),
        ),
        throwsFormatException,
      );
      expect(await store.packageBytes('character_a'), before);
      await store.saveSession(
        'character_a',
        session('character_a', text: 'queue recovered'),
      );
      expect(
        await store.readSession('character_a'),
        session('character_a', text: 'queue recovered'),
      );
    },
  );

  test('failed atomic replacement leaves previous ZIP intact', () async {
    await create('character_a');
    await store.saveSession('character_a', session('character_a'));
    final before = await store.packageBytes('character_a');
    // The next sequence number is 3; opening an existing directory as the
    // pending file simulates a failed filesystem write before rename.
    final obstruction = Directory(
      '${temp.path}/model_packages/character_a.zip.pending.3',
    );
    await obstruction.create();
    await expectLater(
      store.saveSession('character_a', session('character_a', text: 'lost')),
      throwsA(isA<FileSystemException>()),
    );
    expect(await store.packageBytes('character_a'), before);
    await obstruction.delete();
  });

  test(
    'damaged existing package is preserved rather than replaced on migration',
    () async {
      final target = File('${temp.path}/model_packages/character_a.zip');
      await target.writeAsBytes([1, 2, 3, 4]);
      await expectLater(create('character_a'), throwsFormatException);
      expect(await target.readAsBytes(), [1, 2, 3, 4]);
      expect(await store.exists('character_a'), isFalse);
    },
  );

  test(
    'rejects traversal, case duplicates, symlink and file-directory conflicts',
    () async {
      for (final path in [
        '../escape',
        '/absolute',
        'C:/drive',
        'model/../../bad',
        'bad\u0000name',
        'CON.txt',
      ]) {
        expect(
          () => ModelPackageStore.decodePackage(
            zip({
              path: [1],
            }),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => ModelPackageStore.decodePackage(
          zip({
            'model/a': [1],
            'MODEL/A': [2],
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => ModelPackageStore.decodePackage(
          zip({
            'model/a': [1],
            'model/a/b': [2],
          }),
        ),
        throwsFormatException,
      );
      final links = Archive()
        ..add(ArchiveFile.bytes('model/link', [1])..mode = 0xa1ff);
      expect(
        () => ModelPackageStore.decodePackage(ZipEncoder().encodeBytes(links)),
        throwsFormatException,
      );
      expect(
        () => ModelPackageStore.encodeModelZip({'../bad': bytes('x')}),
        throwsFormatException,
      );
    },
  );

  test('rejects oversized declarations before allocating output or decoding content', () async {
    final bad = zip({
      'manifest.json': [1],
    });
    final data = ByteData.sublistView(bad);
    for (var i = 0; i < bad.length - 46; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        data.setUint32(
          i + 24,
          ModelPackageStore.maxStateBytes + 1,
          Endian.little,
        );
        break;
      }
    }
    expect(() => ModelPackageStore.decodePackage(bad), throwsFormatException);
    final tooMany = zip({
      for (var i = 0; i <= ModelPackageStore.maxEntries; i++) 'model/$i': [1],
    });
    expect(
      () => ModelPackageStore.decodePackage(tooMany),
      throwsFormatException,
    );
  });

  test(
    'rejects corrupt integrity, unknown namespaces and package versions',
    () async {
      await create('character_a');
      final original = zipFiles(await store.packageBytes('character_a'));
      final tampered = Map<String, List<int>>.of(original)
        ..['model/nested/model.png'] = [1, 2];
      expect(
        () => ModelPackageStore.decodePackage(zip(tampered)),
        throwsFormatException,
      );
      final extra = Map<String, List<int>>.of(original)
        ..['app/global.json'] = bytes('{}');
      expect(
        () => ModelPackageStore.decodePackage(zip(extra)),
        throwsFormatException,
      );
      final manifest =
          jsonDecode(utf8.decode(original['manifest.json']!)) as Map;
      manifest['version'] = 2;
      final newer = Map<String, List<int>>.of(original)
        ..['manifest.json'] = bytes(jsonEncode(manifest));
      expect(
        () => ModelPackageStore.decodePackage(zip(newer)),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects contradictory local headers and truncated resource streams',
    () async {
      await create('character_a');
      final original = await store.packageBytes('character_a');
      final inconsistent = Uint8List.fromList(original);
      ByteData.sublistView(inconsistent).setUint16(8, 0, Endian.little);
      expect(
        () => ModelPackageStore.decodePackage(inconsistent),
        throwsFormatException,
      );
      expect(
        () => ModelPackageStore.decodePackage(
          Uint8List.sublistView(original, 0, original.length - 10),
        ),
        throwsFormatException,
      );
    },
  );

  test('model identity and owner cannot cross package boundaries', () async {
    await create('character_a');
    await expectLater(
      store.ensureModel(
        modelId: 'character_a',
        format: 'spine',
        label: 'Other',
        ownerCharacterId: 'sophie',
        files: resources,
      ),
      throwsFormatException,
    );
    await expectLater(create('../escape'), throwsFormatException);
    await expectLater(
      store.saveAttachment('character_a', '../secret', bytes('x')),
      throwsFormatException,
    );
    await expectLater(
      store.saveAttachment(
        'character_a',
        'texture-state.json',
        bytes('{"enabled":true,"accessToken":"x"}'),
      ),
      throwsFormatException,
    );
    await store.deleteModel('character_a');
    expect(await store.exists('character_a'), isFalse);
    expect(await store.readSession('character_a'), isNull);
  });
}
