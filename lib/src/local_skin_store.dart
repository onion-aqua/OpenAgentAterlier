import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'character_idle_behavior.dart';
import 'model_package_store.dart';
import 'model_mapping_persistence.dart';
import 'spine_control_templates.dart';
import 'spine36_player.dart';

const maxSkinImportBytes = 64 * 1024 * 1024;

/// ZIPs are read into a whitelist, never extracted using archive paths.
Map<String, Uint8List> decodeSkinZip(
  Uint8List bytes, {
  Uint8List? gestureTemplate,
  bool requireGesture = true,
}) {
  if (bytes.length > maxSkinImportBytes) {
    throw const FormatException('ZIP exceeds 64 MB');
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final files = <String, Uint8List>{};
  var total = 0;
  if (archive.length > 64) throw const FormatException('Too many ZIP entries');
  for (final entry in archive) {
    final path = entry.name.replaceAll('\\', '/');
    if (path.startsWith('/') ||
        path.contains(':') ||
        path.split('/').contains('..') ||
        entry.isSymbolicLink) {
      throw const FormatException('Unsafe ZIP path');
    }
    if (!entry.isFile) continue;
    total += entry.size;
    if (entry.size < 0 || total > maxSkinImportBytes) {
      throw const FormatException('Expanded ZIP exceeds 64 MB');
    }
    final name = path.split('/').last;
    if (!RegExp(r'^[a-zA-Z0-9_.-]+\.(atlas|png|skel|json)$').hasMatch(name)) {
      continue;
    }
    if (files.containsKey(name)) throw const FormatException('Duplicate file');
    final data = entry.readBytes();
    if (data == null || data.length != entry.size) {
      throw const FormatException('Invalid ZIP entry');
    }
    files[name] = data;
  }
  final atlases = files.keys.where((name) => name.endsWith('.atlas')).toList();
  if (atlases.length != 1) throw const FormatException('Expected one atlas');
  final base = atlases.single.replaceFirst(RegExp(r'\.atlas$'), '');
  if (!files.containsKey('$base.png')) {
    throw FormatException('Missing $base.png');
  }
  final skeletonFiles = [
    for (final extension in const ['skel', 'json'])
      if (files.containsKey('$base.$extension')) '$base.$extension',
  ];
  if (skeletonFiles.length != 1) {
    throw const FormatException(
      'Expected exactly one matching .skel or .json skeleton',
    );
  }
  final atlas = utf8.decode(files['$base.atlas']!);
  final pages = atlas
      .split(RegExp(r'\r?\n'))
      .where((line) => line.trim().endsWith('.png'))
      .toList();
  if (pages.length != 1 || pages.single.trim() != '$base.png') {
    throw const FormatException('Expected a single matching PNG atlas page');
  }
  final gestureName = '${base}_gesture.json';
  if (gestureTemplate != null) files[gestureName] = gestureTemplate;
  final gestureBytes = files[gestureName];
  if (gestureBytes != null) {
    _validateGesture(gestureBytes);
  } else if (requireGesture) {
    throw FormatException('Missing $gestureName; choose a control template');
  }
  final skeletonName = skeletonFiles.single;
  _validateSpineSkeleton(skeletonName, files[skeletonName]!);
  final dimensions = pngSize(files['$base.png']!);
  final declaredSize = RegExp(
    r'^size:\s*(\d+)\s*,\s*(\d+)',
    multiLine: true,
  ).firstMatch(atlas);
  if (declaredSize == null ||
      dimensions !=
          (int.parse(declaredSize[1]!), int.parse(declaredSize[2]!))) {
    throw const FormatException('PNG dimensions do not match the atlas');
  }
  final preview = [
    '${base}_preview.png',
    '$base-preview.png',
    'preview.png',
    'cover.png',
    'thumbnail.png',
  ].where((name) => name != '$base.png' && files.containsKey(name)).firstOrNull;
  if (preview != null) pngSize(files[preview]!);
  return {
    '$base.atlas': files['$base.atlas']!,
    '$base.png': files['$base.png']!,
    skeletonName: files[skeletonName]!,
    gestureName: ?gestureBytes,
    ?preview: files[preview]!,
  };
}

Map<String, Uint8List> _decodeSkinZipForImport(Uint8List bytes) =>
    decodeSkinZip(bytes, requireGesture: false);

void _validateGesture(Uint8List bytes) {
  final gesture = jsonDecode(utf8.decode(bytes));
  if (gesture is! Map ||
      gesture['emotionalGesture'] is! Map ||
      gesture['emotionalGesture']['MotionGroups'] is! List) {
    throw const FormatException('Invalid gesture mapping');
  }
}

void _validateSpineSkeleton(String name, Uint8List bytes) {
  if (name.endsWith('.skel')) {
    // Spine 4.2 binary header: 8-byte hash followed by varint UTF-8 version.
    if (bytes.length < 14 ||
        bytes[8] < 4 ||
        bytes[8] > 32 ||
        String.fromCharCodes(bytes.sublist(9, 13)) != '4.2.') {
      throw const FormatException('Only Spine 4.2 skeletons are supported');
    }
    return;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on Object {
    throw const FormatException('Invalid Spine skeleton JSON');
  }
  final skeleton = decoded is Map ? decoded['skeleton'] : null;
  final version = skeleton is Map ? skeleton['spine'] : null;
  if (version is! String || version.trim().isEmpty) {
    throw const FormatException('Spine skeleton JSON is missing its version');
  }
  if (!isSpine36(version) && !RegExp(r'^4\.2(?:\.|$)').hasMatch(version)) {
    throw const FormatException(
      'Only Spine 3.6 JSON / 4.2 skeletons are supported',
    );
  }
}

String spineSkeletonExtension(Map<String, Uint8List> files, String base) {
  for (final extension in const ['skel', 'json']) {
    if (files.containsKey('$base.$extension')) return extension;
  }
  throw const FormatException('Missing Spine skeleton data');
}

Map<String, Object?> _gestureRuntime(Uint8List bytes) {
  final root = decodeJsonObject(bytes, 'gesture mapping');
  final modelMapping = root['ModelMapping'];
  final runtime =
      root['ModelMapping.Runtime'] ??
      (modelMapping is Map ? modelMapping['Runtime'] : null);
  if (runtime is! Map || runtime.keys.any((key) => key is! String)) {
    return const {};
  }
  return Map<String, Object?>.from(runtime);
}

List<String> _runtimeStringList(Object? value) {
  if (value is! List) return const [];
  final result = <String>[];
  for (final item in value) {
    if (item is! String || item.trim().isEmpty) {
      throw const FormatException('Invalid gesture runtime metadata');
    }
    result.add(item.trim());
  }
  return result;
}

void _validateMappedSpineRuntime(
  Map<String, Object?> runtime, {
  required String sourceFingerprint,
}) {
  if (runtime['schemaVersion'] != 1 ||
      runtime['sourceFingerprint'] != sourceFingerprint ||
      runtime['posture'] is! String ||
      (runtime['posture'] as String).trim().isEmpty ||
      runtime['rigProfile'] != 'generic_spine') {
    throw const FormatException('Invalid mapped Spine runtime metadata');
  }
  if (_runtimeStringList(runtime['idleAnimations']).isEmpty) {
    throw const FormatException(
      'Mapped Spine resources require an idle animation',
    );
  }
  final actions = runtime['actions'];
  final expressions = runtime['expressions'];
  final parameters = runtime['parameters'];
  if (actions is! Map || expressions is! Map || parameters is! Map) {
    throw const FormatException('Invalid mapped Spine runtime capabilities');
  }
  for (final entry in actions.entries) {
    final value = entry.value;
    if (entry.key is! String || value is! Map) {
      throw const FormatException('Invalid mapped Spine action');
    }
    final animation = value['animation'];
    final description = value['description'];
    final confidence = value['confidence'];
    final evidence = value['evidence'];
    if (animation is! String ||
        animation.trim().isEmpty ||
        description is! String ||
        description.trim().isEmpty ||
        confidence is! num ||
        !confidence.isFinite ||
        confidence < 0 ||
        confidence > 1 ||
        evidence is! String ||
        evidence.trim().isEmpty) {
      throw const FormatException('Invalid mapped Spine action');
    }
  }
  for (final map in [expressions, parameters]) {
    if (map.entries.any(
      (entry) =>
          entry.key is! String ||
          entry.value is! String ||
          (entry.value as String).trim().isEmpty,
    )) {
      throw const FormatException('Invalid mapped Spine capability');
    }
  }
}

(int, int) pngSize(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 ||
      !listEquals(bytes.take(8).toList(), signature) ||
      String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') {
    throw const FormatException('Expected a PNG texture');
  }
  final data = ByteData.sublistView(bytes);
  final width = data.getUint32(16), height = data.getUint32(20);
  if (width == 0 ||
      height == 0 ||
      width > 8192 ||
      height > 8192 ||
      width * height > 33554432) {
    throw const FormatException('Invalid or oversized PNG');
  }
  return (width, height);
}

class LocalSkinStore {
  LocalSkinStore._(this._packages);
  @visibleForTesting
  factory LocalSkinStore.forTesting({ModelPackageStore? packageStore}) =>
      LocalSkinStore._(packageStore ?? ModelPackageStore.forTesting());
  static final instance = LocalSkinStore._(ModelPackageStore.instance);
  final ModelPackageStore _packages;
  Directory? _root;
  Future<void>? _initializing;
  SharedPreferences? _prefs;
  final List<Map<String, String>> skins = [];
  final Map<String, Map<String, dynamic>> _textures = {};

  Future<void> initialize({Directory? storageDirectory}) {
    final pending = _initializing;
    if (pending != null) return pending;
    if (_root != null) return Future<void>.value();
    return _initializing = _initialize(storageDirectory).whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize(Directory? storageDirectory) async {
    final directory =
        storageDirectory ?? await getApplicationSupportDirectory();
    await _packages.initialize(storageDirectory: directory);
    final root = Directory('${directory.path}/imported_skins');
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.notFound &&
        rootType != FileSystemEntityType.directory) {
      throw const FileSystemException('Spine storage is not a directory');
    }
    _root = await root.create(recursive: true);
    _prefs = await SharedPreferences.getInstance();
    for (final text
        in _prefs!.getStringList('localSkinPackages') ?? <String>[]) {
      try {
        final record = Map<String, String>.from(jsonDecode(text) as Map);
        // Older versions saved every imported model as Ryza in a flat folder.
        record.putIfAbsent('characterId', () => 'ryza');
        record.putIfAbsent('skeletonExtension', () => 'skel');
        final skeletonExtension = record['skeletonExtension']!;
        if (_safe(record['id']!) &&
            _safe(record['base']!) &&
            _safe(record['characterId']!) &&
            _validSkeletonExtension(skeletonExtension)) {
          await _restoreCacheIfMissing(record);
          if (!await File(
            '${_folderFor(record)}/${record['base']}.$skeletonExtension',
          ).exists()) {
            continue;
          }
          final sourceFingerprint = record['sourceFingerprint'];
          if (sourceFingerprint != null) {
            if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sourceFingerprint)) {
              continue;
            }
            final mappingFile = File(
              '${_folderFor(record)}/$importedPerformanceMappingFileName',
            );
            if (!await mappingFile.exists() ||
                await mappingFile.length() > maxPerformanceMappingBytes) {
              continue;
            }
            final mapping = decodeJsonObject(
              await mappingFile.readAsBytes(),
              'performance mapping',
            );
            if (mapping['format'] != 'spine' ||
                mapping['sourceFingerprint'] != sourceFingerprint) {
              continue;
            }
          }
          final preview = record['preview'];
          if (preview != null &&
              (!_validPreviewName(preview, record['base']!) ||
                  !await File('${_folderFor(record)}/$preview').exists())) {
            record.remove('preview');
          }
          skins.add(record);
          // Migration only packages model resources. The controller decides
          // explicitly which existing app session belongs to this model.
          if (!await _packages.exists(record['id']!)) {
            await _ensureRecordPackage(record);
          }
        }
      } on Object {
        /* Ignore invalid metadata without touching the user's files. */
      }
    }
    try {
      final saved =
          jsonDecode(_prefs!.getString('localSkinTextures') ?? '{}') as Map;
      for (final entry in saved.entries) {
        final value = Map<String, dynamic>.from(entry.value as Map);
        if (_safe(entry.key as String) && _safe(value['file'] as String)) {
          _textures[entry.key as String] = value;
        }
      }
    } on Object {
      _textures.clear();
    }
    for (final record in skins) {
      try {
        await _restoreModelAttachments(record);
      } on Object {
        // A damaged optional customization must not hide the original model.
      }
    }
  }

  static bool _safe(String name) => RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name);

  static bool _validSkeletonExtension(String value) =>
      value == 'skel' || value == 'json';

  String _folderFor(Map<String, String> record) =>
      record['storageLayout'] == 'character'
      ? '${_root!.path}/${record['characterId']}/${record['id']}'
      : '${_root!.path}/${record['id']}';

  Future<Map<String, Uint8List>> _cachedFiles(
    Map<String, String> record,
  ) async {
    await _requireCacheParent(record);
    final folder = Directory(_folderFor(record));
    final folderType = await FileSystemEntity.type(
      folder.path,
      followLinks: false,
    );
    if (folderType != FileSystemEntityType.directory) {
      throw const FileSystemException('Spine model cache is not a directory');
    }
    final base = record['base']!;
    final names = <String>{
      '$base.atlas',
      '$base.png',
      '$base.${record['skeletonExtension'] ?? 'skel'}',
      '${base}_gesture.json',
      if (record['preview'] case final String preview) preview,
      if (record['sourceFingerprint'] != null)
        importedPerformanceMappingFileName,
    };
    final files = <String, Uint8List>{};
    var total = 0;
    for (final name in names) {
      final path = '${folder.path}/$name';
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException(
          'Spine model file is missing or a link',
        );
      }
      final file = File(path);
      total += await file.length();
      if (total > maxSkinImportBytes) {
        throw const FormatException('Expanded Spine model exceeds 64 MB');
      }
      files[name] = await file.readAsBytes();
    }
    return files;
  }

  Future<void> _ensureRecordPackage(Map<String, String> record) async {
    if (await _packages.exists(record['id']!)) {
      _requirePackageOwner(record);
      return;
    }
    final files = await _cachedFiles(record);
    final archive = Archive();
    for (final entry in files.entries) {
      if (entry.key != importedPerformanceMappingFileName) {
        archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
      }
    }
    decodeSkinZip(Uint8List.fromList(ZipEncoder().encode(archive)));
    await _packages.ensureModel(
      modelId: record['id']!,
      format: 'spine',
      label: record['label'] ?? record['base']!,
      ownerCharacterId: record['characterId']!,
      files: files,
    );
  }

  void _requirePackageOwner(Map<String, String> record) {
    final metadata = _packages.models
        .where((model) => model.modelId == record['id'])
        .firstOrNull;
    if (metadata == null ||
        metadata.format != 'spine' ||
        metadata.ownerCharacterId != record['characterId']) {
      throw const FormatException(
        'Stored Spine model belongs to another owner',
      );
    }
  }

  /// Creates the canonical ZIP for an older imported model, preserving any
  /// model session already present in the package.
  Future<void> ensureModelPackage(
    String id, {
    required String characterId,
  }) async {
    await initialize();
    final record = skinsFor(characterId)
        .where((record) => record['id'] == id)
        .firstOrNull;
    if (record == null) throw const FormatException('Unknown Spine model');
    await _ensureRecordPackage(record);
  }

  Future<Uint8List> packageBytesFor(
    String id, {
    required String characterId,
  }) async {
    await ensureModelPackage(id, characterId: characterId);
    return _packages.packageBytes(id);
  }

  Future<void> _restoreCacheIfMissing(Map<String, String> record) async {
    await _requireCacheParent(record);
    final folder = Directory(_folderFor(record));
    final skeleton = File(
      '${folder.path}/${record['base']}.${record['skeletonExtension']}',
    );
    // Restore partially removed caches too, rather than treating the skeleton
    // alone as proof that the runtime can open the model.
    final required = <String>[
      skeleton.path,
      '${folder.path}/${record['base']}.atlas',
      '${folder.path}/${record['base']}.png',
      '${folder.path}/${record['base']}_gesture.json',
      if (record['sourceFingerprint'] != null)
        '${folder.path}/$importedPerformanceMappingFileName',
      if (record['preview'] case final String preview)
        '${folder.path}/$preview',
    ];
    if ((await Future.wait(required.map((path) => File(path).exists())))
        .every((exists) => exists)) {
      return;
    }
    if (!await _packages.exists(record['id']!)) return;
    _requirePackageOwner(record);
    final files = await _packages.modelFiles(record['id']!);
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    final restored = decodeSkinZip(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    final base = record['base']!;
    if (!restored.containsKey('$base.${record['skeletonExtension']}')) {
      throw const FormatException(
        'Stored Spine model does not match its index',
      );
    }
    final mapping = files[importedPerformanceMappingFileName];
    if (record['sourceFingerprint'] != null) {
      if (mapping == null || mapping.length > maxPerformanceMappingBytes) {
        throw const FormatException(
          'Stored Spine performance mapping is missing',
        );
      }
      final metadata = decodeJsonObject(mapping, 'performance mapping');
      if (metadata['format'] != 'spine' ||
          metadata['sourceFingerprint'] != record['sourceFingerprint']) {
        throw const FormatException('Stored Spine performance mapping differs');
      }
      restored[importedPerformanceMappingFileName] = mapping;
    }
    final folderType = await FileSystemEntity.type(
      folder.path,
      followLinks: false,
    );
    if (folderType != FileSystemEntityType.directory &&
        folderType != FileSystemEntityType.notFound) {
      throw const FileSystemException('Spine model cache is not a directory');
    }
    final parentType = await FileSystemEntity.type(
      folder.parent.path,
      followLinks: false,
    );
    if (parentType != FileSystemEntityType.directory &&
        parentType != FileSystemEntityType.notFound) {
      throw const FileSystemException('Spine cache parent is not a directory');
    }
    await folder.parent.create(recursive: true);
    final staging = Directory(
      '${folder.parent.path}/.restore_${record['id']}_${DateTime.now().microsecondsSinceEpoch}',
    );
    final previous = Directory(
      '${folder.parent.path}/.previous_${record['id']}_${DateTime.now().microsecondsSinceEpoch}',
    );
    var movedPrevious = false;
    var committed = false;
    await staging.create();
    try {
      for (final entry in restored.entries) {
        await File('${staging.path}/${entry.key}')
            .writeAsBytes(entry.value, flush: true);
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

  Future<void> _requireCacheParent(Map<String, String> record) async {
    if (record['storageLayout'] != 'character') return;
    final parent = '${_root!.path}/${record['characterId']}';
    final type = await FileSystemEntity.type(parent, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw const FileSystemException('Spine character cache contains a link');
    }
  }

  Map<String, String>? _recordForId(String id) =>
      skins.where((record) => record['id'] == id).firstOrNull;

  /// Rebuilds the optional texture cache from the model ZIP. Original runtime
  /// model bytes and their mapping fingerprint remain unchanged.
  Future<void> restoreModelAttachments(
    String id, {
    required String characterId,
  }) async {
    await initialize();
    final record = skinsFor(characterId)
        .where((record) => record['id'] == id)
        .firstOrNull;
    if (record == null) throw const FormatException('Unknown Spine model');
    await _restoreModelAttachments(record);
  }

  Future<void> _restoreModelAttachments(Map<String, String> record) async {
    final id = record['id']!;
    await _ensureRecordPackage(record);
    final cached = _textures[id];
    final cachedFile = cached == null
        ? null
        : File('${_root!.path}/${cached['file']}.png');
    final hasCached =
        cachedFile != null &&
        await FileSystemEntity.type(cachedFile.path, followLinks: false) ==
            FileSystemEntityType.file;
    final bytes = await _packages.readAttachment(id, 'texture.png');
    if (bytes == null) {
      if (hasCached) {
        await _saveTextureAttachments(
          id,
          await cachedFile.readAsBytes(),
          enabled: cached!['enabled'] == true,
        );
      }
      return;
    }
    if (hasCached) return;
    if (bytes.length > maxSkinImportBytes ||
        pngSize(bytes) !=
            pngSize(
              await File('${_folderFor(record)}/${record['base']}.png')
                  .readAsBytes(),
            )) {
      throw const FormatException(
        'Stored custom texture differs in dimensions',
      );
    }
    final stateBytes = await _packages.readAttachment(id, 'texture-state.json');
    var enabled = true;
    if (stateBytes != null) {
      final state = decodeJsonObject(stateBytes, 'texture state');
      if (state['enabled'] is! bool) {
        throw const FormatException('Invalid stored custom texture state');
      }
      enabled = state['enabled'] as bool;
    }
    final fileName = 'texture_${DateTime.now().microsecondsSinceEpoch}';
    final file = File('${_root!.path}/$fileName.png');
    await file.writeAsBytes(bytes, flush: true);
    final next = {
      ..._textures,
      id: <String, dynamic>{'file': fileName, 'enabled': enabled},
    };
    if (!await _prefs!.setString('localSkinTextures', jsonEncode(next))) {
      await file.delete();
      throw const FileSystemException(
        'Could not restore custom texture settings',
      );
    }
    _textures[id] = next[id]!;
  }

  Future<void> _saveTextureAttachments(
    String id,
    Uint8List? bytes, {
    required bool enabled,
  }) async {
    final record = _recordForId(id);
    if (record == null) return;
    await _ensureRecordPackage(record);
    await _packages.saveAttachments(id, {
      'texture.png': bytes,
      'texture-state.json': bytes == null
          ? null
          : Uint8List.fromList(utf8.encode(jsonEncode({'enabled': enabled}))),
    });
  }

  Future<Map<String, Uint8List?>?> _textureAttachmentSnapshot(String id) async {
    final record = _recordForId(id);
    if (record == null) return null;
    await _ensureRecordPackage(record);
    return {
      'texture.png': await _packages.readAttachment(id, 'texture.png'),
      'texture-state.json': await _packages.readAttachment(
        id,
        'texture-state.json',
      ),
    };
  }

  Iterable<Map<String, String>> skinsFor(String characterId) =>
      skins.where((record) => (record['characterId'] ?? 'ryza') == characterId);

  bool containsPackage(String id, {String characterId = 'ryza'}) =>
      skinsFor(characterId).any((record) => record['id'] == id);

  static bool _validPreviewName(String name, String base) =>
      name != '$base.png' &&
      [
        '${base}_preview.png',
        '$base-preview.png',
        'preview.png',
        'cover.png',
        'thumbnail.png',
      ].contains(name);

  /// Validates a ZIP and resolves its control mapping without saving files.
  /// Callers can check the actual Spine skeleton before committing the import.
  Future<Map<String, Uint8List>> preparePackage(
    Uint8List bytes, {
    String? templateId,
    Uint8List? gestureMapping,
    Uint8List? performanceMapping,
    bool preserveCompatibleTemplate = false,
  }) async {
    if (gestureMapping == null &&
        templateId != null &&
        SpineControlTemplates.byId(templateId) == null) {
      throw FormatException('Unknown Spine control template: $templateId');
    }
    final files = await compute(_decodeSkinZipForImport, bytes);
    final base = files.keys
        .firstWhere((name) => name.endsWith('.atlas'))
        .replaceFirst(RegExp(r'\.atlas$'), '');
    if (!_safe(base)) throw const FormatException('Invalid skin name');
    final gestureName = '${base}_gesture.json';
    final compatibleTemplate = SpineControlTemplates.templateForBase(base);
    if (preserveCompatibleTemplate) {
      if (performanceMapping == null || gestureMapping != null) {
        throw const FormatException(
          'Preserving a Spine template requires a performance mapping and no generated gesture mapping',
        );
      }
      if (compatibleTemplate == null ||
          (templateId != null && templateId != compatibleTemplate.id)) {
        throw const FormatException(
          'The selected Spine package has no exact compatible control template',
        );
      }
    }
    Map<String, Object?>? validatedPerformance;
    if (performanceMapping != null) {
      if (gestureMapping == null && !preserveCompatibleTemplate) {
        throw const FormatException(
          'A Spine performance mapping requires its generated gesture mapping',
        );
      }
      validatedPerformance = await validatePerformanceMapping(
        bytes: performanceMapping,
        sourceArchive: bytes,
        expectedFormat: 'spine',
      );
      files[importedPerformanceMappingFileName] = Uint8List.fromList(
        performanceMapping,
      );
    }
    if (gestureMapping != null) {
      _validateGesture(gestureMapping);
      files[gestureName] = Uint8List.fromList(gestureMapping);
      if (validatedPerformance != null) {
        _validateMappedSpineRuntime(
          _gestureRuntime(gestureMapping),
          sourceFingerprint:
              validatedPerformance['sourceFingerprint'] as String,
        );
      }
      return files;
    }
    final selectedTemplate = preserveCompatibleTemplate
        ? compatibleTemplate
        : templateId != null
        ? SpineControlTemplates.byId(templateId)
        : files.containsKey(gestureName)
        ? null
        : compatibleTemplate;
    if (selectedTemplate != null) {
      final gesture = await SpineControlTemplates.read(selectedTemplate.id);
      _validateGesture(gesture);
      files[gestureName] = gesture;
    } else if (files.containsKey(gestureName)) {
      if (compatibleTemplate != null) {
        final reference = await SpineControlTemplates.read(
          compatibleTemplate.id,
        );
        // Preserve the package's own groups, poses and explicit empty bindings.
        // Only missing ambient drivers use the known rig's data-only template.
        files[gestureName] = Uint8List.fromList(
          utf8.encode(
            restoreMissingIdleDrivers(
              utf8.decode(files[gestureName]!),
              utf8.decode(reference),
            ),
          ),
        );
      }
    } else if (!files.containsKey(gestureName)) {
      throw FormatException(
        'Missing $gestureName; choose a compatible Spine control template',
      );
    }
    return files;
  }

  Future<Map<String, String>> importPackage(
    Uint8List bytes, {
    String characterId = 'ryza',
    String? templateId,
    Uint8List? gestureMapping,
    Uint8List? performanceMapping,
    bool preserveCompatibleTemplate = false,
  }) async {
    if (!_safe(characterId)) {
      throw const FormatException('Invalid character ID');
    }
    await initialize();
    final files = await preparePackage(
      bytes,
      templateId: templateId,
      gestureMapping: gestureMapping,
      performanceMapping: performanceMapping,
      preserveCompatibleTemplate: preserveCompatibleTemplate,
    );
    final base = files.keys
        .firstWhere((name) => name.endsWith('.atlas'))
        .replaceFirst(RegExp(r'\.atlas$'), '');
    final skeletonExtension = spineSkeletonExtension(files, base);
    final selectedTemplate = preserveCompatibleTemplate
        ? SpineControlTemplates.templateForBase(base)
        : gestureMapping == null && templateId != null
        ? SpineControlTemplates.byId(templateId)
        : gestureMapping == null
        ? SpineControlTemplates.templateForBase(base)
        : null;
    final preview = files.keys
        .where((name) => _validPreviewName(name, base))
        .firstOrNull;
    final runtime = gestureMapping == null
        ? const <String, Object?>{}
        : _gestureRuntime(files['${base}_gesture.json']!);
    final idleAnimations = _runtimeStringList(runtime['idleAnimations']);
    String? runtimeText(String key) {
      final value = runtime[key];
      if (value == null) return null;
      if (value is! String || value.trim().isEmpty || value.length > 80) {
        throw const FormatException('Invalid gesture runtime metadata');
      }
      return value.trim();
    }

    final posture = runtimeText('posture');
    final rigProfile = preserveCompatibleTemplate
        ? 'ryza'
        : runtimeText('rigProfile');
    final storedMapping = performanceMapping == null
        ? null
        : decodeJsonObject(performanceMapping, 'performance mapping');
    final mappedLabel = storedMapping?['label'];
    if (mappedLabel != null &&
        (mappedLabel is! String || mappedLabel.trim().isEmpty)) {
      throw const FormatException('Invalid performance mapping label');
    }
    final id = 'local_${DateTime.now().microsecondsSinceEpoch}';
    final record = {
      'id': id,
      'base': base,
      'characterId': characterId,
      'storageLayout': 'character',
      'skeletonExtension': skeletonExtension,
      'spineVersion': skeletonExtension == 'json'
          ? ((jsonDecode(utf8.decode(files['$base.json']!)) as Map)['skeleton']
                    as Map)['spine']
                as String
          : '4.2',
      if (selectedTemplate != null) 'templateId': selectedTemplate.id,
      'posture': ?posture,
      'rigProfile': ?rigProfile,
      if (idleAnimations.isNotEmpty)
        'idleAnimations': jsonEncode(idleAnimations),
      if (storedMapping?['sourceFingerprint'] case final String fingerprint)
        'sourceFingerprint': fingerprint,
      'label': mappedLabel is String
          ? (mappedLabel.trim().length <= 120
                ? mappedLabel.trim()
                : mappedLabel.trim().substring(0, 120))
          : '$base · ${skins.length + 1}',
      'preview': ?preview,
    };
    await _requireCacheParent(record);
    final folder = await Directory(_folderFor(record)).create(recursive: true);
    var packaged = false;
    try {
      for (final entry in files.entries) {
        await File('${folder.path}/${entry.key}')
            .writeAsBytes(entry.value, flush: true);
      }
      await _packages.ensureModel(
        modelId: id,
        format: 'spine',
        label: record['label']!,
        ownerCharacterId: characterId,
        files: files,
      );
      packaged = true;
      final next = [...skins, record];
      if (!await _prefs!.setStringList(
        'localSkinPackages',
        next.map(jsonEncode).toList(),
      )) {
        throw const FileSystemException('Could not save skin settings');
      }
    } on Object {
      if (packaged) await _packages.deleteModel(id);
      await folder.delete(recursive: true);
      rethrow;
    }
    skins.add(record);
    return record;
  }

  Future<Map<String, Uint8List>?> filesFor(
    String id, {
    String characterId = 'ryza',
  }) async {
    await initialize();
    final records = skinsFor(characterId).where((record) => record['id'] == id);
    if (records.isEmpty) return null;
    await _restoreCacheIfMissing(records.first);
    final base = records.first['base']!;
    final skeletonExtension = records.first['skeletonExtension'] ?? 'skel';
    if (!_validSkeletonExtension(skeletonExtension)) return null;
    final folder = _folderFor(records.first);
    final root = 'assets/character/$characterId/$id';
    final files = <String, Uint8List>{};
    for (final suffix in ['.atlas', '.$skeletonExtension', '_gesture.json']) {
      files['$root/$id$suffix'] = await File('$folder/$base$suffix')
          .readAsBytes();
    }
    files['$root/$base.png'] = await File('$folder/$base.png').readAsBytes();
    final performance = File('$folder/$importedPerformanceMappingFileName');
    if (await performance.exists()) {
      files['$root/$importedPerformanceMappingFileName'] = await performance
          .readAsBytes();
    }
    return files;
  }

  /// Removes one imported model after a larger import transaction fails.
  /// No resource is deleted until both model and texture indexes are saved.
  /// An index failure therefore leaves the model available for recovery.
  Future<bool> removeImportedModel(
    String id, {
    required String characterId,
  }) async {
    await initialize();
    final record = skinsFor(characterId)
        .where((record) => record['id'] == id)
        .firstOrNull;
    if (record == null) return false;
    await _ensureRecordPackage(record);
    await _requireCacheParent(record);
    final folder = Directory(_folderFor(record));
    final type = await FileSystemEntity.type(folder.path, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw const FileSystemException('Spine cache is not a directory');
    }
    final previousSkins = [...skins];
    final previousTextures = {..._textures};
    final nextSkins = skins.where((item) => item != record).toList();
    final nextTextures = {..._textures}..remove(id);
    Future<void> saveIndexes(
      List<Map<String, String>> modelRows,
      Map<String, Map<String, dynamic>> textureRows,
    ) async {
      if (!await _prefs!.setString(
            'localSkinTextures',
            jsonEncode(textureRows),
          ) ||
          !await _prefs!.setStringList(
            'localSkinPackages',
            modelRows.map(jsonEncode).toList(),
          )) {
        throw const FileSystemException(
          'Could not save removed model settings',
        );
      }
    }

    try {
      await saveIndexes(nextSkins, nextTextures);
    } on Object {
      // SharedPreferences updates its in-memory cache before its write result;
      // explicitly restore both keys even when a platform write returns false.
      await saveIndexes(previousSkins, previousTextures);
      rethrow;
    }
    skins
      ..clear()
      ..addAll(nextSkins);
    _textures
      ..clear()
      ..addAll(nextTextures);
    try {
      if (type == FileSystemEntityType.directory) {
        await folder.delete(recursive: true);
      }
      // Delete the authoritative ZIP last, so any cache cleanup failure can
      // still restore the model from its complete package.
      await _packages.deleteModel(id);
    } on Object {
      try {
        await saveIndexes(previousSkins, previousTextures);
        skins
          ..clear()
          ..addAll(previousSkins);
        _textures
          ..clear()
          ..addAll(previousTextures);
        await _restoreCacheIfMissing(record);
      } on Object {
        // Even if the index cannot be restored, its ZIP remains recoverable.
      }
      rethrow;
    }
    await _deleteUnreferencedTexture(
      previousTextures[id]?['file'] as String?,
      nextTextures,
    );
    return true;
  }

  Future<Uint8List?> previewFor(
    String id, {
    String characterId = 'ryza',
  }) async {
    await initialize();
    final records = skinsFor(characterId).where((record) => record['id'] == id);
    if (records.isEmpty) return null;
    await _restoreCacheIfMissing(records.first);
    final preview = records.first['preview'];
    if (preview == null ||
        !_validPreviewName(preview, records.first['base']!)) {
      return null;
    }
    final file = File('${_folderFor(records.first)}/$preview');
    return await file.exists() ? file.readAsBytes() : null;
  }

  bool hasTexture(String id) => _textures.containsKey(id);
  bool usesTexture(String id) => _textures[id]?['enabled'] == true;

  Future<void> _deleteUnreferencedTexture(
    String? fileName,
    Map<String, Map<String, dynamic>> records,
  ) async {
    if (fileName == null ||
        !fileName.startsWith('texture_') ||
        !_safe(fileName) ||
        records.values.any((record) => record['file'] == fileName)) {
      return;
    }
    try {
      await File('${_root!.path}/$fileName.png').delete();
    } on FileSystemException {
      // A leftover local file is harmless once no saved texture refers to it.
    }
  }

  Future<void> importTexture(
    String id,
    Uint8List bytes,
    Uint8List original,
  ) async {
    await initialize();
    if (!_safe(id) ||
        bytes.length > maxSkinImportBytes ||
        pngSize(bytes) != pngSize(original)) {
      throw const FormatException(
        'PNG dimensions must match the original texture',
      );
    }
    final previousFile = _textures[id]?['file'] as String?;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    var file = 'texture_$timestamp';
    var suffix = 1;
    while (await File('${_root!.path}/$file.png').exists()) {
      file = 'texture_${timestamp}_${suffix++}';
    }
    final textureFile = File('${_root!.path}/$file.png');
    await textureFile.writeAsBytes(bytes, flush: true);
    final next = {
      ..._textures,
      id: {'file': file, 'enabled': true},
    };
    final previousAttachments = await _textureAttachmentSnapshot(id);
    try {
      await _saveTextureAttachments(id, bytes, enabled: true);
      if (!await _prefs!.setString('localSkinTextures', jsonEncode(next))) {
        throw const FileSystemException('Could not save texture settings');
      }
    } on Object {
      if (previousAttachments != null) {
        await _packages.saveAttachments(id, previousAttachments);
      }
      await _deleteUnreferencedTexture(file, _textures);
      rethrow;
    }
    _textures[id] = next[id]!;
    await _deleteUnreferencedTexture(previousFile, next);
  }

  Future<bool> deleteTexture(String id) async {
    await initialize();
    final record = _textures[id];
    if (record == null) return false;
    final next = {..._textures}..remove(id);
    final previousAttachments = await _textureAttachmentSnapshot(id);
    try {
      await _saveTextureAttachments(id, null, enabled: false);
      if (!await _prefs!.setString('localSkinTextures', jsonEncode(next))) {
        throw const FileSystemException('Could not save texture settings');
      }
    } on Object {
      if (previousAttachments != null) {
        await _packages.saveAttachments(id, previousAttachments);
      }
      rethrow;
    }
    _textures.remove(id);
    await _deleteUnreferencedTexture(record['file'] as String?, next);
    return true;
  }

  Future<void> setTextureEnabled(String id, bool enabled) async {
    if (!hasTexture(id)) return;
    final next = {
      ..._textures,
      id: {..._textures[id]!, 'enabled': enabled},
    };
    final previousAttachments = await _textureAttachmentSnapshot(id);
    try {
      final textureFile = File('${_root!.path}/${_textures[id]!['file']}.png');
      await _saveTextureAttachments(
        id,
        await textureFile.readAsBytes(),
        enabled: enabled,
      );
      if (!await _prefs!.setString('localSkinTextures', jsonEncode(next))) {
        throw const FileSystemException('Could not save texture settings');
      }
    } on Object {
      if (previousAttachments != null) {
        await _packages.saveAttachments(id, previousAttachments);
      }
      rethrow;
    }
    _textures[id] = next[id]!;
  }

  Future<Uint8List?> textureFor(String id) async {
    if (!usesTexture(id)) return null;
    final file = File('${_root!.path}/${_textures[id]!['file']}.png');
    return await file.exists() ? file.readAsBytes() : null;
  }
}
