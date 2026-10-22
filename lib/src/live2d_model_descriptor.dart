import 'dart:convert';

import 'character_expression.dart';

/// A validated, runtime-independent view of a Cubism `.model3.json` bundle.
///
/// This parser deliberately does not load files or initialize the native
/// Cubism runtime. It is safe to use for cataloging and capability planning.
/// All paths are kept bundle-relative; absolute paths and `..` traversal are
/// rejected so a descriptor cannot point outside its own model directory.
class Live2DModelDescriptor {
  Live2DModelDescriptor._({
    required this.modelId,
    required this.mocFile,
    required this.textureFiles,
    required this.physicsFile,
    required this.poseFile,
    required this.motions,
    required this.idleMotion,
    required this.expressions,
    required this.parameterGroups,
    required this.hitAreas,
    required this.parameterBindings,
    required this.actionMappings,
    required this.expressionMappings,
    required this.warnings,
  });

  factory Live2DModelDescriptor.parse(
    String model3Json, {
    String? manifestJson,
    String? modelId,
  }) {
    final decoded = _decodeObject(model3Json, 'model3 JSON');
    return Live2DModelDescriptor.fromMaps(
      decoded,
      manifest: manifestJson == null
          ? null
          : _decodeObject(manifestJson, 'Live2D manifest'),
      modelId: modelId,
    );
  }

