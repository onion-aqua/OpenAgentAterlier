import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'live2d_model_descriptor.dart';
import 'model_mapping_persistence.dart';
import 'model_package_store.dart';

const maxLive2dArchiveBytes = 128 * 1024 * 1024;
const maxLive2dExpandedBytes = 256 * 1024 * 1024;
const maxLive2dFileBytes = 128 * 1024 * 1024;
const maxLive2dArchiveEntries = 1024;

/// A model belongs to exactly one character, including its semantic manifest.
/// [directory] is the absolute directory containing [modelFileName].
class LocalLive2dModel {
  const LocalLive2dModel({
    required this.id,
    required this.characterId,
    required this.label,
    required this.directory,
    required this.modelFileName,
    this.manifestFileName,
    this.performanceMappingFileName,
    this.sourceFingerprint,
  });

  final String id;
  final String characterId;
  final String label;
  final String directory;
  final String modelFileName;
  final String? manifestFileName;
  final String? performanceMappingFileName;
  final String? sourceFingerprint;
}

/// Private, user-imported model packages, separate from portable settings data.
///
/// ZIP paths are validated before decompression, and only ordinary whitelisted
/// files are written. The index stores relative paths and is replaced only
/// after a complete package has been moved into its final directory.
class LocalLive2dStore {
  LocalLive2dStore._(this._packages);

  @visibleForTesting
  factory LocalLive2dStore.forTesting({ModelPackageStore? packageStore}) =>
      LocalLive2dStore._(packageStore ?? ModelPackageStore.forTesting());

  static final instance = LocalLive2dStore._(ModelPackageStore.instance);
  final ModelPackageStore _packages;

  Directory? _root;
  Future<void>? _initializing;
  Future<void> _pending = Future<void>.value();
  final List<_StoredLive2dModel> _records = [];

  List<LocalLive2dModel> get models =>
      List.unmodifiable(_records.map((record) => record.model(_root!)));

  List<LocalLive2dModel> modelsFor(String characterId) => List.unmodifiable(
    models.where((model) => model.characterId == characterId),
  );

  LocalLive2dModel? byId(String id, {required String characterId}) {
    for (final model in modelsFor(characterId)) {
      if (model.id == id) return model;
    }
    return null;
  }

