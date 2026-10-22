import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:spine_flutter/spine_flutter.dart';

import 'live2d_model_descriptor.dart';
import 'protected_character_assets.dart';
import 'spine_control_templates.dart';
import 'spine36_player.dart';

enum ModelResourceFormat { spine, live2d, vrm }

/// Stable resource kinds shared by model inspectors and semantic mapping.
abstract final class ModelResourceKinds {
  static const animation = 'animation';
  static const motion = 'motion';
  static const expression = 'expression';
  static const parameter = 'parameter';
  static const bone = 'bone';
  static const slot = 'slot';
  static const skin = 'skin';
  static const hitArea = 'hitArea';
  static const constraint = 'constraint';
  static const event = 'event';
}

class ModelResource {
  const ModelResource({
    required this.id,
    required this.kind,
    required this.name,
    this.native = const {},
    this.description = '',
    this.duration,
  });

  final String id;
  final String kind;
  final String name;
  final Map<String, Object?> native;
  final String description;
  final double? duration;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    if (duration != null) 'duration': duration,
    if (native.isNotEmpty) 'native': native,
  };
}

class ModelResourceCatalog {
  ModelResourceCatalog({
    required this.format,
    required this.sourceFingerprint,
    required this.runtimeVersion,
    required this.entryFile,
    required List<ModelResource> resources,
    this.runtimeSupported = true,
    List<String> compatibilityIssues = const [],
    Map<String, Object?> existingMapping = const {},
  }) : resources = List.unmodifiable(resources),
       compatibilityIssues = List.unmodifiable(compatibilityIssues),
       existingMapping = Map.unmodifiable(existingMapping) {
    final ids = <String>{};
    for (final resource in resources) {
      if (resource.id.trim().isEmpty ||
          resource.kind.trim().isEmpty ||
          resource.name.trim().isEmpty) {
        throw ArgumentError(
          'Model resources require non-empty id, kind and name.',
        );
      }
      if (!ids.add(resource.id)) {
        throw ArgumentError('Duplicate model resource id: ${resource.id}');
      }
    }
  }

  final ModelResourceFormat format;
  final String sourceFingerprint;
  final String runtimeVersion;
  final String entryFile;
  final List<ModelResource> resources;
  final bool runtimeSupported;
  final List<String> compatibilityIssues;
  final Map<String, Object?> existingMapping;

  ModelResource? resourceById(String id) {
    for (final resource in resources) {
      if (resource.id == id) return resource;
    }
    return null;
  }

  /// Complete, compact input for semantic mapping. Resources are never
  /// truncated: callers must explicitly raise the limit or review a catalog
  /// that is too large for their selected LLM.
  Map<String, Object?> toPromptJson({int maxEncodedBytes = 512 * 1024}) {
    if (maxEncodedBytes <= 0) {
      throw ArgumentError.value(maxEncodedBytes, 'maxEncodedBytes');
    }
    final result = <String, Object?>{
      'schemaVersion': 1,
      'format': format.name,
      'sourceFingerprint': sourceFingerprint,
      'runtimeVersion': runtimeVersion,
      'entryFile': entryFile,
      'runtimeSupported': runtimeSupported,
      if (compatibilityIssues.isNotEmpty)
        'compatibilityIssues': compatibilityIssues,
      'resources': [for (final resource in resources) resource.toJson()],
      if (existingMapping.isNotEmpty) 'existingMapping': existingMapping,
    };
    final size = utf8.encode(jsonEncode(result)).length;
    if (size > maxEncodedBytes) {
      throw StateError(
        'Model resource catalog needs $size UTF-8 bytes for '
        '${resources.length} resources, above the $maxEncodedBytes-byte '
        'prompt limit. Raise the limit or review/split this model explicitly; '
        'resources were not truncated.',
      );
    }
    return result;
  }
}

const _maxArchiveBytes = 128 * 1024 * 1024;
const _maxExpandedBytes = 256 * 1024 * 1024;
const _maxFileBytes = 128 * 1024 * 1024;
const _maxJsonBytes = 16 * 1024 * 1024;
const _maxEntries = 1024;

Future<ModelResourceCatalog> inspectModelResources(
  Uint8List bytes, {
  required ModelResourceFormat format,
}) async {
  if (bytes.isEmpty) throw const FormatException('Model ZIP is empty.');
  if (bytes.length > _maxArchiveBytes) {
    throw const FormatException('Model package cannot exceed 128 MB.');
  }
  final fingerprint = _hex((await Sha256().hash(bytes)).bytes);
  final archive = format == ModelResourceFormat.vrm && _isGlb(bytes)
      ? _InspectionArchive(
          {'model.vrm': bytes},
          archiveBytes: bytes.length,
          expandedBytes: bytes.length,
          entryCount: 1,
        )
      : _decodeArchive(bytes, format);
  return switch (format) {
    ModelResourceFormat.spine => _inspectSpine(archive, fingerprint),
    ModelResourceFormat.live2d => _inspectLive2d(archive, fingerprint),
    ModelResourceFormat.vrm => _inspectVrm(archive, fingerprint),
  };
}

