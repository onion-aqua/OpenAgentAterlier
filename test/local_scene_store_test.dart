import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/local_scene_store.dart';

const _morning = 'stage_00_000_00_mor';
const _night = 'stage_00_000_00_ngt';

Uint8List _png({int marker = 0, int width = 2}) {
  final bytes = Uint8List(33);
  bytes.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
  bytes.setAll(12, ascii.encode('IHDR'));
  ByteData.sublistView(bytes)
    ..setUint32(16, width)
    ..setUint32(20, 3);
  bytes[32] = marker;
  return bytes;
}

Map<String, List<int>> _triplet(
  String id, {
  String prefix = '',
  int marker = 0,
}) => {
  '$prefix$id.atlas': utf8.encode('$id.png\nsize:2,3\nfilter:Linear,Linear\n'),
  '$prefix$id.skel': [...List.filled(8, 0), 7, ...ascii.encode('4.2.43'), 0],
  '$prefix$id.png': _png(marker: marker),
};

Uint8List _zip(Map<String, List<int>> files, {ArchiveFile? extra}) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  if (extra != null) archive.addFile(extra);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _editFirstCentralHeader(Uint8List zip, void Function(ByteData) edit) {
  final bytes = Uint8List.fromList(zip);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < bytes.length - 46; ++i) {
    if (data.getUint32(i, Endian.little) == 0x02014b50) {
      edit(ByteData.sublistView(bytes, i));
      return bytes;
    }
  }
  throw StateError('No test ZIP central directory');
}

