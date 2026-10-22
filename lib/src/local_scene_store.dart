import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show InputMemoryStream, ZipDirectory, ZipFileHeader, getCrc32;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Both the ZIP and its expanded contents have this limit. Contents are read
/// through a bounded inflater, rather than trusting ZIP size declarations.
const maxSceneImportBytes = 256 * 1024 * 1024;
const _maxSceneZipEntries = 4096;
const _sceneRoot = 'assets/scenes_runtime';
const _seatRoot = 'assets/spine/objects/obj_001';
const _suffixes = ['.atlas', '.skel', '.png'];
final _sceneIdPattern = RegExp(
  r'^stage_[0-9]{2}_[0-9]{3}_[0-9]{2}_(mor|aft|eve|ngt)$',
);
final _packageIdPattern = RegExp(r'^pkg_[0-9]{20}_[a-f0-9]{8}$');

/// Reads only scene/chair triplets into their original virtual asset paths.
/// Character files and unrecognised files are rejected, never extracted.
Map<String, Uint8List> decodeSceneZip(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxSceneImportBytes) {
    throw const FormatException('Scene ZIP must be between 1 byte and 256 MB');
  }
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.isEmpty ||
      directory.fileHeaders.length > _maxSceneZipEntries) {
    throw const FormatException('Empty scene ZIP or too many ZIP entries');
  }
  final entries = <String, ZipFileHeader>{};
  final sourcePaths = <String>{};
  var total = 0;
  for (final header in directory.fileHeaders) {
    final file = header.file;
    final path = _safeArchivePath(header.filename);
    if (file == null || _safeArchivePath(file.filename) != path) {
      throw const FormatException('ZIP local and directory paths do not match');
    }
    if (!sourcePaths.add(path)) {
      throw const FormatException('Duplicate ZIP path');
    }
    final type = (header.externalFileAttributes >> 16) & 0xf000;
    if (type != 0 && type != 0x8000 && type != 0x4000) {
      throw const FormatException(
        'Scene ZIP links and special files are unsafe',
      );
    }
    if ((header.generalPurposeBitFlag | file.flags) & 1 != 0 ||
        (header.compressionMethod != 0 && header.compressionMethod != 8)) {
      throw const FormatException(
        'Use an unencrypted stored/deflated scene ZIP',
      );
    }
    if (header.uncompressedSize < 0 ||
        header.compressedSize < 0 ||
        header.compressedSize > bytes.length) {
      throw const FormatException('Invalid ZIP entry size');
    }
    total += header.uncompressedSize;
    if (total > maxSceneImportBytes) {
      throw const FormatException('Expanded scene ZIP exceeds 256 MB');
    }
    if (path.endsWith('/')) {
      if (header.uncompressedSize != 0 || (type != 0 && type != 0x4000)) {
        throw const FormatException('Invalid ZIP directory');
      }
      continue;
    }
    if (type == 0x4000 || header.uncompressedSize == 0) {
      throw const FormatException('Empty or invalid scene file');
    }
    final virtualPath = _canonicalAssetPath(path);
    if (virtualPath == null) {
      throw FormatException('Not a supported scene/chair file: $path');
    }
    if (entries.containsKey(virtualPath)) {
      throw const FormatException('Duplicate scene asset');
    }
    entries[virtualPath] = header;
  }
  if (entries.isEmpty) throw const FormatException('No scene/chair triplets');
  _checkCompleteTriplets(entries.keys);

  // Check the full directory before decompressing any entry, including links.
  final files = <String, Uint8List>{};
  for (final entry in entries.entries) {
    final header = entry.value;
    final sink = _BoundedBytesSink(header.uncompressedSize);
    final compressed = header.file!.getRawContent();
    if (header.compressionMethod == 0) {
      sink.add(compressed);
    } else {
      final inflater = ZLibDecoder(raw: true).startChunkedConversion(sink);
      for (var offset = 0; offset < compressed.length; offset += 8192) {
        inflater.add(
          Uint8List.sublistView(
            compressed,
            offset,
            min(offset + 8192, compressed.length),
          ),
        );
      }
      inflater.close();
    }
    final content = sink.takeBytes();
    if (content.length != header.uncompressedSize ||
        getCrc32(content) != header.crc32) {
      throw const FormatException('Scene ZIP size/checksum mismatch');
    }
    files[entry.key] = content;
  }
  _validateTriplets(files);
  return files;
}