  factory Live2DModelDescriptor.fromMaps(
    Map<String, Object?> model3, {
    Map<String, Object?>? manifest,
    String? modelId,
  }) {
    final references = _asMap(model3['FileReferences']);
    if (references == null) {
      throw const FormatException('Missing FileReferences in model3 JSON.');
    }

    final warnings = <String>[];
    final mocFile = _bundlePath(references['Moc'], field: 'FileReferences.Moc');
    final textureFiles = _stringList(
      references['Textures'],
      field: 'FileReferences.Textures',
      warnings: warnings,
    );
    final physicsFile = _bundlePath(
      references['Physics'],
      field: 'FileReferences.Physics',
    );
    final poseFile = _bundlePath(
      references['Pose'],
      field: 'FileReferences.Pose',
    );

    final motions = <String, List<Live2DMotion>>{};
    final rawMotions = _asMap(references['Motions']) ?? const {};
    for (final entry in rawMotions.entries) {
      final group = entry.key;
      if (entry.value is! List) {
        warnings.add('Ignored malformed motion group "${entry.key}".');
        continue;
      }
      final parsed = <Live2DMotion>[];
      final rows = entry.value as List;
      for (var sourceIndex = 0; sourceIndex < rows.length; sourceIndex++) {
        final raw = rows[sourceIndex];
        final row = _asMap(raw);
        if (row == null) {
          warnings.add('Ignored malformed motion in group "$group".');
          continue;
        }
        final file = _bundlePath(
          row['File'],
          field: 'FileReferences.Motions.$group.File',
        );
        if (file == null) {
          warnings.add('Motion without a valid file in group "$group".');
          continue;
        }
        final sound = _bundlePath(
          row['Sound'],
          field: 'FileReferences.Motions.$group.Sound',
          optional: true,
        );
        parsed.add(
          Live2DMotion(
            group: group,
            index: sourceIndex,
            file: file,
            sound: sound,
            fadeInSeconds: _number(row['FadeInTime']),
            fadeOutSeconds: _number(row['FadeOutTime']),
          ),
        );
      }
      if (parsed.isNotEmpty) motions[group] = List.unmodifiable(parsed);
    }

    final expressions = <Live2DExpressionAsset>[];
    final rawExpressions = references['Expressions'];
    if (rawExpressions is List) {
      for (
        var sourceIndex = 0;
        sourceIndex < rawExpressions.length;
        sourceIndex++
      ) {
        final raw = rawExpressions[sourceIndex];
        final row = _asMap(raw);
        if (row == null) {
          warnings.add('Ignored malformed expression entry.');
          continue;
        }
        final name = _string(row['Name']);
        final file = _bundlePath(
          row['File'],
          field: 'FileReferences.Expressions.File',
        );
        if (name.isEmpty || file == null) {
          warnings.add('Ignored expression without a name or valid file.');
          continue;
        }
        expressions.add(
          Live2DExpressionAsset(index: sourceIndex, name: name, file: file),
        );
      }
    }

    final parameterGroups = <String, List<String>>{};
    final rawGroups = model3['Groups'];
    if (rawGroups is List) {
      for (final raw in rawGroups) {
        final row = _asMap(raw);
        if (row == null ||
            _string(row['Target']).toLowerCase() != 'parameter') {
          continue;
        }
        final name = _string(row['Name']);
        final ids = _stringArray(row['Ids']);
        if (name.isNotEmpty && ids.isNotEmpty) {
          parameterGroups[name] = List.unmodifiable(ids);
        }
      }
    }

    final hitAreas = <Live2DHitArea>[];
    final rawHitAreas = model3['HitAreas'];
    if (rawHitAreas is List) {
      for (final raw in rawHitAreas) {
        final row = _asMap(raw);
        if (row == null) continue;
        final id = _string(row['Id']);
        final name = _string(row['Name']);
        if (id.isNotEmpty && name.isNotEmpty) {
          hitAreas.add(Live2DHitArea(id: id, name: name));
        }
      }
    }

    final parsedManifest = _parseManifest(manifest, warnings);
    Live2DMotion? idleMotion;
    final idleMapping = parsedManifest.idle;
    if (idleMapping != null) {
      final candidates = motions[idleMapping.group];
      idleMotion = candidates
          ?.where((motion) => motion.index == idleMapping.index)
          .firstOrNull;
      if (idleMotion == null) {
        warnings.add(
          'Idle maps to missing motion '
          '"${idleMapping.group}[${idleMapping.index}]".',
        );
      }
    }
    final validActions = <String, Live2DActionMapping>{};
    for (final entry in parsedManifest.actions.entries) {
      final candidates = motions[entry.value.group];
      if (candidates == null ||
          !candidates.any((motion) => motion.index == entry.value.index)) {
        warnings.add(
          'Action "${entry.key}" maps to missing motion '
          '"${entry.value.group}[${entry.value.index}]".',
        );
        continue;
      }
      validActions[entry.key] = entry.value;
      for (final alias in entry.value.aliases) {
        final aliasKey = _semanticKey(alias);
        if (aliasKey.isNotEmpty) {
          validActions.putIfAbsent(aliasKey, () => entry.value);
        }
      }
    }

    final validExpressions = <String, Live2DExpressionMapping>{};
    for (final entry in parsedManifest.expressions.entries) {
      final mapping = entry.value;
      final found = mapping.index != null
          ? expressions.any((candidate) => candidate.index == mapping.index)
          : expressions.any(
              (candidate) => _sameName(candidate.name, mapping.name!),
            );
      if (!found) {
        warnings.add(
          'Expression mapping "${entry.key}" points to no model expression.',
        );
        continue;
      }
      validExpressions[entry.key] = mapping;
      for (final alias in mapping.aliases) {
        final aliasKey = _semanticKey(alias);
        if (aliasKey.isNotEmpty) {
          validExpressions.putIfAbsent(aliasKey, () => mapping);
        }
      }
    }

    return Live2DModelDescriptor._(
      modelId: modelId?.trim().isNotEmpty == true
          ? modelId!.trim()
          : _string(manifest?['modelId']),
      mocFile: mocFile,
      textureFiles: List.unmodifiable(textureFiles),
      physicsFile: physicsFile,
      poseFile: poseFile,
      motions: Map.unmodifiable(motions),
      idleMotion: idleMotion,
      expressions: List.unmodifiable(expressions),
      parameterGroups: Map.unmodifiable(parameterGroups),
      hitAreas: List.unmodifiable(hitAreas),
      parameterBindings: Map.unmodifiable(parsedManifest.parameterBindings),
      actionMappings: Map.unmodifiable(validActions),
      expressionMappings: Map.unmodifiable(validExpressions),
      warnings: List.unmodifiable(warnings),
    );
  }