Future<ModelResourceCatalog> _inspectSpine(
  _InspectionArchive archive,
  String fingerprint,
) async {
  final binaries = archive.files.keys
      .where((path) => path.toLowerCase().endsWith('.skel'))
      .toList();
  final candidates = <(String, Map<String, Object?>)>[];
  for (final entry in archive.files.entries) {
    if (!entry.key.toLowerCase().endsWith('.json')) continue;
    final decoded = _tryJsonObject(entry.value, entry.key);
    if (decoded != null &&
        decoded['skeleton'] is Map &&
        decoded['bones'] is List &&
        decoded['animations'] is Map) {
      candidates.add((entry.key, decoded));
    }
  }
  if (binaries.length > 1) {
    throw const FormatException('Spine ZIP must contain one skeleton entry.');
  }
  if (binaries.length == 1) {
    final binaryBase = _fileStem(binaries.single);
    final matchingJson = archive.files.keys.any(
      (path) => path.split('/').last == '$binaryBase.json',
    );
    if (matchingJson) {
      throw const FormatException(
        'Spine ZIP contains multiple or ambiguous skeleton entries.',
      );
    }
  }
  if (candidates.length > 1 || (binaries.isNotEmpty && candidates.isNotEmpty)) {
    throw const FormatException(
      'Spine ZIP contains multiple or ambiguous skeleton entries.',
    );
  }
  if (binaries.length == 1) {
    final entry = binaries.single;
    final version = _spineBinaryVersion(archive.files[entry]!) ?? 'unknown';
    final packageIssues = _spineImportCompatibility(archive, entry);
    final existingMapping = await _spineExistingMapping(
      archive.files,
      _fileStem(entry),
    );
    if (!_isSpine42(version)) {
      return ModelResourceCatalog(
        format: ModelResourceFormat.spine,
        sourceFingerprint: fingerprint,
        runtimeVersion: version,
        entryFile: entry,
        resources: const [],
        runtimeSupported: false,
        compatibilityIssues: [
          'Spine binary $version is not supported by the bundled 4.2 runtime.',
          ...packageIssues,
        ],
        existingMapping: existingMapping,
      );
    }
    if (packageIssues.isNotEmpty) {
      return ModelResourceCatalog(
        format: ModelResourceFormat.spine,
        sourceFingerprint: fingerprint,
        runtimeVersion: version,
        entryFile: entry,
        resources: const [],
        runtimeSupported: false,
        compatibilityIssues: packageIssues,
        existingMapping: existingMapping,
      );
    }
    return _inspectSpineBinary(
      archive,
      fingerprint,
      entry,
      version,
      existingMapping,
      packageIssues,
    );
  }

  if (candidates.length != 1) {
    throw const FormatException(
      'Spine ZIP must contain one .skel or one skeleton JSON entry.',
    );
  }
  final (entry, json) = candidates.single;
  final packageIssues = _spineImportCompatibility(archive, entry);
  return _inspectSpineJson(
    json,
    entryFile: entry,
    fingerprint: fingerprint,
    existingMapping: await _spineExistingMapping(
      archive.files,
      _fileStem(entry),
    ),
    packageIssues: packageIssues,
  );
}

ModelResourceCatalog _inspectSpineJson(
  Map<String, Object?> json, {
  required String entryFile,
  required String fingerprint,
  required Map<String, Object?> existingMapping,
  required List<String> packageIssues,
}) {
  final skeleton = _object(json['skeleton']);
  final version = _text(skeleton['spine']);
  final resources = <ModelResource>[];

  final bones = _list(json['bones']);
  for (var index = 0; index < bones.length; index++) {
    final bone = _object(bones[index]);
    final name = _text(bone['name']);
    if (name.isEmpty) continue;
    resources.add(
      ModelResource(
        id: 'bone:$name',
        kind: ModelResourceKinds.bone,
        name: name,
        native: {
          'name': name,
          'index': index,
          if (_text(bone['parent']).isNotEmpty) 'parent': _text(bone['parent']),
        },
      ),
    );
  }

  final slots = _list(json['slots']);
  for (var index = 0; index < slots.length; index++) {
    final slot = _object(slots[index]);
    final name = _text(slot['name']);
    if (name.isEmpty) continue;
    resources.add(
      ModelResource(
        id: 'slot:$name',
        kind: ModelResourceKinds.slot,
        name: name,
        native: {
          'name': name,
          'index': index,
          if (_text(slot['bone']).isNotEmpty) 'bone': _text(slot['bone']),
          if (_text(slot['attachment']).isNotEmpty)
            'attachment': _text(slot['attachment']),
        },
      ),
    );
  }

  final skins = _spineSkins(json['skins']);
  for (final skin in skins) {
    resources.add(
      ModelResource(
        id: 'skin:${skin.name}',
        kind: ModelResourceKinds.skin,
        name: skin.name,
        native: {'name': skin.name},
      ),
    );
    for (final area in skin.hitAreas) {
      resources.add(
        ModelResource(
          id: 'hitArea:${skin.name}:${area.slot}:${area.name}',
          kind: ModelResourceKinds.hitArea,
          name: area.name,
          native: {
            'skin': skin.name,
            'slot': area.slot,
            'attachment': area.name,
          },
        ),
      );
    }
  }

  final animations = _object(json['animations']);
  for (final entry in animations.entries) {
    final name = entry.key;
    final animation = _object(entry.value);
    resources.add(
      ModelResource(
        id: 'animation:$name',
        kind: ModelResourceKinds.animation,
        name: name,
        duration: _timelineDuration(animation),
        native: {
          'name': name,
          if (animation.isNotEmpty) 'sections': animation.keys.toList(),
        },
      ),
    );
  }

  for (final type in ['ik', 'transform', 'path', 'physics']) {
    for (final value in _list(json[type])) {
      final row = _object(value);
      final name = _text(row['name']);
      if (name.isEmpty) continue;
      resources.add(
        ModelResource(
          id: 'constraint:$type:$name',
          kind: ModelResourceKinds.constraint,
          name: name,
          native: {'type': type, 'name': name},
        ),
      );
    }
  }

  final events = json['events'];
  final eventNames = events is Map
      ? events.keys.whereType<String>()
      : _list(events).map((value) => _text(_object(value)['name']));
  for (final name in eventNames.where((value) => value.isNotEmpty)) {
    resources.add(
      ModelResource(
        id: 'event:$name',
        kind: ModelResourceKinds.event,
        name: name,
        native: {'name': name},
      ),
    );
  }

  final versionSupported =
      _isSpine42(version) || (isSpine36(version) && spine36Available);
  return ModelResourceCatalog(
    format: ModelResourceFormat.spine,
    sourceFingerprint: fingerprint,
    runtimeVersion: version.isEmpty ? 'unknown' : version,
    entryFile: entryFile,
    resources: resources,
    runtimeSupported: versionSupported && packageIssues.isEmpty,
    compatibilityIssues: [
      if (!versionSupported)
        isSpine36(version)
            ? 'Spine 3.6 JSON playback currently requires Android.'
            : 'Spine $version does not match the supported 3.6 JSON / 4.2 runtimes.',
      ...packageIssues,
    ],
    existingMapping: existingMapping,
  );
}