String _safeArchivePath(String value) {
  final path = value.replaceAll('\\', '/');
  final parts = (path.endsWith('/') ? path.substring(0, path.length - 1) : path)
      .split('/');
  if (path.isEmpty ||
      path.length > 240 ||
      path.startsWith('/') ||
      path.contains(':') ||
      path.codeUnits.any((c) => c < 32 || c == 127) ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const FormatException('Unsafe scene ZIP path');
  }
  return path;
}

String? _canonicalAssetPath(String path) {
  final fileName = path.split('/').last;
  final suffix = _suffixes.where(fileName.endsWith).firstOrNull;
  if (suffix == null) return null;
  final id = fileName.substring(0, fileName.length - suffix.length);
  if (_sceneIdPattern.hasMatch(id) &&
      (path == fileName || path == '$_sceneRoot/$fileName')) {
    return '$_sceneRoot/$fileName';
  }
  if (path == '$_seatRoot/obj_001$suffix') return path;
  return null;
}

String _assetBase(String path) => path.substring(0, path.lastIndexOf('.'));

void _checkCompleteTriplets(Iterable<String> paths) {
  final files = paths.toSet();
  for (final base in paths.map(_assetBase).toSet()) {
    if (_suffixes.any((suffix) => !files.contains('$base$suffix'))) {
      throw FormatException('Missing atlas, skel or PNG for $base');
    }
  }
}

void _validateTriplets(Map<String, Uint8List> files) {
  for (final base in files.keys.map(_assetBase).toSet()) {
    final atlasBytes = files['$base.atlas']!;
    if (atlasBytes.length > 1024 * 1024) {
      throw const FormatException('Scene atlas exceeds 1 MB');
    }
    final atlas = utf8.decode(atlasBytes);
    final name = base.split('/').last;
    final pages = atlas
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.endsWith('.png'))
        .toList();
    if (pages.length != 1 || pages.single != '$name.png') {
      throw const FormatException('Use one matching PNG page for each atlas');
    }
    final texture = files['$base.png']!;
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (texture.length < 33 ||
        !listEquals(texture.take(8).toList(), signature) ||
        String.fromCharCodes(texture.sublist(12, 16)) != 'IHDR') {
      throw const FormatException('Expected a PNG scene texture');
    }
    final png = ByteData.sublistView(texture);
    final width = png.getUint32(16), height = png.getUint32(20);
    final size = RegExp(
      r'^size:\s*(\d+)\s*,\s*(\d+)\s*$',
      multiLine: true,
    ).firstMatch(atlas);
    if (width == 0 ||
        height == 0 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 33554432 ||
        size == null ||
        int.parse(size[1]!) != width ||
        int.parse(size[2]!) != height) {
      throw const FormatException(
        'Invalid PNG size or atlas dimension mismatch',
      );
    }
    final skeleton = files['$base.skel']!;
    if (skeleton.length < 14 ||
        skeleton[8] < 4 ||
        skeleton[8] > 32 ||
        8 + skeleton[8] > skeleton.length ||
        !RegExp(r'^4\.2\.[0-9]+$').hasMatch(
          // Spine strings encode their UTF-8 byte length plus one.
          String.fromCharCodes(skeleton.sublist(9, 8 + skeleton[8])),
        )) {
      throw const FormatException(
        'Only Spine 4.2 scene skeletons are supported',
      );
    }
  }
}