  final String modelId;
  final String? mocFile;
  final List<String> textureFiles;
  final String? physicsFile;
  final String? poseFile;
  final Map<String, List<Live2DMotion>> motions;

  /// Manifest-declared idle motion, validated against [motions].
  ///
  /// `null` means the manifest deliberately omitted an idle declaration.
  /// An invalid declaration is reported in [warnings] and rejected by the
  /// package importer when supplied as an override.
  final Live2DMotion? idleMotion;
  final List<Live2DExpressionAsset> expressions;
  final Map<String, List<String>> parameterGroups;
  final List<Live2DHitArea> hitAreas;

  /// Maps application-level parameter roles (such as `mouthOpen`) to the
  /// model's actual parameter IDs. Only manifest-authored bindings are used.
  final Map<String, String> parameterBindings;

  /// Explicit semantic mappings from manifest, validated against model3.
  final Map<String, Live2DActionMapping> actionMappings;
  final Map<String, Live2DExpressionMapping> expressionMappings;
  final List<String> warnings;

  List<String> get motionGroups => List.unmodifiable(motions.keys);

  /// Stable IDs for this model's real motions, separate from Spine IDs.
  Map<String, Live2DMotion> get motionCapabilities {
    final result = <String, Live2DMotion>{};
    var groupIndex = 0;
    for (final entry in motions.entries) {
      for (final motion in entry.value) {
        result['grp_live2d_${groupIndex}_${motion.index}'] = motion;
      }
      groupIndex += 1;
    }
    return Map.unmodifiable(result);
  }

  String motionDescription(Live2DMotion motion) {
    final authored = actionMappings.values
        .where(
          (mapping) =>
              mapping.group == motion.group &&
              mapping.index == motion.index &&
              mapping.description.isNotEmpty,
        )
        .firstOrNull;
    return authored?.description ??
        '模型原始动作 ${motion.group}[${motion.index}]（${motion.file}）；仅按明确的名称语义选择，不推断未说明的肢体姿势。';
  }

  /// Resolve an exact action binding. Missing actions return null; the caller
  /// must represent that as `none` instead of substituting a similar motion.
  Live2DMotion? resolveAction(String semanticAction) {
    final key = _semanticKey(semanticAction);
    final explicit = actionMappings[key];
    if (explicit != null) {
      return motions[explicit.group]!.firstWhere(
        (motion) => motion.index == explicit.index,
      );
    }
    final aliases = _actionAliases[key] ?? {key};
    for (final entry in motions.entries) {
      if (aliases.any((alias) => _sameName(entry.key, alias))) {
        return entry.value.first;
      }
    }
    return null;
  }

  /// Resolve expressions using a model-authored binding or conservative
  /// exact-name aliases. If the requested expression is unavailable, the
  /// model's explicit neutral expression is returned, if present.
  Live2DExpressionResolution resolveExpression(CharacterExpression requested) {
    final key = requested.name;
    final explicit = expressionMappings[key];
    if (explicit != null) {
      final match = _expressionFor(explicit);
      if (match != null) {
        return Live2DExpressionResolution(
          requested: requested,
          resolved: requested,
          expression: match,
          usedNeutralFallback: false,
        );
      }
    }
    final aliases = _expressionAliases[requested] ?? {key};
    for (final expression in expressions) {
      if (aliases.any((alias) => _sameName(expression.name, alias))) {
        return Live2DExpressionResolution(
          requested: requested,
          resolved: requested,
          expression: expression,
          usedNeutralFallback: false,
        );
      }
    }
    final neutral = expressionMappings['neutral'];
    final neutralAsset = neutral == null
        ? _expressionMatchingAliases(const {'neutral', 'default', 'normal'})
        : _expressionFor(neutral);
    return Live2DExpressionResolution(
      requested: requested,
      resolved: CharacterExpression.neutral,
      expression: neutralAsset,
      usedNeutralFallback: requested != CharacterExpression.neutral,
    );
  }