Future<ModelResourceCatalog> _inspectSpineBinary(
  _InspectionArchive archive,
  String fingerprint,
  String entry,
  String version,
  Map<String, Object?> existingMapping,
  List<String> packageIssues,
) async {
  final atlasEntry = _matchingSpineAtlas(archive.files.keys, entry);
  if (atlasEntry == null) {
    throw const FormatException('Spine binary package is missing its atlas.');
  }
  final prefix = 'model_resource_catalog';
  final bundle = ProtectedCharacterAssetBundle({
    for (final file in archive.files.entries) '$prefix/${file.key}': file.value,
  });
  await initSpineFlutter();
  final atlas = await Atlas.fromAsset('$prefix/$atlasEntry', bundle: bundle);
  try {
    final skeleton = SkeletonData.fromBinary(atlas, archive.files[entry]!);
    try {
      final resources = <ModelResource>[
        for (final animation in skeleton.getAnimations())
          ModelResource(
            id: 'animation:${animation.getName()}',
            kind: ModelResourceKinds.animation,
            name: animation.getName(),
            duration: animation.getDuration(),
            native: {'name': animation.getName()},
          ),
        for (final bone in skeleton.getBones())
          ModelResource(
            id: 'bone:${bone.getName()}',
            kind: ModelResourceKinds.bone,
            name: bone.getName(),
            native: {'name': bone.getName()},
          ),
        for (final slot in skeleton.getSlots())
          ModelResource(
            id: 'slot:${slot.getName()}',
            kind: ModelResourceKinds.slot,
            name: slot.getName(),
            native: {
              'name': slot.getName(),
              'index': slot.getIndex(),
              'bone': slot.getBoneData().getName(),
            },
          ),
        for (final skin in skeleton.getSkins())
          ModelResource(
            id: 'skin:${skin.getName()}',
            kind: ModelResourceKinds.skin,
            name: skin.getName(),
            native: {'name': skin.getName()},
          ),
        for (final event in skeleton.getEvents())
          ModelResource(
            id: 'event:${event.getName()}',
            kind: ModelResourceKinds.event,
            name: event.getName(),
            native: {'name': event.getName()},
          ),
        for (final constraint in skeleton.getIkConstraints())
          ModelResource(
            id: 'constraint:ik:${constraint.getName()}',
            kind: ModelResourceKinds.constraint,
            name: constraint.getName(),
            native: {'type': 'ik', 'name': constraint.getName()},
          ),
        for (final constraint in skeleton.getPathConstraints())
          ModelResource(
            id: 'constraint:path:${constraint.getName()}',
            kind: ModelResourceKinds.constraint,
            name: constraint.getName(),
            native: {'type': 'path', 'name': constraint.getName()},
          ),
      ];
      return ModelResourceCatalog(
        format: ModelResourceFormat.spine,
        sourceFingerprint: fingerprint,
        runtimeVersion: version,
        entryFile: entry,
        resources: resources,
        runtimeSupported: packageIssues.isEmpty,
        compatibilityIssues: packageIssues,
        existingMapping: existingMapping,
      );
    } finally {
      skeleton.dispose();
    }
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    throw FormatException(
      'Spine 4.2 binary could not be inspected: ${error.runtimeType}.',
    );
  } finally {
    atlas.dispose();
  }
}