class _BoundedBytesSink implements Sink<List<int>> {
  _BoundedBytesSink(this.limit);
  final int limit;
  final _builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (_builder.length + data.length > limit) {
      throw const FormatException('Expanded ZIP entry exceeds declared size');
    }
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

class LocalSceneImportResult {
  LocalSceneImportResult({
    required List<String> sceneIds,
    required this.importedSeat,
  }) : sceneIds = List.unmodifiable(sceneIds);
  final List<String> sceneIds;
  final bool importedSeat;
}

/// User-supplied scene/object media is independent from character packages.
/// A fully written package directory is committed with one rename, so a failed
/// or interrupted replacement leaves the previous scene available on restart.
class LocalSceneStore extends ChangeNotifier {
  LocalSceneStore._();
  @visibleForTesting
  factory LocalSceneStore.forTesting() => LocalSceneStore._();
  static final instance = LocalSceneStore._();

  Directory? _root;
  Future<void>? _initialization;
  Future<void> _importTail = Future.value();
  final _scenes = <String, _ScenePackageRecord>{};
  _ScenePackageRecord? _seat;
  int _lastStamp = 0;
  int _revision = 0;

  List<String> get availableSceneIds =>
      List.unmodifiable(_scenes.keys.toList()..sort());
  bool get hasSeat => _seat != null;
  int get revision => _revision;

  Future<void> initialize({Directory? storageDirectory}) =>
      _initialization ??= _initialize(storageDirectory);

  Future<void> _initialize(Directory? storageDirectory) async {
    final support = storageDirectory ?? await getApplicationSupportDirectory();
    final root = Directory('${support.path}/imported_scenes');
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FileSystemException('Invalid scene storage directory');
    }
    await root.create(recursive: true);
    final directories = await root
        .list(followLinks: false)
        .where((entry) {
          return entry is Directory &&
              _packageIdPattern.hasMatch(
                entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
              );
        })
        .cast<Directory>()
        .toList();
    directories.sort((a, b) => a.path.compareTo(b.path));
    for (final directory in directories) {
      try {
        final record = await _ScenePackageRecord.read(directory);
        if (record == null) continue;
        for (final id in record.sceneIds) {
          _scenes[id] = record;
        }
        if (record.hasSeat) _seat = record;
        final name = directory.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        _lastStamp = max(_lastStamp, int.parse(name.split('_')[1]));
      } on Object {
        // Incomplete/corrupt packages do not hide older intact imports.
      }
    }
    _root = root;
    ++_revision;
    notifyListeners();
  }

  Future<LocalSceneImportResult> importPackage(Uint8List bytes) async {
    await initialize();
    // File writes/commits are serial even if two callers select ZIPs together.
    final previous = _importTail;
    final completer = Completer<void>();
    _importTail = completer.future;
    await previous;
    try {
      return await _importPackage(bytes);
    } finally {
      completer.complete();
    }
  }