  Live2DExpressionAsset? _expressionFor(Live2DExpressionMapping mapping) {
    final index = mapping.index;
    if (index != null) {
      for (final expression in expressions) {
        if (expression.index == index) return expression;
      }
    }
    return _expressionMatchingName(mapping.name ?? '');
  }

  Live2DExpressionAsset? _expressionMatchingName(String name) {
    for (final expression in expressions) {
      if (_sameName(expression.name, name)) return expression;
    }
    return null;
  }

  Live2DExpressionAsset? _expressionMatchingAliases(Set<String> aliases) {
    for (final expression in expressions) {
      if (aliases.any((alias) => _sameName(expression.name, alias))) {
        return expression;
      }
    }
    return null;
  }
}

class Live2DMotion {
  const Live2DMotion({
    required this.group,
    required this.index,
    required this.file,
    this.sound,
    this.fadeInSeconds,
    this.fadeOutSeconds,
  });

  final String group;
  final int index;
  final String file;
  final String? sound;
  final double? fadeInSeconds;
  final double? fadeOutSeconds;
}

class Live2DExpressionAsset {
  const Live2DExpressionAsset({
    required this.index,
    required this.name,
    required this.file,
  });

  final int index;
  final String name;
  final String file;
}

class Live2DHitArea {
  const Live2DHitArea({required this.id, required this.name});

  final String id;
  final String name;
}

class Live2DActionMapping {
  const Live2DActionMapping({
    required this.group,
    required this.index,
    this.description = '',
    this.aliases = const [],
  });

  final String group;
  final int index;
  final String description;
  final List<String> aliases;
}

class Live2DExpressionMapping {
  const Live2DExpressionMapping({
    this.name,
    this.index,
    this.aliases = const [],
  }) : assert(name != null || index != null);

  final String? name;
  final int? index;
  final List<String> aliases;
}

class Live2DExpressionResolution {
  const Live2DExpressionResolution({
    required this.requested,
    required this.resolved,
    required this.expression,
    required this.usedNeutralFallback,
  });

  final CharacterExpression requested;
  final CharacterExpression resolved;
  final Live2DExpressionAsset? expression;
  final bool usedNeutralFallback;
}

class _ParsedManifest {
  const _ParsedManifest({
    this.idle,
    this.actions = const {},
    this.expressions = const {},
    this.parameterBindings = const {},
  });

  final Live2DActionMapping? idle;
  final Map<String, Live2DActionMapping> actions;
  final Map<String, Live2DExpressionMapping> expressions;
  final Map<String, String> parameterBindings;
}

_ParsedManifest _parseManifest(
  Map<String, Object?>? manifest,
  List<String> warnings,
) {
  if (manifest == null) return const _ParsedManifest();
  Live2DActionMapping? idle;
  if (manifest.containsKey('idle') && manifest['idle'] != null) {
    final value = _asMap(manifest['idle']);
    final rawGroup = value?['group'];
    final index = _integer(value?['index']);
    if (value == null || rawGroup is! String || index == null || index < 0) {
      warnings.add('Ignored invalid idle manifest entry.');
    } else {
      idle = Live2DActionMapping(group: rawGroup, index: index);
    }
  }
  final actions = <String, Live2DActionMapping>{};
  for (final entry in (_asMap(manifest['actions']) ?? const {}).entries) {
    final semantic = _semanticKey(entry.key);
    final value = _asMap(entry.value);
    if (semantic.isEmpty || value == null) continue;
    final rawGroup = value['group'];
    final index = _integer(value['index']);
    if (rawGroup is! String || index == null || index < 0) {
      warnings.add('Ignored invalid action manifest entry "${entry.key}".');
      continue;
    }
    actions[semantic] = Live2DActionMapping(
      group: rawGroup,
      index: index,
      description: _string(value['description']),
      aliases: _stringArray(value['aliases']),
    );
  }

  final expressions = <String, Live2DExpressionMapping>{};
  for (final entry in (_asMap(manifest['expressions']) ?? const {}).entries) {
    final semantic = _semanticKey(entry.key);
    final value = _asMap(entry.value);
    if (semantic.isEmpty || value == null) continue;
    final name = _string(value['name']);
    final index = _integer(value['index']);
    if (name.isEmpty && (index == null || index < 0)) {
      warnings.add('Ignored invalid expression manifest entry "${entry.key}".');
      continue;
    }
    expressions[semantic] = Live2DExpressionMapping(
      name: name.isEmpty ? null : name,
      index: index,
      aliases: _stringArray(value['aliases']),
    );
  }

  final parameters = <String, String>{};
  for (final entry in (_asMap(manifest['parameters']) ?? const {}).entries) {
    // Parameter roles are application API names (mouthOpen, angleX), not
    // action aliases. Preserve their casing for renderer lookup.
    final role = entry.key.trim();
    final parameterId = _string(entry.value);
    if (role.isNotEmpty && parameterId.isNotEmpty) {
      parameters[role] = parameterId;
    }
  }
  return _ParsedManifest(
    idle: idle,
    actions: Map.unmodifiable(actions),
    expressions: Map.unmodifiable(expressions),
    parameterBindings: Map.unmodifiable(parameters),
  );
}