ModelResourceCatalog _inspectLive2d(
  _InspectionArchive archive,
  String fingerprint,
) {
  final modelEntries = archive.files.keys
      .where((path) => path.toLowerCase().endsWith('.model3.json'))
      .toList();
  if (modelEntries.length != 1) {
    throw const FormatException(
      'Live2D ZIP must contain exactly one .model3.json.',
    );
  }
  final entryFile = modelEntries.single;
  final parent = _parentPath(entryFile);
  String relative(String path) => parent.isEmpty ? path : '$parent/$path';
  final manifestPath = [
    relative('performance.manifest.json'),
    relative('manifest.json'),
  ].where(archive.files.containsKey).firstOrNull;
  final modelJson = _jsonText(archive.files[entryFile]!, entryFile);
  final model = _jsonObject(modelJson, entryFile);
  final descriptor = Live2DModelDescriptor.parse(
    modelJson,
    manifestJson: manifestPath == null
        ? null
        : _jsonText(archive.files[manifestPath]!, manifestPath),
    modelId: entryFile.split('/').last.replaceFirst('.model3.json', ''),
  );
  if (descriptor.mocFile == null || descriptor.textureFiles.isEmpty) {
    throw const FormatException('Live2D model requires Moc and Textures.');
  }
  final referenced = <String>{
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
  for (final path in referenced) {
    final resolved = relative(_safePath(path));
    if (!archive.files.containsKey(resolved) ||
        archive.files[resolved]!.isEmpty) {
      throw FormatException('Live2D ZIP is missing referenced file: $path');
    }
  }

  final parameterNames = <String, String>{};
  for (final ids in descriptor.parameterGroups.values) {
    for (final id in ids) {
      parameterNames.putIfAbsent(id, () => id);
    }
  }
  for (final id in descriptor.parameterBindings.values) {
    parameterNames.putIfAbsent(id, () => id);
  }

  final references = _object(model['FileReferences']);
  final displayInfo = _text(references['DisplayInfo']);
  if (displayInfo.isNotEmpty) {
    final path = relative(_safePath(displayInfo));
    final bytes = archive.files[path];
    if (bytes == null) {
      throw FormatException('Live2D ZIP is missing DisplayInfo: $displayInfo');
    }
    final info = _jsonObject(_jsonText(bytes, path), path);
    for (final value in _list(info['Parameters'])) {
      final row = _object(value);
      final id = _text(row['Id']);
      if (id.isNotEmpty) {
        parameterNames[id] = _text(row['Name']).isEmpty
            ? id
            : _text(row['Name']);
      }
    }
  }

  final resources = <ModelResource>[];
  for (final entry in descriptor.motions.entries) {
    for (final motion in entry.value) {
      final path = relative(_safePath(motion.file));
      final metadata = _live2dMotionMetadata(archive.files[path]!, path);
      for (final id in metadata.parameters) {
        parameterNames.putIfAbsent(id, () => id);
      }
      resources.add(
        ModelResource(
          id: 'motion:${motion.group}:${motion.index}',
          kind: ModelResourceKinds.motion,
          name: '${motion.group}[${motion.index}]',
          description: descriptor.motionDescription(motion),
          duration: metadata.duration,
          native: {
            'group': motion.group,
            'index': motion.index,
            'file': motion.file,
            if (motion.sound != null) 'sound': motion.sound,
            if (motion.fadeInSeconds != null)
              'fadeInSeconds': motion.fadeInSeconds,
            if (motion.fadeOutSeconds != null)
              'fadeOutSeconds': motion.fadeOutSeconds,
          },
        ),
      );
    }
  }
  for (final expression in descriptor.expressions) {
    final path = relative(_safePath(expression.file));
    for (final id in _live2dExpressionParameters(archive.files[path]!, path)) {
      parameterNames.putIfAbsent(id, () => id);
    }
    resources.add(
      ModelResource(
        id: 'expression:${expression.name}',
        kind: ModelResourceKinds.expression,
        name: expression.name,
        native: {
          'name': expression.name,
          'index': expression.index,
          'file': expression.file,
        },
      ),
    );
  }
  for (final entry in parameterNames.entries) {
    resources.add(
      ModelResource(
        id: 'parameter:${entry.key}',
        kind: ModelResourceKinds.parameter,
        name: entry.value,
        native: {'id': entry.key},
      ),
    );
  }
  for (final area in descriptor.hitAreas) {
    resources.add(
      ModelResource(
        id: 'hitArea:${area.id}',
        kind: ModelResourceKinds.hitArea,
        name: area.name,
        native: {'id': area.id, 'name': area.name},
      ),
    );
  }

  final version = model['Version'];
  return ModelResourceCatalog(
    format: ModelResourceFormat.live2d,
    sourceFingerprint: fingerprint,
    runtimeVersion: version == null ? 'Cubism 3+' : 'Cubism $version',
    entryFile: entryFile,
    resources: resources,
    compatibilityIssues: descriptor.warnings,
    existingMapping: {
      'manifestFile': ?manifestPath,
      if (descriptor.actionMappings.isNotEmpty)
        'actions': {
          for (final entry in descriptor.actionMappings.entries)
            entry.key: {
              'resourceId': 'motion:${entry.value.group}:${entry.value.index}',
              if (entry.value.description.isNotEmpty)
                'description': entry.value.description,
              if (entry.value.aliases.isNotEmpty)
                'aliases': entry.value.aliases,
            },
        },
      if (descriptor.expressionMappings.isNotEmpty)
        'expressions': {
          for (final entry in descriptor.expressionMappings.entries)
            entry.key: {
              if (entry.value.name != null)
                'resourceId': 'expression:${entry.value.name}',
              if (entry.value.index != null) 'index': entry.value.index,
              if (entry.value.aliases.isNotEmpty)
                'aliases': entry.value.aliases,
            },
        },
      if (descriptor.parameterBindings.isNotEmpty)
        'parameters': {
          for (final entry in descriptor.parameterBindings.entries)
            entry.key: 'parameter:${entry.value}',
        },
    },
  );
}

ModelResourceCatalog _inspectVrm(
  _InspectionArchive archive,
  String fingerprint,
) {
  final entries = archive.files.keys.where((path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.vrm') || lower.endsWith('.glb');
  }).toList();
  if (entries.length != 1) {
    throw const FormatException('VRM ZIP must contain exactly one .vrm/.glb.');
  }
  final entryFile = entries.single;
  final gltf = _parseGlb(archive.files[entryFile]!, entryFile);
  final extensions = _object(gltf['extensions']);
  final resources = <ModelResource>[];
  final mappingBones = <String, Object?>{};
  final mappingExpressions = <String, Object?>{};
  String version;

  final vrm1 = _object(extensions['VRMC_vrm']);
  if (vrm1.isNotEmpty) {
    final spec = _text(vrm1['specVersion']);
    version = 'VRM ${spec.isEmpty ? '1.0' : spec}';
    final humanBones = _object(_object(vrm1['humanoid'])['humanBones']);
    for (final entry in humanBones.entries) {
      final row = _object(entry.value);
      final node = row['node'];
      if (node is! int) continue;
      resources.add(
        ModelResource(
          id: 'bone:${entry.key}',
          kind: ModelResourceKinds.bone,
          name: entry.key,
          native: {
            'humanBone': entry.key,
            'node': node,
            'extension': 'VRMC_vrm',
          },
        ),
      );
      mappingBones[entry.key] = 'bone:${entry.key}';
    }
    final expressions = _object(vrm1['expressions']);
    for (final source in ['preset', 'custom']) {
      for (final entry in _object(expressions[source]).entries) {
        final id = 'expression:${entry.key}';
        resources.add(
          ModelResource(
            id: id,
            kind: ModelResourceKinds.expression,
            name: entry.key,
            native: {
              'name': entry.key,
              'source': source,
              'extension': 'VRMC_vrm',
            },
          ),
        );
        mappingExpressions[entry.key] = id;
      }
    }
  } else {
    final vrm0 = _object(extensions['VRM']);
    if (vrm0.isEmpty) {
      throw const FormatException('GLB does not contain a VRM extension.');
    }
    final spec = _text(vrm0['specVersion']);
    version = 'VRM ${spec.isEmpty ? '0.x' : spec}';
    for (final value in _list(_object(vrm0['humanoid'])['humanBones'])) {
      final row = _object(value);
      final name = _text(row['bone']);
      final node = row['node'];
      if (name.isEmpty || node is! int) continue;
      resources.add(
        ModelResource(
          id: 'bone:$name',
          kind: ModelResourceKinds.bone,
          name: name,
          native: {'humanBone': name, 'node': node, 'extension': 'VRM'},
        ),
      );
      mappingBones[name] = 'bone:$name';
    }
    final blendShapeMaster = _object(vrm0['blendShapeMaster']);
    for (final value in _list(blendShapeMaster['blendShapeGroups'])) {
      final row = _object(value);
      final preset = _text(row['presetName']);
      final name = preset.isNotEmpty && preset.toLowerCase() != 'unknown'
          ? preset
          : _text(row['name']);
      if (name.isEmpty) continue;
      final id = 'expression:$name';
      resources.add(
        ModelResource(
          id: id,
          kind: ModelResourceKinds.expression,
          name: name,
          native: {'name': name, 'extension': 'VRM'},
        ),
      );
      mappingExpressions[name] = id;
    }
  }

  return ModelResourceCatalog(
    format: ModelResourceFormat.vrm,
    sourceFingerprint: fingerprint,
    runtimeVersion: version,
    entryFile: entryFile,
    resources: resources,
    runtimeSupported: false,
    compatibilityIssues: const [
      'VRM metadata is available for mapping, but this app has no VRM renderer yet.',
    ],
    existingMapping: {
      if (mappingBones.isNotEmpty) 'humanoid': mappingBones,
      if (mappingExpressions.isNotEmpty) 'expressions': mappingExpressions,
    },
  );
}

class _InspectionArchive {
  const _InspectionArchive(
    this.files, {
    required this.archiveBytes,
    required this.expandedBytes,
    required this.entryCount,
  });
  final Map<String, Uint8List> files;
  final int archiveBytes;
  final int expandedBytes;
  final int entryCount;
}

_InspectionArchive _decodeArchive(Uint8List bytes, ModelResourceFormat format) {
  if (bytes.length > _maxArchiveBytes) {
    throw const FormatException('Model ZIP cannot exceed 128 MB.');
  }
  try {
    final archive = ZipDirectory()..read(InputMemoryStream(bytes));
    if (archive.filePosition < 0 ||
        archive.numberOfThisDisk != 0 ||
        archive.diskWithTheStartOfTheCentralDirectory != 0 ||
        archive.fileHeaders.length != archive.totalCentralDirectoryEntries) {
      throw const FormatException('Invalid or split model ZIP.');
    }
    if (archive.fileHeaders.length > _maxEntries) {
      throw const FormatException(
        'Model ZIP cannot contain more than 1024 entries.',
      );
    }
    final seen = <String>{};
    final filePaths = <String>{};
    final requiredDirectories = <String>{};
    final entries = <(String, ZipFileHeader)>[];
    var expanded = 0;
    for (final entry in archive.fileHeaders) {
      final path = _safePath(entry.filename);
      final canonical = path.toLowerCase();
      if (!seen.add(canonical)) {
        throw FormatException('Model ZIP contains duplicate path: $path');
      }
      final local = entry.file;
      if (local == null) {
        throw const FormatException('Invalid ZIP file header.');
      }
      final mode = (entry.externalFileAttributes >> 16) & 0xf000;
      final isDirectory =
          entry.filename.endsWith('/') || entry.filename.endsWith('\\');
      if (mode != 0 && mode != 0x8000 && mode != 0x4000) {
        throw const FormatException(
          'Model ZIP cannot contain links or special files.',
        );
      }
      if ((entry.generalPurposeBitFlag & 1) != 0 || (local.flags & 1) != 0) {
        throw const FormatException('Encrypted model ZIPs are not supported.');
      }
      if (isDirectory) {
        if (mode == 0x8000) {
          throw const FormatException('ZIP file/directory type mismatch.');
        }
        requiredDirectories.add(canonical);
        continue;
      }
      if (mode == 0x4000 || !_allowedModelFile(path, format)) {
        throw FormatException('Unsupported file in model ZIP: $path');
      }
      if (path.toLowerCase().endsWith('.json') &&
          entry.uncompressedSize > _maxJsonBytes) {
        throw FormatException('$path exceeds the 16 MB JSON limit.');
      }
      if (entry.uncompressedSize < 0 ||
          entry.uncompressedSize > _maxFileBytes) {
        throw const FormatException('A model file exceeds 128 MB.');
      }
      expanded += entry.uncompressedSize;
      if (expanded > _maxExpandedBytes) {
        throw const FormatException('Expanded model ZIP exceeds 256 MB.');
      }
      if (entry.compressionMethod != 0 && entry.compressionMethod != 8) {
        throw const FormatException(
          'Only Store/Deflate ZIP compression is supported.',
        );
      }
      if (_safePath(local.filename) != path ||
          local.uncompressedSize != entry.uncompressedSize ||
          local.compressedSize != entry.compressedSize) {
        throw const FormatException('ZIP local and central headers disagree.');
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
      throw const FormatException('ZIP file and directory paths conflict.');
    }
    final files = <String, Uint8List>{};
    for (final (path, entry) in entries) {
      final output = _BoundedOutput(entry.uncompressedSize);
      entry.file!.decompress(output);
      final content = output.getBytes();
      if (content.length != entry.uncompressedSize ||
          getCrc32(content) != entry.crc32) {
        throw FormatException('Damaged model ZIP entry: $path');
      }
      files[path] = content;
    }
    return _InspectionArchive(
      Map.unmodifiable(files),
      archiveBytes: bytes.length,
      expandedBytes: expanded,
      entryCount: archive.fileHeaders.length,
    );
  } on FormatException {
    rethrow;
  } on Object catch (error) {
    throw FormatException('Model ZIP cannot be read: ${error.runtimeType}.');
  }
}

class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.maximum) : super(size: min(maximum, 32 * 1024));
  final int maximum;

  void _check(int count) {
    if (count < 0 || length + count > maximum) {
      throw const FormatException('ZIP output exceeds its declared size.');
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

bool _allowedModelFile(String path, ModelResourceFormat format) {
  final lower = path.toLowerCase();
  final name = lower.split('/').last;
  if (const {
    'license',
    'license.txt',
    'license.md',
    'copying',
    'notice',
    'readme',
    'readme.txt',
    'readme.md',
  }.contains(name)) {
    return true;
  }
  const common = ['.txt', '.md', '.license'];
  if (common.any(lower.endsWith)) return true;
  return switch (format) {
    ModelResourceFormat.spine => const [
      '.json',
      '.skel',
      '.atlas',
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
    ].any(lower.endsWith),
    ModelResourceFormat.live2d => const [
      '.model3.json',
      '.moc3',
      '.motion3.json',
      '.exp3.json',
      '.physics3.json',
      '.pose3.json',
      '.cdi3.json',
      '.userdata3.json',
      '.json',
      '.png',
      '.jpg',
      '.jpeg',
      '.wav',
      '.mp3',
    ].any(lower.endsWith),
    ModelResourceFormat.vrm => lower.endsWith('.vrm') || lower.endsWith('.glb'),
  };
}

String _safePath(String value) {
  final path = value.replaceAll('\\', '/');
  if (path.isEmpty || path.startsWith('/') || path.length > 1024) {
    throw const FormatException('ZIP paths must be relative.');
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
    throw const FormatException('ZIP contains an unsafe or incompatible path.');
  }
  return segments.join('/');
}

String _parentPath(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

String? _matchingSpineAtlas(Iterable<String> paths, String skeleton) {
  final lower = skeleton.toLowerCase();
  final stem = lower.substring(0, lower.length - '.skel'.length);
  final exact = paths.where((path) => path.toLowerCase() == '$stem.atlas');
  if (exact.isNotEmpty) return exact.first;
  final atlases = paths.where((path) => path.toLowerCase().endsWith('.atlas'));
  return atlases.length == 1 ? atlases.first : null;
}

List<String> _spineImportCompatibility(
  _InspectionArchive archive,
  String skeletonPath,
) {
  const localLimit = 64 * 1024 * 1024;
  final issues = <String>[];
  if (archive.archiveBytes > localLimit) {
    issues.add('The Spine ZIP exceeds the importer limit of 64 MB.');
  }
  if (archive.expandedBytes > localLimit) {
    issues.add(
      'The expanded Spine package exceeds the importer limit of 64 MB.',
    );
  }
  if (archive.entryCount > 64) {
    issues.add('The Spine ZIP has more than the importer limit of 64 entries.');
  }

  final flattened = <String, Uint8List>{};
  var duplicate = false;
  for (final entry in archive.files.entries) {
    final name = entry.key.split('/').last;
    if (!RegExp(r'^[a-zA-Z0-9_.-]+\.(atlas|png|skel|json)$').hasMatch(name)) {
      continue;
    }
    if (flattened.containsKey(name)) {
      duplicate = true;
    } else {
      flattened[name] = entry.value;
    }
  }
  if (duplicate) {
    issues.add(
      'Flattening nested files would create duplicate importer names.',
    );
  }

  final skeletonName = skeletonPath.split('/').last;
  final base = _fileStem(skeletonName);
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(base)) {
    issues.add(
      'The Spine base name must use only ASCII letters, digits, _ or -.',
    );
  }
  final atlases = flattened.keys
      .where((name) => name.endsWith('.atlas'))
      .toList();
  if (atlases.length != 1) {
    issues.add('The Spine importer requires exactly one atlas file.');
    return List.unmodifiable(issues);
  }
  if (atlases.single != '$base.atlas') {
    issues.add('The atlas and skeleton must use the same base name.');
  }
  final textureName = '$base.png';
  if (!flattened.containsKey(textureName)) {
    issues.add(
      'The Spine importer requires the matching texture $textureName.',
    );
  }
  if (!flattened.containsKey(skeletonName)) {
    issues.add(
      'The skeleton filename is not compatible with importer flattening.',
    );
  }

  final gestureName = '${base}_gesture.json';
  final gesture = flattened[gestureName];
  if (gesture != null) {
    final root = _tryJsonObject(gesture, gestureName);
    final emotionalGesture = root?['emotionalGesture'];
    if (emotionalGesture is! Map || emotionalGesture['MotionGroups'] is! List) {
      issues.add('The matching Spine gesture mapping is invalid.');
    }
  }

  final preview =
      [
            '${base}_preview.png',
            '$base-preview.png',
            'preview.png',
            'cover.png',
            'thumbnail.png',
          ]
          .where((name) => name != textureName && flattened.containsKey(name))
          .firstOrNull;
  if (preview != null && _pngDimensions(flattened[preview]!) == null) {
    issues.add('The Spine preview $preview is not a valid PNG.');
  }

  String? atlas;
  try {
    atlas = utf8.decode(flattened[atlases.single]!);
  } on FormatException {
    issues.add('The Spine atlas is not valid UTF-8 text.');
  }
  if (atlas != null) {
    final pages = atlas
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().endsWith('.png'))
        .map((line) => line.trim())
        .toList();
    if (pages.length != 1 || pages.single != textureName) {
      issues.add(
        'The Spine importer requires one atlas page named $textureName.',
      );
    }
    final texture = flattened[textureName];
    if (texture != null) {
      final declared = RegExp(
        r'^size:\s*(\d+)\s*,\s*(\d+)',
        multiLine: true,
      ).firstMatch(atlas);
      final actual = _pngDimensions(texture);
      if (declared == null ||
          actual == null ||
          actual.$1 != int.parse(declared[1]!) ||
          actual.$2 != int.parse(declared[2]!)) {
        issues.add('The PNG dimensions do not match the atlas size.');
      }
    }
  }
  return List.unmodifiable(issues);
}

(int, int)? _pngDimensions(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33) return null;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return null;
  }
  if (ascii.decode(bytes.sublist(12, 16), allowInvalid: true) != 'IHDR') {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  final width = data.getUint32(16);
  final height = data.getUint32(20);
  if (width == 0 ||
      height == 0 ||
      width > 8192 ||
      height > 8192 ||
      width * height > 33554432) {
    return null;
  }
  return (width, height);
}

String? _spineBinaryVersion(Uint8List bytes) {
  if (bytes.length <= 9) return null;
  var offset = 8;
  var shift = 0;
  var encodedLength = 0;
  while (offset < bytes.length && shift <= 28) {
    final value = bytes[offset++];
    encodedLength |= (value & 0x7f) << shift;
    if ((value & 0x80) == 0) break;
    shift += 7;
  }
  final length = encodedLength - 1;
  if (length <= 0 || offset + length > bytes.length) return null;
  try {
    return utf8.decode(bytes.sublist(offset, offset + length));
  } on FormatException {
    return null;
  }
}

bool _isSpine42(String version) =>
    RegExp(r'^4\.2(?:\.|$)').hasMatch(version.trim());

bool _isGlb(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x67 &&
    bytes[1] == 0x6c &&
    bytes[2] == 0x54 &&
    bytes[3] == 0x46;

Future<Map<String, Object?>> _spineExistingMapping(
  Map<String, Uint8List> files,
  String skeletonBase,
) async {
  final expectedName = '${skeletonBase}_gesture.json';
  for (final entry in files.entries) {
    if (entry.key.split('/').last != expectedName) continue;
    return _compactSpineGesture(entry.value, source: entry.key);
  }
  final template = SpineControlTemplates.templateForBase(skeletonBase);
  if (template == null) return const {};
  final bytes = await SpineControlTemplates.read(template.id);
  return _compactSpineGesture(
    bytes,
    source: 'builtin:${template.id}',
    templateId: template.id,
  );
}

Map<String, Object?> _compactSpineGesture(
  Uint8List bytes, {
  required String source,
  String? templateId,
}) {
  final root = _tryJsonObject(bytes, source);
  final gesture = _object(root?['emotionalGesture']);
  final groups = <String, Object?>{};
  for (final value in _list(gesture['MotionGroups'])) {
    final row = _object(value);
    final id = _text(row['GroupId']);
    final first = _text(row['AnimName_1']);
    final second = _text(row['AnimName_2']);
    if (id.isEmpty || (first.isEmpty && second.isEmpty)) continue;
    groups[id] = {
      if (_text(row['Label']).isNotEmpty) 'label': _text(row['Label']),
      if (_text(row['OccupancyLetters']).isNotEmpty)
        'occupancy': _text(row['OccupancyLetters']),
      'resources': [
        if (first.isNotEmpty) 'animation:$first',
        if (second.isNotEmpty) 'animation:$second',
      ],
    };
  }
  return {
    'gestureFile': source,
    'templateId': ?templateId,
    if (groups.isNotEmpty) 'motionGroups': groups,
  };
}

String _fileStem(String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

class _SpineSkin {
  const _SpineSkin(this.name, this.hitAreas);
  final String name;
  final List<_SpineHitArea> hitAreas;
}

class _SpineHitArea {
  const _SpineHitArea(this.slot, this.name);
  final String slot;
  final String name;
}

List<_SpineSkin> _spineSkins(Object? value) {
  final result = <_SpineSkin>[];
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) continue;
      result.add(
        _SpineSkin(entry.key as String, _spineHitAreas(_object(entry.value))),
      );
    }
  } else if (value is List) {
    for (final value in value) {
      final skin = _object(value);
      final name = _text(skin['name']);
      if (name.isEmpty) continue;
      result.add(
        _SpineSkin(name, _spineHitAreas(_object(skin['attachments']))),
      );
    }
  }
  return result;
}