Future<Uint8List> _asset(AssetBundle bundle, String path) async {
  final bytes = await bundle.load(path);
  return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'flat scenes and canonical scene/chair packages keep original asset paths',
    () {
      final decoded = decodeSceneZip(
        _zip({
          ..._triplet(_morning),
          ..._triplet(_night, prefix: 'assets/scenes_runtime/'),
          ..._triplet('obj_001', prefix: 'assets/spine/objects/obj_001/'),
        }),
      );
      expect(decoded, hasLength(9));
      expect(
        decoded.keys,
        containsAll([
          'assets/scenes_runtime/$_morning.atlas',
          'assets/scenes_runtime/$_night.skel',
          'assets/spine/objects/obj_001/obj_001.png',
        ]),
      );
    },
  );

  test(
    'rejects unsafe paths, symlinks, character assets and duplicate aliases',
    () {
      for (final path in [
        '../$_morning.png',
        '/$_morning.png',
        'C:/$_morning.png',
        'assets//scenes_runtime/$_morning.png',
        'assets/scenes_runtime/./$_morning.png',
        'assets/character/ryza/$_morning.png',
        'crf_skn_002_0001_01.skel',
        'notes.txt',
      ]) {
        expect(
          () => decodeSceneZip(
            _zip({
              ..._triplet(_morning),
              path: [1],
            }),
          ),
          throwsFormatException,
          reason: path,
        );
      }
      expect(
        () => decodeSceneZip(
          _zip(
            _triplet(_morning),
            extra: ArchiveFile.bytes('link', utf8.encode('../outside'))
              ..mode = 0xa1ff,
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => decodeSceneZip(
          _zip({
            ..._triplet(_morning),
            ..._triplet(_morning, prefix: 'assets/scenes_runtime/'),
          }),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'checks full triplets, atlas pages, texture dimensions and Spine version',
    () {
      final incomplete = _triplet(_morning)..remove('$_morning.skel');
      expect(() => decodeSceneZip(_zip(incomplete)), throwsFormatException);
      for (final atlas in [
        '../$_morning.png\nsize:2,3\n',
        'other.png\nsize:2,3\n',
        '$_morning.png\nsize:2,3\n\nother.png\nsize:2,3\n',
        '$_morning.png\nsize:4,5\n',
      ]) {
        final files = _triplet(_morning)
          ..['$_morning.atlas'] = utf8.encode(atlas);
        expect(() => decodeSceneZip(_zip(files)), throwsFormatException);
      }
      final oversized = _triplet(_morning)
        ..['$_morning.png'] = _png(width: 9000);
      expect(() => decodeSceneZip(_zip(oversized)), throwsFormatException);
      final wrongVersion = _triplet(_morning)
        ..['$_morning.skel'] = [
          ...List.filled(8, 0),
          7,
          ...ascii.encode('4.1.43'),
          0,
        ];
      expect(() => decodeSceneZip(_zip(wrongVersion)), throwsFormatException);
    },
  );

  test('enforces declared and actual expansion limits and checks CRC', () {
    final zip = _zip(_triplet(_morning));
    final large = _editFirstCentralHeader(zip, (header) {
      header.setUint32(24, maxSceneImportBytes + 1, Endian.little);
    });
    expect(() => decodeSceneZip(large), throwsFormatException);
    final lie = _editFirstCentralHeader(zip, (header) {
      header.setUint32(24, 1, Endian.little);
    });
    expect(() => decodeSceneZip(lie), throwsFormatException);
    final badCrc = _editFirstCentralHeader(zip, (header) {
      header.setUint32(
        16,
        header.getUint32(16, Endian.little) ^ 1,
        Endian.little,
      );
    });
    expect(() => decodeSceneZip(badCrc), throwsFormatException);
  });

  test('persistent imports replace one scene while preserving other scenes and seat', () async {
    final directory = await Directory.systemTemp.createTemp('aar_scene_store_');
    addTearDown(() => directory.delete(recursive: true));
    final store = LocalSceneStore.forTesting();
    addTearDown(store.dispose);
    var notifications = 0;
    store.addListener(() => ++notifications);
    await store.initialize(storageDirectory: directory);
    expect(store.availableSceneIds, isEmpty);
    expect(store.hasSeat, isFalse);
    expect(await store.bundleForScene(_morning), isNull);
    expect(await store.bundleForScene('../../escape'), isNull);
    expect(await store.seatBundle(), isNull);
    final result = await store.importPackage(
      _zip({
        ..._triplet(_morning),
        ..._triplet(_night),
        ..._triplet('obj_001', prefix: 'assets/spine/objects/obj_001/'),
      }),
    );
    expect(result.sceneIds, [_morning, _night]);
    expect(result.importedSeat, isTrue);
    expect(store.availableSceneIds, [_morning, _night]);
    expect(store.hasSeat, isTrue);
    expect(notifications, 2);
    final originalBundle = (await store.bundleForScene(_morning))!;
    final imagePath = 'assets/scenes_runtime/$_morning.png';
    expect(await _asset(originalBundle, imagePath), _png());
    final replacement = await store.importPackage(
      _zip(_triplet(_morning, marker: 9)),
    );
    expect(replacement.importedSeat, isFalse);
    expect(store.hasSeat, isTrue);
    expect(store.revision, 3);
    final newBundle = (await store.bundleForScene(_morning))!;
    expect(identical(originalBundle, newBundle), isFalse);
    expect(await _asset(newBundle, imagePath), _png(marker: 9));
    expect(await _asset(originalBundle, imagePath), _png());
    await expectLater(
      newBundle.load('../escape'),
      throwsA(isA<FlutterError>()),
    );
    await expectLater(
      newBundle.load('assets/scenes_runtime/$_night.png'),
      throwsA(isA<FlutterError>()),
    );
    final reloaded = LocalSceneStore.forTesting();
    addTearDown(reloaded.dispose);
    await reloaded.initialize(storageDirectory: directory);
    expect(reloaded.availableSceneIds, [_morning, _night]);
    expect(reloaded.hasSeat, isTrue);
    expect(
      await _asset((await reloaded.bundleForScene(_morning))!, imagePath),
      _png(marker: 9),
    );
    expect(
      await _asset(
        (await reloaded.seatBundle())!,
        'assets/spine/objects/obj_001/obj_001.png',
      ),
      _png(),
    );
  });

  test(
    'failed imports and interrupted directories do not hide existing scenes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aar_scene_failure_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalSceneStore.forTesting();
      addTearDown(store.dispose);
      await store.initialize(storageDirectory: directory);
      await store.importPackage(_zip(_triplet(_morning)));
      final revision = store.revision;
      await expectLater(
        store.importPackage(
          _zip({
            'notes.txt': [1],
          }),
        ),
        throwsFormatException,
      );
      expect(store.revision, revision);
      await Directory('${directory.path}/imported_scenes/.pending_interrupted')
          .create();
      await store.importPackage(_zip(_triplet(_morning, marker: 8)));
      final packageDirectories =
          await Directory('${directory.path}/imported_scenes')
              .list()
              .where(
                (entry) =>
                    entry is Directory &&
                    entry.path.replaceAll('\\', '/').contains('/pkg_'),
              )
              .cast<Directory>()
              .toList();
      packageDirectories.sort((a, b) => a.path.compareTo(b.path));
      await File(
        '${packageDirectories.last.path}/assets/scenes_runtime/$_morning.png',
      ).delete();
      final reloaded = LocalSceneStore.forTesting();
      addTearDown(reloaded.dispose);
      await reloaded.initialize(storageDirectory: directory);
      expect(reloaded.availableSceneIds, [_morning]);
      expect(
        await _asset(
          (await reloaded.bundleForScene(_morning))!,
          'assets/scenes_runtime/$_morning.png',
        ),
        _png(),
      );
    },
  );

  test(
    'asset corruption is detected before returning bytes to the renderer',
    () async {
      final directory = await Directory.systemTemp.createTemp('aar_scene_crc_');
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalSceneStore.forTesting();
      addTearDown(store.dispose);
      await store.initialize(storageDirectory: directory);
      await store.importPackage(_zip(_triplet(_morning)));
      final bundle = (await store.bundleForScene(_morning))!;
      final texture =
          (await Directory('${directory.path}/imported_scenes')
                      .list(recursive: true)
                      .where((entry) => entry.path.endsWith('$_morning.png'))
                      .toList())
                  .single
              as File;
      await texture.writeAsBytes(_png(marker: 5));
      await expectLater(
        bundle.load('assets/scenes_runtime/$_morning.png'),
        throwsA(isA<FlutterError>()),
      );
    },
  );
}