  Future<LocalSceneImportResult> _importPackage(Uint8List bytes) async {
    final files = await compute(decodeSceneZip, bytes);
    final sceneIds =
        files.keys
            .where(
              (path) =>
                  path.startsWith('$_sceneRoot/') && path.endsWith('.skel'),
            )
            .map((path) => path.split('/').last.replaceFirst('.skel', ''))
            .toList()
          ..sort();
    final hasSeat = files.containsKey('$_seatRoot/obj_001.skel');
    final stamp = max(DateTime.now().microsecondsSinceEpoch, _lastStamp + 1);
    final random = Random.secure()
        .nextInt(0x100000000)
        .toRadixString(16)
        .padLeft(8, '0');
    final name = 'pkg_${stamp.toString().padLeft(20, '0')}_$random';
    final staging = Directory('${_root!.path}/.pending_$name');
    final committed = Directory('${_root!.path}/$name');
    await staging.create();
    try {
      for (final entry in files.entries) {
        final file = File('${staging.path}/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      await File('${staging.path}/package.json').writeAsString(
        jsonEncode({
          'version': 1,
          'files': {
            for (final entry in files.entries)
              entry.key: {
                'bytes': entry.value.length,
                'crc32': getCrc32(entry.value),
              },
          },
        }),
        flush: true,
      );
      await staging.rename(committed.path);
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    final record = await _ScenePackageRecord.read(committed);
    if (record == null) {
      throw const FileSystemException(
        'Scene import did not persist completely',
      );
    }
    for (final id in sceneIds) {
      _scenes[id] = record;
    }
    if (hasSeat) _seat = record;
    _lastStamp = stamp;
    ++_revision;
    notifyListeners();
    return LocalSceneImportResult(sceneIds: sceneIds, importedSeat: hasSeat);
  }

  Future<AssetBundle?> bundleForScene(String id) async {
    await initialize();
    if (!_sceneIdPattern.hasMatch(id)) return null;
    return _scenes[id]?.bundle('$_sceneRoot/$id');
  }

  Future<AssetBundle?> seatBundle() async {
    await initialize();
    return _seat?.bundle('$_seatRoot/obj_001');
  }
}

class _ScenePackageRecord {
  _ScenePackageRecord(this.directory, this.files);
  final Directory directory;
  final Map<String, ({int bytes, int crc32})> files;
  final _bundles = <String, AssetBundle>{};

  List<String> get sceneIds => files.keys
      .where(
        (path) => path.startsWith('$_sceneRoot/') && path.endsWith('.skel'),
      )
      .map((path) => path.split('/').last.replaceFirst('.skel', ''))
      .toList();
  bool get hasSeat => files.containsKey('$_seatRoot/obj_001.skel');

  static Future<_ScenePackageRecord?> read(Directory directory) async {
    final manifest = File('${directory.path}/package.json');
    if (await FileSystemEntity.type(manifest.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await manifest.length() > 1024 * 1024) {
      return null;
    }
    final data = jsonDecode(await manifest.readAsString());
    if (data is! Map || data['version'] != 1 || data['files'] is! Map) {
      return null;
    }
    final metadata = data['files'] as Map;
    if (metadata.isEmpty || metadata.length > _maxSceneZipEntries) return null;
    final files = <String, ({int bytes, int crc32})>{};
    var total = 0;
    for (final entry in metadata.entries) {
      final path = entry.key;
      final value = entry.value;
      if (path is! String ||
          _canonicalAssetPath(path) != path ||
          value is! Map) {
        return null;
      }
      final size = value['bytes'], crc = value['crc32'];
      if (size is! int ||
          size <= 0 ||
          crc is! int ||
          crc < 0 ||
          crc > 0xffffffff) {
        return null;
      }
      total += size;
      if (total > maxSceneImportBytes ||
          !await _isRegularAssetFile(directory, path) ||
          await File('${directory.path}/$path').length() != size) {
        return null;
      }
      files[path] = (bytes: size, crc32: crc);
    }
    _checkCompleteTriplets(files.keys);
    return _ScenePackageRecord(directory, Map.unmodifiable(files));
  }

  AssetBundle bundle(String base) => _bundles.putIfAbsent(base, () {
    return _LocalSceneAssetBundle(directory, {
      for (final suffix in _suffixes) '$base$suffix': files['$base$suffix']!,
    });
  });
}

Future<bool> _isRegularAssetFile(Directory directory, String path) async {
  var current = directory.path;
  final parts = path.split('/');
  for (var i = 0; i < parts.length; ++i) {
    current = '$current/${parts[i]}';
    final type = await FileSystemEntity.type(current, followLinks: false);
    final expected = i == parts.length - 1
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (type != expected) return false;
  }
  return true;
}

class _LocalSceneAssetBundle extends CachingAssetBundle {
  _LocalSceneAssetBundle(this.directory, this.files);
  final Directory directory;
  final Map<String, ({int bytes, int crc32})> files;

  @override
  Future<ByteData> load(String key) async {
    final path = key.replaceAll('\\', '/');
    final expected = files[path];
    if (expected == null || !await _isRegularAssetFile(directory, path)) {
      throw FlutterError('Imported scene asset not found: $path');
    }
    final file = File('${directory.path}/$path');
    if (await file.length() != expected.bytes) {
      throw FlutterError('Imported scene asset size mismatch: $path');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != expected.bytes || getCrc32(bytes) != expected.crc32) {
      throw FlutterError('Imported scene asset checksum mismatch: $path');
    }
    // Keep an exact buffer: some Spine versions ignore ByteData view offsets.
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}