List<_SpineHitArea> _spineHitAreas(Map<String, Object?> attachments) {
  final result = <_SpineHitArea>[];
  for (final slot in attachments.entries) {
    for (final attachment in _object(slot.value).entries) {
      if (_text(_object(attachment.value)['type']).toLowerCase() ==
          'boundingbox') {
        result.add(_SpineHitArea(slot.key, attachment.key));
      }
    }
  }
  return result;
}

double? _timelineDuration(Object? value) {
  var found = false;
  var duration = 0.0;
  void visit(Object? current) {
    if (current is Map) {
      for (final entry in current.entries) {
        if (entry.key == 'time' &&
            entry.value is num &&
            (entry.value as num).isFinite) {
          found = true;
          duration = max(duration, (entry.value as num).toDouble());
        }
        visit(entry.value);
      }
    } else if (current is List) {
      for (final item in current) {
        visit(item);
      }
    }
  }

  visit(value);
  return found ? duration : null;
}

class _MotionMetadata {
  const _MotionMetadata(this.duration, this.parameters);
  final double? duration;
  final Set<String> parameters;
}

_MotionMetadata _live2dMotionMetadata(Uint8List bytes, String path) {
  final root = _jsonObject(_jsonText(bytes, path), path);
  final meta = _object(root['Meta']);
  final durationValue = meta['Duration'];
  final parameters = <String>{};
  for (final value in _list(root['Curves'])) {
    final curve = _object(value);
    if (_text(curve['Target']).toLowerCase() != 'parameter') continue;
    final id = _text(curve['Id']);
    if (id.isNotEmpty) parameters.add(id);
  }
  return _MotionMetadata(
    durationValue is num && durationValue.isFinite
        ? durationValue.toDouble()
        : null,
    parameters,
  );
}