  Future<void> initialize({Directory? storageDirectory}) {
    if (_root != null) return Future<void>.value();
    return _initializing ??= _initialize(storageDirectory).whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize(Directory? storageDirectory) async {
    final support = storageDirectory ?? await getApplicationSupportDirectory();
    await _packages.initialize(storageDirectory: support);
    final root = Directory('${support.path}/imported_live2d').absolute;
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.notFound &&
        rootType != FileSystemEntityType.directory) {
      throw const FileSystemException('Live2D 存储目录不是普通目录');
    }
    await root.create(recursive: true);
    final index = File('${root.path}/models.json');
    final indexType = await FileSystemEntity.type(
      index.path,
      followLinks: false,
    );
    final loaded = <_StoredLive2dModel>[];
    if (indexType != FileSystemEntityType.notFound) {
      if (indexType != FileSystemEntityType.file) {
        throw const FileSystemException('Live2D 模型索引不是普通文件');
      }
      if (await index.length() > 1024 * 1024) {
        throw const FormatException('Live2D 模型索引过大');
      }
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['models'] is! List) {
        throw const FormatException('Live2D 模型索引格式错误');
      }
      final ids = <String>{};
      for (final row in decoded['models'] as List) {
        try {
          final record = _StoredLive2dModel.fromJson(row);
          if (!ids.add(record.id)) continue;
          final relative = '${record.characterId}/${record.id}';
          await _restoreCacheIfMissing(root, record);
          await _requireOrdinaryPath(root, relative, directory: true);
          final folder = Directory('${root.path}/$relative');
          await _requireOrdinaryPath(folder, record.modelPath);
          if (record.manifestPath != null) {
            await _requireOrdinaryPath(folder, record.manifestPath!);
          }
          if (record.performanceMappingPath != null) {
            await _requireOrdinaryPath(folder, record.performanceMappingPath!);
            final mappingFile = File(
              '${folder.path}/${record.performanceMappingPath}',
            );
            if (await mappingFile.length() > maxPerformanceMappingBytes) {
              throw const FormatException(
                'Live2D performance mapping is too large',
              );
            }
            final mapping = decodeJsonObject(
              await mappingFile.readAsBytes(),
              'performance mapping',
            );
            if (mapping['format'] != 'live2d' ||
                mapping['sourceFingerprint'] != record.sourceFingerprint) {
              throw const FormatException(
                'Live2D performance mapping metadata does not match its index',
              );
            }
          }
          loaded.add(record);
          if (!await _packages.exists(record.id)) {
            await _ensureRecordPackage(root, record);
          }
        } on FormatException {
          // An invalid individual record cannot escape its character folder.
        } on FileSystemException {
          // Removed model folders are not restored as usable models.
        }
      }
    }
    _records
      ..clear()
      ..addAll(loaded);
    _root = root;
  }

  Future<LocalLive2dModel> importPackage(
    Uint8List bytes, {
    required String characterId,
    String? label,
    Map<String, Object?>? manifestOverride,
    Uint8List? performanceMapping,
  }) async {
    if (!_safeId(characterId)) {
      throw const FormatException('无效的 Live2D 角色标识');
    }
    await initialize();
    final decoded = await compute(_decodeLive2dZip, bytes);
    final files = Map<String, Uint8List>.of(decoded.files);
    var manifestPath = decoded.manifestPath;
    String? performanceMappingPath;
    Map<String, Object?>? storedMapping;
    final modelParent = _parentPath(decoded.modelPath);
    String besideModel(String name) =>
        modelParent.isEmpty ? name : '$modelParent/$name';
    if (manifestOverride != null) {
      late final Uint8List manifestBytes;
      try {
        manifestBytes = Uint8List.fromList(
          utf8.encode(jsonEncode(manifestOverride)),
        );
      } on Object {
        throw const FormatException('Invalid Live2D manifest override');
      }
      _validateLive2dManifestOverride(
        modelJson: utf8.decode(files[decoded.modelPath]!),
        manifest: manifestOverride,
      );
      manifestPath = besideModel('performance.manifest.json');
      files[manifestPath] = manifestBytes;
    }
    if (performanceMapping != null) {
      storedMapping = await validatePerformanceMapping(
        bytes: performanceMapping,
        sourceArchive: bytes,
        expectedFormat: 'live2d',
      );
      performanceMappingPath = besideModel(importedPerformanceMappingFileName);
      files[performanceMappingPath] = Uint8List.fromList(performanceMapping);
    }
    return _exclusive(() async {
      final root = _root!;
      final id = 'live2d_${_randomId()}';
      final staging = Directory('${root.path}/.staging_$id');
      final characterFolder = Directory('${root.path}/$characterId');
      final finalFolder = Directory('${characterFolder.path}/$id');
      var moved = false;
      var packaged = false;
      try {
        await staging.create();
        for (final entry in files.entries) {
          final file = File('${staging.path}/${entry.key}');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(entry.value, flush: true);
        }
        final type = await FileSystemEntity.type(
          characterFolder.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory) {
          throw const FileSystemException('Live2D 角色目录不是普通目录');
        }
        await characterFolder.create();
        await staging.rename(finalFolder.path);
        moved = true;
        final customLabel = label?.trim();
        final mappedLabel = storedMapping?['label'] as String?;
        final modelName = decoded.modelPath.split('/').last;
        final record = _StoredLive2dModel(
          id: id,
          characterId: characterId,
          label: customLabel?.isNotEmpty == true
              ? customLabel!.substring(0, min(customLabel.length, 120))
              : mappedLabel?.trim().isNotEmpty == true
              ? mappedLabel!.trim().substring(
                  0,
                  min(mappedLabel.trim().length, 120),
                )
              : modelName.substring(
                  0,
                  modelName.length - '.model3.json'.length,
                ),
          modelPath: decoded.modelPath,
          manifestPath: manifestPath,
          performanceMappingPath: performanceMappingPath,
          sourceFingerprint: storedMapping?['sourceFingerprint'] as String?,
        );
        await _packages.ensureModel(
          modelId: id,
          format: 'live2d',
          label: record.label,
          ownerCharacterId: characterId,
          files: files,
        );
        packaged = true;
        await _saveIndex([..._records, record]);
        _records.add(record);
        return record.model(root);
      } on Object {
        if (packaged) await _packages.deleteModel(id);
        // Both paths are derived solely from the store root and a random ID.
        final cleanup = moved ? finalFolder : staging;
        if (await cleanup.exists()) await cleanup.delete(recursive: true);
        rethrow;
      }
    });
  }

  /// Packages an older imported model without assigning the currently active
  /// app session to it. App session migration is an explicit controller step.
  Future<void> ensureModelPackage(
    String id, {
    required String characterId,
  }) async {
    await initialize();
    final record = _records
        .where((record) => record.id == id && record.characterId == characterId)
        .firstOrNull;
    if (record == null) throw const FormatException('Unknown Live2D model');
    await _ensureRecordPackage(_root!, record);
  }

  /// Rolls back only the supplied imported model. The index is committed
  /// before deleting resources, leaving them intact when persistence fails.
  Future<bool> removeImportedModel(
    String id, {
    required String characterId,
  }) async {
    await initialize();
    return _exclusive(() async {
      final record = _records
          .where(
            (record) => record.id == id && record.characterId == characterId,
          )
          .firstOrNull;
      if (record == null) return false;
      final root = _root!;
      await _ensureRecordPackage(root, record);
      final parent = '${root.path}/${record.characterId}';
      await _requireOrdinaryPath(root, record.characterId, directory: true);
      final folder = Directory('$parent/${record.id}');
      final type = await FileSystemEntity.type(folder.path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw const FileSystemException('Live2D cache is not a directory');
      }
      final previous = [..._records];
      final next = _records.where((item) => item != record).toList();
      await _saveIndex(next);
      _records
        ..clear()
        ..addAll(next);
      try {
        if (type == FileSystemEntityType.directory) {
          await folder.delete(recursive: true);
        }
        await _packages.deleteModel(id);
      } on Object {
        try {
          await _saveIndex(previous);
          _records
            ..clear()
            ..addAll(previous);
          await _restoreCacheIfMissing(root, record);
        } on Object {
          // The canonical ZIP is kept until every cache removal succeeds.
        }
        rethrow;
      }
      return true;
    });
  }

  Future<Uint8List> packageBytesFor(
    String id, {
    required String characterId,
  }) async {
    await ensureModelPackage(id, characterId: characterId);
    return _packages.packageBytes(id);
  }

  Future<Map<String, Uint8List>> _cachedFiles(
    Directory root,
    _StoredLive2dModel record,
  ) async {
    final relative = '${record.characterId}/${record.id}';
    await _requireOrdinaryPath(root, relative, directory: true);
    final folder = Directory('${root.path}/$relative');
    final files = <String, Uint8List>{};
    var total = 0;
    await for (final entity in folder.list(
      recursive: true,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) continue;
      if (type != FileSystemEntityType.file) {
        throw const FileSystemException('Live2D cache contains a link');
      }
      final relativePath = _safePath(
        entity.path.substring(folder.path.length + 1),
      );
      if (!_allowedFile(relativePath) &&
          relativePath != record.performanceMappingPath) {
        // Preserve all accepted model resources, while ignoring unrelated
        // cache artifacts that have never belonged to the model package.
        continue;
      }
      final file = File(entity.path);
      final length = await file.length();
      total += length;
      if (length > maxLive2dFileBytes ||
          total > maxLive2dExpandedBytes ||
          files.length >= maxLive2dArchiveEntries) {
        throw const FormatException('Live2D cache exceeds import limits');
      }
      files[relativePath] = await file.readAsBytes();
    }
    _validatePackageFiles(files, record);
    return files;
  }

  Future<void> _ensureRecordPackage(
    Directory root,
    _StoredLive2dModel record,
  ) async {
    if (await _packages.exists(record.id)) {
      _requirePackageOwner(record);
      return;
    }
    await _packages.ensureModel(
      modelId: record.id,
      format: 'live2d',
      label: record.label,
      ownerCharacterId: record.characterId,
      files: await _cachedFiles(root, record),
    );
  }

  void _requirePackageOwner(_StoredLive2dModel record) {
    final metadata = _packages.models
        .where((model) => model.modelId == record.id)
        .firstOrNull;
    if (metadata == null ||
        metadata.format != 'live2d' ||
        metadata.ownerCharacterId != record.characterId) {
      throw const FormatException(
        'Stored Live2D model belongs to another owner',
      );
    }
  }

  void _validatePackageFiles(
    Map<String, Uint8List> files,
    _StoredLive2dModel record,
  ) {
    final archive = Archive();
    for (final entry in files.entries) {
      if (entry.key != record.performanceMappingPath) {
        archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
      }
    }
    final decoded = _decodeLive2dZip(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    if (decoded.modelPath != record.modelPath ||
        decoded.manifestPath != record.manifestPath) {
      throw const FormatException('Stored Live2D model differs from its index');
    }
    if (record.performanceMappingPath case final String path) {
      final bytes = files[path];
      if (bytes == null || bytes.length > maxPerformanceMappingBytes) {
        throw const FormatException('Stored Live2D mapping is missing');
      }
      final mapping = decodeJsonObject(bytes, 'performance mapping');
      if (mapping['format'] != 'live2d' ||
          mapping['sourceFingerprint'] != record.sourceFingerprint) {
        throw const FormatException(
          'Stored Live2D mapping differs from its index',
        );
      }
    }
  }

  Future<void> _restoreCacheIfMissing(
    Directory root,
    _StoredLive2dModel record,
  ) async {
    final folder = Directory('${root.path}/${record.characterId}/${record.id}');
    final folderType = await FileSystemEntity.type(
      folder.path,
      followLinks: false,
    );
    if (folderType != FileSystemEntityType.directory &&
        folderType != FileSystemEntityType.notFound) {
      throw const FileSystemException('Live2D cache is not a directory');
    }
    if (folderType == FileSystemEntityType.directory) {
      try {
        // A surviving .model3.json is insufficient: textures or moc may have
        // been evicted separately from the cache.
        final modelFile = File('${folder.path}/${record.modelPath}');
        await _requireOrdinaryPath(
          root,
          '${record.characterId}/${record.id}/${record.modelPath}',
        );
        if (await modelFile.length() > 16 * 1024 * 1024) {
          throw const FormatException('Live2D model descriptor is too large');
        }
        final raw = jsonDecode(await modelFile.readAsString());
        if (raw is! Map || raw['FileReferences'] is! Map) {
          throw const FormatException('Invalid cached Live2D descriptor');
        }
        final parent = _parentPath(record.modelPath);
        for (final reference in _allModelReferences(
          raw['FileReferences'] as Map,
        )) {
          await _requireOrdinaryPath(
            folder,
            parent.isEmpty ? reference : '$parent/$reference',
          );
        }
        if (record.manifestPath case final String path) {
          await _requireOrdinaryPath(folder, path);
        }
        if (record.performanceMappingPath case final String path) {
          await _requireOrdinaryPath(folder, path);
        }
        return;
      } on FileSystemException {
        // Restore only from the authenticated local model package below.
      } on FormatException {
        // Validate the complete canonical payload before replacing cache.
      }
    }
    if (!await _packages.exists(record.id)) return;
    _requirePackageOwner(record);
    final files = await _packages.modelFiles(record.id);
    _validatePackageFiles(files, record);
    final characterFolder = folder.parent;
    final characterType = await FileSystemEntity.type(
      characterFolder.path,
      followLinks: false,
    );
    if (characterType != FileSystemEntityType.directory &&
        characterType != FileSystemEntityType.notFound) {
      throw const FileSystemException(
        'Live2D character cache is not a directory',
      );
    }
    await characterFolder.create(recursive: true);
    final staging = Directory('${root.path}/.restore_${_randomId()}');
    final previous = Directory('${root.path}/.previous_${_randomId()}');
    var movedPrevious = false;
    var committed = false;
    await staging.create();
    try {
      for (final entry in files.entries) {
        final path = _safePath(entry.key);
        final file = File('${staging.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      if (folderType == FileSystemEntityType.directory) {
        await folder.rename(previous.path);
        movedPrevious = true;
      }
      await staging.rename(folder.path);
      committed = true;
    } finally {
      if (!committed && movedPrevious) await previous.rename(folder.path);
      if (await staging.exists()) await staging.delete(recursive: true);
      if (committed && await previous.exists()) {
        await previous.delete(recursive: true);
      }
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _pending = _pending.then((_) async {
      try {
        result.complete(await operation());
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> _saveIndex(List<_StoredLive2dModel> records) async {
    final root = _root!;
    final temporary = File('${root.path}/.models_${_randomId()}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'models': records.map((record) => record.toJson()).toList(),
        }),
        flush: true,
      );
      await temporary.rename('${root.path}/models.json');
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class _StoredLive2dModel {
  const _StoredLive2dModel({
    required this.id,
    required this.characterId,
    required this.label,
    required this.modelPath,
    this.manifestPath,
    this.performanceMappingPath,
    this.sourceFingerprint,
  });

  factory _StoredLive2dModel.fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['characterId'] is! String ||
        value['label'] is! String ||
        value['modelPath'] is! String ||
        (value['manifestPath'] != null && value['manifestPath'] is! String) ||
        (value['performanceMappingPath'] != null &&
            value['performanceMappingPath'] is! String) ||
        (value['sourceFingerprint'] != null &&
            value['sourceFingerprint'] is! String)) {
      throw const FormatException('无效的 Live2D 模型记录');
    }
    final id = value['id'] as String;
    final characterId = value['characterId'] as String;
    final modelPath = _safePath(value['modelPath'] as String);
    final manifestPath = value['manifestPath'] == null
        ? null
        : _safePath(value['manifestPath'] as String);
    final performanceMappingPath = value['performanceMappingPath'] == null
        ? null
        : _safePath(value['performanceMappingPath'] as String);
    final sourceFingerprint = value['sourceFingerprint'] as String?;
    if (!_safeId(id) ||
        !_safeId(characterId) ||
        !modelPath.toLowerCase().endsWith('.model3.json') ||
        (manifestPath != null &&
            (!_isManifest(manifestPath) ||
                _parentPath(manifestPath) != _parentPath(modelPath))) ||
        (performanceMappingPath != null &&
            (performanceMappingPath.split('/').last !=
                    importedPerformanceMappingFileName ||
                _parentPath(performanceMappingPath) !=
                    _parentPath(modelPath))) ||
        (performanceMappingPath != null &&
            (sourceFingerprint == null ||
                !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sourceFingerprint))) ||
        (performanceMappingPath == null && sourceFingerprint != null)) {
      throw const FormatException('无效的 Live2D 模型路径');
    }
    return _StoredLive2dModel(
      id: id,
      characterId: characterId,
      label: value['label'] as String,
      modelPath: modelPath,
      manifestPath: manifestPath,
      performanceMappingPath: performanceMappingPath,
      sourceFingerprint: sourceFingerprint,
    );
  }

  final String id;
  final String characterId;
  final String label;
  final String modelPath;
  final String? manifestPath;
  final String? performanceMappingPath;
  final String? sourceFingerprint;

  LocalLive2dModel model(Directory root) {
    final parent = _parentPath(modelPath);
    return LocalLive2dModel(
      id: id,
      characterId: characterId,
      label: label,
      directory:
          '${root.path}/$characterId/$id${parent.isEmpty ? '' : '/$parent'}',
      modelFileName: modelPath.split('/').last,
      manifestFileName: manifestPath?.split('/').last,
      performanceMappingFileName: performanceMappingPath?.split('/').last,
      sourceFingerprint: sourceFingerprint,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'characterId': characterId,
    'label': label,
    'modelPath': modelPath,
    'manifestPath': manifestPath,
    'performanceMappingPath': performanceMappingPath,
    'sourceFingerprint': sourceFingerprint,
  };
}

void _validateLive2dManifestOverride({
  required String modelJson,
  required Map<String, Object?> manifest,
}) {
  final idle = manifest['idle'];
  if (idle != null && idle is! Map) {
    throw const FormatException('Live2D manifest idle must be an object');
  }
  for (final field in const ['actions', 'expressions', 'parameters']) {
    final value = manifest[field];
    if (value != null && value is! Map) {
      throw FormatException('Live2D manifest $field must be an object');
    }
  }
  late final Live2DModelDescriptor descriptor;
  try {
    descriptor = Live2DModelDescriptor.fromMaps(
      Map<String, Object?>.from(jsonDecode(modelJson) as Map),
      manifest: manifest,
    );
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('Invalid Live2D manifest override');
  }
  final actions = manifest['actions'] as Map? ?? const {};
  final expressions = manifest['expressions'] as Map? ?? const {};
  final parameters = manifest['parameters'] as Map? ?? const {};
  if (manifest.containsKey('idle') &&
      manifest['idle'] != null &&
      descriptor.idleMotion == null) {
    throw const FormatException('Live2D idle mapping is not in the model');
  }
  for (final key in actions.keys) {
    if (key is! String ||
        !descriptor.actionMappings.containsKey(_semanticMappingKey(key))) {
      throw FormatException('Live2D action mapping is not in the model: $key');
    }
  }
  for (final key in expressions.keys) {
    if (key is! String ||
        !descriptor.expressionMappings.containsKey(_semanticMappingKey(key))) {
      throw FormatException(
        'Live2D expression mapping is not in the model: $key',
      );
    }
  }
  for (final entry in parameters.entries) {
    if (entry.key is! String ||
        entry.value is! String ||
        descriptor.parameterBindings[entry.key] != entry.value) {
      throw FormatException(
        'Live2D parameter mapping is not in the model: ${entry.key}',
      );
    }
  }
}

String _semanticMappingKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');

class _DecodedLive2dPackage {
  const _DecodedLive2dPackage(this.files, this.modelPath, this.manifestPath);

  final Map<String, Uint8List> files;
  final String modelPath;
  final String? manifestPath;
}

_DecodedLive2dPackage _decodeLive2dZip(Uint8List bytes) {
  if (bytes.length > maxLive2dArchiveBytes) {
    throw const FormatException('Live2D ZIP 不能超过 128 MB');
  }
  try {
    // Read the central directory directly. ZipDecoder merges duplicate paths
    // and inflates symlinks before returning, so it cannot be our safety gate.
    final archive = ZipDirectory()..read(InputMemoryStream(bytes));
    if (archive.filePosition < 0 ||
        archive.numberOfThisDisk != 0 ||
        archive.diskWithTheStartOfTheCentralDirectory != 0 ||
        archive.fileHeaders.length != archive.totalCentralDirectoryEntries) {
      throw const FormatException('Live2D ZIP 格式错误或使用了分卷压缩');
    }
    if (archive.fileHeaders.length > maxLive2dArchiveEntries) {
      throw const FormatException('Live2D ZIP 最多包含 1024 项');
    }
    final seen = <String>{};
    final filePaths = <String>{};
    final requiredDirectories = <String>{};
    final entries = <(String, ZipFileHeader)>[];
    var total = 0;
    for (final entry in archive.fileHeaders) {
      final path = _safePath(entry.filename);
      final canonical = path.toLowerCase();
      if (!seen.add(canonical)) {
        throw FormatException('Live2D ZIP 包含重复路径：$path');
      }
      final mode = (entry.externalFileAttributes >> 16) & 0xf000;
      final isDirectory =
          entry.filename.endsWith('/') || entry.filename.endsWith('\\');
      if (mode != 0 && mode != 0x8000 && mode != 0x4000) {
        throw const FormatException('Live2D ZIP 不允许链接或特殊文件');
      }
      if ((entry.generalPurposeBitFlag & 1) != 0 ||
          (entry.file!.flags & 1) != 0) {
        throw const FormatException('Live2D ZIP 不支持密码保护');
      }
      if (isDirectory) {
        if (mode == 0x8000) {
          throw const FormatException('Live2D ZIP 文件类型冲突');
        }
        requiredDirectories.add(canonical);
        continue;
      }
      if (mode == 0x4000 || !_allowedFile(path)) {
        throw FormatException('Live2D ZIP 不支持此文件：$path');
      }
      if (entry.uncompressedSize < 0 ||
          entry.uncompressedSize > maxLive2dFileBytes) {
        throw const FormatException('Live2D 单个文件不能超过 128 MB');
      }
      total += entry.uncompressedSize;
      if (total > maxLive2dExpandedBytes) {
        throw const FormatException('Live2D ZIP 解压后不能超过 256 MB');
      }
      if (entry.compressionMethod != 0 && entry.compressionMethod != 8) {
        throw const FormatException('Live2D ZIP 仅支持 Store/Deflate 压缩');
      }
      final local = entry.file!;
      if (_safePath(local.filename) != path ||
          local.uncompressedSize != entry.uncompressedSize ||
          local.compressedSize != entry.compressedSize) {
        throw const FormatException('Live2D ZIP 文件头不一致');
      }
      filePaths.add(canonical);
      var parent = _parentPath(canonical);
      while (parent.isNotEmpty) {
        requiredDirectories.add(parent);
        parent = _parentPath(parent);
      }
      entries.add((path, entry));
    }
    if (filePaths.any(requiredDirectories.contains)) {
      throw const FormatException('Live2D ZIP 文件与目录路径冲突');
    }
    final modelPaths = entries
        .map((entry) => entry.$1)
        .where((path) => path.toLowerCase().endsWith('.model3.json'))
        .toList();
    if (modelPaths.length != 1) {
      throw const FormatException('Live2D ZIP 必须恰好包含一个 .model3.json');
    }
    final files = <String, Uint8List>{};
    for (final (path, entry) in entries) {
      // Enforce actual output size during inflation, even if the ZIP lies
      // about its uncompressed size in both headers.
      final output = _BoundedOutput(entry.uncompressedSize);
      entry.file!.decompress(output);
      final content = output.getBytes();
      if (content.length != entry.uncompressedSize ||
          getCrc32(content) != entry.crc32) {
        throw FormatException('Live2D ZIP 文件损坏：$path');
      }
      files[path] = content;
    }
    final modelPath = modelPaths.single;
    final parent = _parentPath(modelPath);
    String relativeToModel(String name) =>
        parent.isEmpty ? name : '$parent/$name';
    final manifestPath = [
      relativeToModel('performance.manifest.json'),
      relativeToModel('manifest.json'),
    ].where(files.containsKey).firstOrNull;
    final modelJson = utf8.decode(files[modelPath]!);
    final descriptor = Live2DModelDescriptor.parse(
      modelJson,
      manifestJson: manifestPath == null
          ? null
          : utf8.decode(files[manifestPath]!),
    );
    if (descriptor.mocFile == null || descriptor.textureFiles.isEmpty) {
      throw const FormatException('Live2D 模型必须包含 Moc 和 Textures 引用');
    }
    final references = <String>{
      descriptor.mocFile!,
      ...descriptor.textureFiles,
      if (descriptor.physicsFile != null) descriptor.physicsFile!,
      if (descriptor.poseFile != null) descriptor.poseFile!,
      for (final motions in descriptor.motions.values)
        for (final motion in motions) ...[
          motion.file,
          if (motion.sound != null) motion.sound!,
        ],
      for (final expression in descriptor.expressions) expression.file,
    };
    // Validate raw rows too: the catalog parser deliberately skips malformed
    // entries, which must not let an importer silently omit referenced files.
    final raw = jsonDecode(modelJson) as Map;
    final rawReferences = raw['FileReferences'] as Map;
    references.addAll(_allModelReferences(rawReferences));
    for (final reference in references) {
      final target = relativeToModel(_safePath(reference));
      if (!files.containsKey(target)) {
        throw FormatException('Live2D ZIP 缺少引用文件：$reference');
      }
      if (files[target]!.isEmpty) {
        throw FormatException('Live2D 引用文件为空：$reference');
      }
    }
    return _DecodedLive2dPackage(files, modelPath, manifestPath);
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    throw FormatException('Live2D ZIP 无法读取：${error.runtimeType}');
  }
}

Set<String> _allModelReferences(Map references) {
  final result = <String>{};
  String reference(Object? value, String field) {
    if (value is! String || value.isEmpty) {
      throw FormatException('Live2D FileReferences.$field 引用无效');
    }
    return _safePath(value);
  }

  for (final key in ['Moc', 'Physics', 'Pose', 'DisplayInfo', 'UserData']) {
    if (references.containsKey(key)) {
      result.add(reference(references[key], key));
    }
  }
  final textures = references['Textures'];
  if (textures is! List) {
    throw const FormatException('Live2D FileReferences.Textures 必须是数组');
  }
  for (final texture in textures) {
    result.add(reference(texture, 'Textures'));
  }
  final motions = references['Motions'];
  if (motions != null) {
    if (motions is! Map) {
      throw const FormatException('Live2D FileReferences.Motions 必须是对象');
    }
    for (final entry in motions.entries) {
      final rows = entry.value;
      if (entry.key is! String || rows is! List) {
        throw const FormatException('Live2D 动作组格式错误');
      }
      for (final row in rows) {
        if (row is! Map) {
          throw const FormatException('Live2D 动作引用格式错误');
        }
        result.add(reference(row['File'], 'Motions.${entry.key}.File'));
        if (row.containsKey('Sound')) {
          result.add(reference(row['Sound'], 'Motions.${entry.key}.Sound'));
        }
      }
    }
  }
  final expressions = references['Expressions'];
  if (expressions != null) {
    if (expressions is! List) {
      throw const FormatException('Live2D 表情引用必须是数组');
    }
    for (final row in expressions) {
      if (row is! Map ||
          row['Name'] is! String ||
          (row['Name'] as String).isEmpty) {
        throw const FormatException('Live2D 表情引用格式错误');
      }
      result.add(reference(row['File'], 'Expressions.File'));
    }
  }
  // Future scalar/list file references still have to stay inside the bundle.
  for (final entry in references.entries) {
    if (const {
      'Moc',
      'Physics',
      'Pose',
      'DisplayInfo',
      'UserData',
      'Textures',
      'Motions',
      'Expressions',
    }.contains(entry.key)) {
      continue;
    }
    final value = entry.value;
    if (value is String) {
      result.add(reference(value, '${entry.key}'));
    } else if (value is List && value.every((item) => item is String)) {
      for (final item in value) {
        result.add(reference(item, '${entry.key}'));
      }
    } else {
      throw FormatException('Live2D 不支持的文件引用结构：${entry.key}');
    }
  }
  return result;
}

class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.maximum) : super(size: min(maximum, 32 * 1024));
  final int maximum;

  void _check(int count) {
    if (count < 0 || length + count > maximum) {
      throw const FormatException('Live2D ZIP 实际解压大小超过声明');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}

bool _safeId(String value) => RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(value);

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _safePath(String value) {
  final path = value.replaceAll('\\', '/');
  if (path.isEmpty || path.startsWith('/') || path.length > 1024) {
    throw const FormatException('Live2D ZIP 必须使用包内相对路径');
  }
  final segments = path.split('/');
  if (segments.last.isEmpty) segments.removeLast();
  if (segments.isEmpty ||
      segments.any(
        (segment) =>
            segment.isEmpty ||
            segment == '.' ||
            segment == '..' ||
            segment.endsWith('.') ||
            segment.endsWith(' ') ||
            RegExp(r'[\x00-\x1f\x7f<>:"|?*]').hasMatch(segment) ||
            RegExp(
              r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(segment),
      )) {
    throw const FormatException('Live2D ZIP 包含不安全或不兼容的路径');
  }
  return segments.join('/');
}

String _parentPath(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

bool _isManifest(String path) => const {
  'manifest.json',
  'performance.manifest.json',
}.contains(path.split('/').last.toLowerCase());

bool _allowedFile(String path) {
  final lower = path.toLowerCase();
  return _isManifest(path) ||
      const [
        '.model3.json',
        '.moc3',
        '.motion3.json',
        '.exp3.json',
        '.physics3.json',
        '.pose3.json',
        '.cdi3.json',
        '.userdata3.json',
        '.png',
        '.jpg',
        '.jpeg',
        '.wav',
        '.mp3',
      ].any(lower.endsWith);
}

Future<void> _requireOrdinaryPath(
  Directory root,
  String relative, {
  bool directory = false,
}) async {
  final segments = _safePath(relative).split('/');
  var path = root.path;
  for (var i = 0; i < segments.length; i++) {
    path = '$path/${segments[i]}';
    final type = await FileSystemEntity.type(path, followLinks: false);
    final expected = i < segments.length - 1 || directory
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
    if (type != expected) {
      throw const FileSystemException('Live2D 模型文件缺失或包含链接');
    }
  }
}