const _actionAliases = <String, Set<String>>{
  'wave': {'wave', 'waving', 'greeting', 'greet', 'hello'},
  'nod': {'nod', 'nodding', 'yes'},
  'shake_head': {'shake_head', 'shakehead', 'headshake', 'no'},
  'bow': {'bow', 'bowing'},
  'think': {'think', 'thinking', 'ponder'},
  'surprised': {'surprised', 'surprise', 'shock'},
  'touch_reaction': {'touch_reaction', 'touchreaction', 'tap_body'},
};

const _expressionAliases = <CharacterExpression, Set<String>>{
  CharacterExpression.neutral: {'neutral', 'normal', 'default'},
  CharacterExpression.happy: {'happy', 'smile', 'joy', 'cheerful'},
  CharacterExpression.laughing: {'laughing', 'laugh', 'laughter'},
  CharacterExpression.angry: {'angry', 'anger', 'mad'},
  CharacterExpression.sad: {'sad', 'sorrow', 'unhappy'},
  CharacterExpression.crying: {'crying', 'cry', 'tears'},
  CharacterExpression.shy: {'shy', 'blush', 'embarrassed'},
  CharacterExpression.tease: {'tease', 'teasing', 'smug', 'playful'},
  CharacterExpression.cuddle: {'cuddle', 'affection', 'love'},
};

Map<String, Object?> _decodeObject(String source, String label) {
  final decoded = jsonDecode(source);
  final map = _asMap(decoded);
  if (map == null) throw FormatException('$label must be a JSON object.');
  return map;
}

Map<String, Object?>? _asMap(Object? value) {
  if (value is! Map) return null;
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

String _string(Object? value) => value is String ? value.trim() : '';

int? _integer(Object? value) => value is int ? value : null;

double? _number(Object? value) => value is num ? value.toDouble() : null;

List<String> _stringArray(Object? value) => value is List
    ? value
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList()
    : const [];

List<String> _stringList(
  Object? value, {
  required String field,
  required List<String> warnings,
}) {
  if (value is! List) return const [];
  final result = <String>[];
  for (final item in value) {
    final path = _bundlePath(item, field: field);
    if (path != null) result.add(path);
  }
  return result;
}

String? _bundlePath(
  Object? raw, {
  required String field,
  bool optional = false,
}) {
  final input = _string(raw).replaceAll('\\', '/');
  if (input.isEmpty) return null;
  final segments = <String>[];
  for (final segment in input.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..' || segment.contains(':')) {
      throw FormatException('$field must stay inside the model bundle.');
    }
    segments.add(segment);
  }
  if (segments.isEmpty || input.startsWith('/') || input.startsWith('//')) {
    if (optional) return null;
    throw FormatException('$field must be a non-empty bundle-relative path.');
  }
  return segments.join('/');
}

String _semanticKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');

bool _sameName(String left, String right) =>
    _semanticKey(left).replaceAll('_', '') ==
    _semanticKey(right).replaceAll('_', '');