Set<String> _live2dExpressionParameters(Uint8List bytes, String path) {
  final root = _jsonObject(_jsonText(bytes, path), path);
  return {
    for (final value in _list(root['Parameters']))
      if (_text(_object(value)['Id']).isNotEmpty) _text(_object(value)['Id']),
  };
}

Map<String, Object?> _parseGlb(Uint8List bytes, String path) {
  if (bytes.length < 20 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'glTF') {
    throw FormatException('$path is not a GLB file.');
  }
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(4, Endian.little) != 2 ||
      data.getUint32(8, Endian.little) != bytes.length) {
    throw FormatException('$path has an invalid GLB header.');
  }
  final jsonLength = data.getUint32(12, Endian.little);
  final chunkType = data.getUint32(16, Endian.little);
  if (chunkType != 0x4e4f534a ||
      jsonLength > _maxJsonBytes ||
      20 + jsonLength > bytes.length) {
    throw FormatException('$path has an invalid or oversized GLB JSON chunk.');
  }
  var end = 20 + jsonLength;
  while (end > 20 && (bytes[end - 1] == 0 || bytes[end - 1] == 0x20)) {
    end--;
  }
  return _jsonObject(utf8.decode(bytes.sublist(20, end)), '$path JSON');
}

String _jsonText(Uint8List bytes, String label) {
  if (bytes.length > _maxJsonBytes) {
    throw FormatException('$label exceeds the 16 MB JSON limit.');
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw FormatException('$label is not valid UTF-8 JSON.');
  }
}

Map<String, Object?> _jsonObject(String source, String label) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw FormatException('$label must be a JSON object.');
    return _object(decoded);
  } on FormatException catch (error) {
    throw FormatException('$label is invalid: ${error.message}');
  }
}

Map<String, Object?>? _tryJsonObject(Uint8List bytes, String label) {
  if (bytes.length > _maxJsonBytes) return null;
  try {
    return _jsonObject(utf8.decode(bytes), label);
  } on FormatException {
    return null;
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

List<Object?> _list(Object? value) => value is List ? value : const [];

String _text(Object? value) => value is String ? value.trim() : '';

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
