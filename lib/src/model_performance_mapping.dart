import 'dart:convert';

import 'character_expression.dart';
import 'model_resource_catalog.dart';

const modelPerformanceMappingSchemaVersion = 1;

const supportedModelParameterRoles = <String>{
  'mouthOpen',
  'eyeBlinkLeft',
  'eyeBlinkRight',
  'eyeOpenLeft',
  'eyeOpenRight',
  'gazeX',
  'gazeY',
  'angleX',
  'angleY',
  'angleZ',
  'bodyAngleX',
  'bodyAngleY',
  'bodyAngleZ',
  'breath',
};

class ModelPerformanceBinding {
  const ModelPerformanceBinding({
    required this.target,
    required this.description,
    required this.confidence,
    required this.evidence,
  });

  final String target;
  final String description;
  final double confidence;
  final String evidence;

  Map<String, Object?> toJson() => {
    'target': target,
    'description': description,
    'confidence': confidence,
    'evidence': evidence,
  };
}

/// Renderer-facing values resolved from a fingerprint-bound resource catalog.
///
/// The persisted mapping stores resource IDs. This view contains only native
/// names that were resolved from the same catalog at the point of use.
class ModelPerformanceRuntime {
  const ModelPerformanceRuntime({
    required this.idleAnimations,
    required this.posture,
    required this.rigProfile,
    required this.actions,
    required this.expressions,
    required this.parameters,
  });

  final List<String> idleAnimations;
  final String posture;
  final String rigProfile;
  final Map<String, Map<String, Object?>> actions;
  final Map<String, String> expressions;
  final Map<String, String> parameters;

  Map<String, Object?> toJson() => {
    'idleAnimations': idleAnimations,
    'posture': posture,
    'rigProfile': rigProfile,
    'actions': actions,
    'expressions': expressions,
    'parameters': parameters,
  };
}

class ModelPerformanceMapping {
  ModelPerformanceMapping({
    required this.sourceFingerprint,
    required this.format,
    required this.label,
    required this.idle,
    required Map<String, ModelPerformanceBinding> actions,
    required Map<String, ModelPerformanceBinding> expressions,
    required Map<String, ModelPerformanceBinding> parameters,
    required List<String> notes,
  }) : actions = Map.unmodifiable(actions),
       expressions = Map.unmodifiable(expressions),
       parameters = Map.unmodifiable(parameters),
       notes = List.unmodifiable(notes);

  final String sourceFingerprint;
  final ModelResourceFormat format;
  final String label;
  final String? idle;
  final Map<String, ModelPerformanceBinding> actions;
  final Map<String, ModelPerformanceBinding> expressions;
  final Map<String, ModelPerformanceBinding> parameters;
  final List<String> notes;

  factory ModelPerformanceMapping.parse(
    String source, {
    required ModelResourceCatalog catalog,
  }) {
    if (utf8.encode(source).length > 128 * 1024) {
      throw const FormatException('Performance mapping exceeds 128 KB.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Performance mapping must be valid JSON.');
    }
    return ModelPerformanceMapping.fromJson(
      _object(decoded, 'mapping'),
      catalog: catalog,
    );
  }

  factory ModelPerformanceMapping.fromJson(
    Map<Object?, Object?> json, {
    required ModelResourceCatalog catalog,
  }) {
    const fields = {
      'schemaVersion',
      'sourceFingerprint',
      'format',
      'label',
      'idle',
      'actions',
      'expressions',
      'parameters',
      'notes',
    };
    _exactKeys(json, fields, 'mapping');
    if (json['schemaVersion'] != modelPerformanceMappingSchemaVersion) {
      throw const FormatException('Unsupported performance mapping schema.');
    }
    final fingerprint = _text(
      json['sourceFingerprint'],
      'sourceFingerprint',
      maxLength: 256,
    );
    if (fingerprint != catalog.sourceFingerprint) {
      throw const FormatException(
        'Performance mapping does not match the inspected model.',
      );
    }
    final rawFormat = _text(json['format'], 'format', maxLength: 16);
    if (rawFormat != catalog.format.name) {
      throw const FormatException('Performance mapping format mismatch.');
    }
    final label = _text(json['label'], 'label', maxLength: 120);
    final idle = switch (json['idle']) {
      null => null,
      String value when value.trim().isNotEmpty => value.trim(),
      _ => throw const FormatException('idle must be a resource ID or null.'),
    };
    if (catalog.format == ModelResourceFormat.spine && idle == null) {
      throw const FormatException(
        'A Spine mapping requires a verified idle animation.',
      );
    }
    if (idle != null) {
      final resource = _resource(catalog, idle, 'idle');
      final expected = switch (catalog.format) {
        ModelResourceFormat.spine => ModelResourceKinds.animation,
        ModelResourceFormat.live2d => ModelResourceKinds.motion,
        ModelResourceFormat.vrm => ModelResourceKinds.animation,
      };
      _requireKind(resource, {expected}, 'idle');
    }

    final actions = _bindings(
      json['actions'],
      field: 'actions',
      maxEntries: 64,
      validateSemantic: (semantic) {
        if (semantic == 'none' ||
            !RegExp(r'^[a-z][a-z0-9_]{0,47}$').hasMatch(semantic)) {
          throw FormatException('Invalid action semantic: $semantic');
        }
      },
      validateTarget: (semantic, binding) {
        final resource = _resource(catalog, binding.target, 'action $semantic');
        _requireKind(resource, switch (catalog.format) {
          ModelResourceFormat.spine => {ModelResourceKinds.animation},
          ModelResourceFormat.live2d => {ModelResourceKinds.motion},
          ModelResourceFormat.vrm => {
            ModelResourceKinds.animation,
            ModelResourceKinds.motion,
          },
        }, 'action $semantic');
      },
    );
    final faceNames = CharacterExpression.values
        .map((value) => value.name)
        .toSet();
    final expressions = _bindings(
      json['expressions'],
      field: 'expressions',
      maxEntries: faceNames.length,
      validateSemantic: (semantic) {
        if (!faceNames.contains(semantic)) {
          throw FormatException('Unsupported expression semantic: $semantic');
        }
      },
      validateTarget: (semantic, binding) {
        final resource = _resource(
          catalog,
          binding.target,
          'expression $semantic',
        );
        _requireKind(
          resource,
          catalog.format == ModelResourceFormat.spine
              ? {ModelResourceKinds.animation}
              : {ModelResourceKinds.expression},
          'expression $semantic',
        );
      },
    );
    final parameters = _bindings(
      json['parameters'],
      field: 'parameters',
      maxEntries: supportedModelParameterRoles.length,
      validateSemantic: (semantic) {
        if (!supportedModelParameterRoles.contains(semantic)) {
          throw FormatException('Unsupported parameter role: $semantic');
        }
      },
      validateTarget: (semantic, binding) {
        final resource = _resource(
          catalog,
          binding.target,
          'parameter $semantic',
        );
        _requireKind(
          resource,
          catalog.format == ModelResourceFormat.spine
              ? {ModelResourceKinds.animation}
              : {ModelResourceKinds.parameter},
          'parameter $semantic',
        );
        if (semantic == 'mouthOpen' &&
            catalog.format == ModelResourceFormat.spine &&
            !_hasVerifiedMouthOpenRange(resource)) {
          throw const FormatException(
            'Spine mouthOpen requires catalog evidence for a normalized '
            'closed-to-open scrub range.',
          );
        }
      },
    );
    final rawNotes = json['notes'];
    if (rawNotes is! List || rawNotes.length > 32) {
      throw const FormatException(
        'notes must be a list with at most 32 items.',
      );
    }
    final notes = <String>[
      for (var index = 0; index < rawNotes.length; index++)
        _text(rawNotes[index], 'notes[$index]', maxLength: 500),
    ];

    return ModelPerformanceMapping(
      sourceFingerprint: fingerprint,
      format: catalog.format,
      label: label,
      idle: idle,
      actions: actions,
      expressions: expressions,
      parameters: parameters,
      notes: notes,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': modelPerformanceMappingSchemaVersion,
    'sourceFingerprint': sourceFingerprint,
    'format': format.name,
    'label': label,
    'idle': idle,
    'actions': {
      for (final entry in actions.entries) entry.key: entry.value.toJson(),
    },
    'expressions': {
      for (final entry in expressions.entries) entry.key: entry.value.toJson(),
    },
    'parameters': {
      for (final entry in parameters.entries) entry.key: entry.value.toJson(),
    },
    'notes': notes,
  };

  ModelPerformanceRuntime runtimeFor(ModelResourceCatalog catalog) {
    _checkCatalog(catalog);
    if (format != ModelResourceFormat.spine) {
      throw StateError('Generic runtime metadata is Spine-only.');
    }
    String animation(String id) =>
        _nativeText(_resource(catalog, id, id), 'name', 'Spine animation');
    return ModelPerformanceRuntime(
      idleAnimations: [if (idle case final value?) animation(value)],
      posture: 'mapped',
      rigProfile: 'generic_spine',
      actions: Map.unmodifiable({
        for (final entry in actions.entries)
          entry.key: {
            'animation': animation(entry.value.target),
            'description': entry.value.description,
            'confidence': entry.value.confidence,
            'evidence': entry.value.evidence,
          },
      }),
      expressions: Map.unmodifiable({
        for (final entry in expressions.entries)
          entry.key: animation(entry.value.target),
      }),
      parameters: Map.unmodifiable({
        for (final entry in parameters.entries)
          entry.key: animation(entry.value.target),
      }),
    );
  }

  Map<String, Object?> toSpineGesture(ModelResourceCatalog catalog) {
    _checkCatalog(catalog, expected: ModelResourceFormat.spine);
    final runtime = runtimeFor(catalog);
    return {
      'schemaVersion': 1,
      'id':
          'mapped_${sourceFingerprint.substring(0, sourceFingerprint.length.clamp(0, 12))}',
      'name': label,
      'description': 'Validated generic Spine performance mapping.',
      'emotionalGesture': {
        'schemaVersion': 1,
        'MotionGroups': [
          for (final entry in runtime.actions.entries)
            {
              'GroupId': 'grp_mapped_${entry.key}',
              'Label': entry.value['description'],
              'OccupancyLetters': '',
              'AnimName_1': entry.value['animation'],
              'AnimName_2': '',
              'Alpha1': '1.00',
              'Alpha2': '',
              'Speed1': '1.00',
              'Speed2': '',
              'BlendTime': '0.30',
              'ApplicablePoseIds': '',
              'ApplicableSittingIDs': '',
              'GroupWeight': '0.00',
              'RepeatCount': '0',
              'VariantIndex': '0',
              'VariantWeight': '1.00',
            },
        ],
      },
      'ModelMapping.Runtime': {
        'schemaVersion': 1,
        'sourceFingerprint': sourceFingerprint,
        ...runtime.toJson(),
      },
    };
  }

  Map<String, Object?> toLive2dManifest(ModelResourceCatalog catalog) {
    _checkCatalog(catalog, expected: ModelResourceFormat.live2d);
    return {
      'modelId': label,
      if (idle case final idleId?)
        'idle': () {
          final resource = _resource(catalog, idleId, 'idle');
          final group = _nativeText(
            resource,
            'group',
            'Live2D idle motion group',
            allowEmpty: true,
          );
          final index = resource.native['index'];
          if (index is! int || index < 0) {
            throw StateError(
              'Live2D idle motion ${resource.id} has no valid index.',
            );
          }
          return {'group': group, 'index': index};
        }(),
      'actions': {
        for (final entry in actions.entries)
          entry.key: () {
            final resource = _resource(catalog, entry.value.target, entry.key);
            final group = _nativeText(
              resource,
              'group',
              'Live2D motion group',
              allowEmpty: true,
            );
            final index = resource.native['index'];
            if (index is! int || index < 0) {
              throw StateError(
                'Live2D motion ${resource.id} has no valid index.',
              );
            }
            return {
              'group': group,
              'index': index,
              'description': entry.value.description,
            };
          }(),
      },
      'expressions': {
        for (final entry in expressions.entries)
          entry.key: {
            'name': _nativeText(
              _resource(catalog, entry.value.target, entry.key),
              'name',
              'Live2D expression',
            ),
          },
      },
      'parameters': {
        for (final entry in parameters.entries)
          entry.key: _nativeText(
            _resource(catalog, entry.value.target, entry.key),
            'id',
            'Live2D parameter',
          ),
      },
    };
  }

  void _checkCatalog(
    ModelResourceCatalog catalog, {
    ModelResourceFormat? expected,
  }) {
    if (catalog.sourceFingerprint != sourceFingerprint ||
        catalog.format != format ||
        (expected != null && format != expected)) {
      throw StateError('Mapping and model resource catalog do not match.');
    }
  }
}

Map<String, Object?> toSpineGesture(
  ModelPerformanceMapping mapping,
  ModelResourceCatalog catalog,
) => mapping.toSpineGesture(catalog);

Map<String, Object?> toLive2dManifest(
  ModelPerformanceMapping mapping,
  ModelResourceCatalog catalog,
) => mapping.toLive2dManifest(catalog);

Map<String, ModelPerformanceBinding> _bindings(
  Object? value, {
  required String field,
  required int maxEntries,
  required void Function(String semantic) validateSemantic,
  required void Function(String semantic, ModelPerformanceBinding binding)
  validateTarget,
}) {
  final raw = _object(value, field);
  if (raw.length > maxEntries) {
    throw FormatException('$field contains too many entries.');
  }
  final result = <String, ModelPerformanceBinding>{};
  for (final entry in raw.entries) {
    final semantic = entry.key;
    validateSemantic(semantic);
    final bindingJson = _object(entry.value, '$field.$semantic');
    _exactKeys(bindingJson, const {
      'target',
      'description',
      'confidence',
      'evidence',
    }, '$field.$semantic');
    final confidenceValue = bindingJson['confidence'];
    if (confidenceValue is! num ||
        !confidenceValue.isFinite ||
        confidenceValue < 0 ||
        confidenceValue > 1) {
      throw FormatException('$field.$semantic.confidence must be from 0 to 1.');
    }
    final binding = ModelPerformanceBinding(
      target: _text(
        bindingJson['target'],
        '$field.$semantic.target',
        maxLength: 256,
      ),
      description: _text(
        bindingJson['description'],
        '$field.$semantic.description',
        maxLength: 300,
      ),
      confidence: confidenceValue.toDouble(),
      evidence: _text(
        bindingJson['evidence'],
        '$field.$semantic.evidence',
        maxLength: 500,
      ),
    );
    validateTarget(semantic, binding);
    result[semantic] = binding;
  }
  return Map.unmodifiable(result);
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$field must be a JSON object.');
  }
  return {for (final entry in value.entries) entry.key as String: entry.value};
}

void _exactKeys(
  Map<Object?, Object?> value,
  Set<String> allowed,
  String field,
) {
  final keys = value.keys.whereType<String>().toSet();
  if (value.keys.any((key) => key is! String) ||
      !keys.containsAll(allowed) ||
      !allowed.containsAll(keys)) {
    throw FormatException('$field has missing or unknown fields.');
  }
}

String _text(Object? value, String field, {required int maxLength}) {
  if (value is! String) throw FormatException('$field must be text.');
  final result = value.trim();
  if (result.isEmpty || result.length > maxLength) {
    throw FormatException('$field must contain 1-$maxLength characters.');
  }
  return result;
}

ModelResource _resource(ModelResourceCatalog catalog, String id, String field) {
  final resource = catalog.resourceById(id);
  if (resource == null) {
    throw FormatException('$field references an unknown resource: $id');
  }
  return resource;
}

void _requireKind(ModelResource resource, Set<String> kinds, String field) {
  if (!kinds.contains(resource.kind)) {
    throw FormatException(
      '$field must reference ${kinds.join(' or ')}, not ${resource.kind}.',
    );
  }
}

String _nativeText(
  ModelResource resource,
  String key,
  String label, {
  bool allowEmpty = false,
}) {
  final value = resource.native[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw StateError('$label ${resource.id} has no native $key.');
  }
  return allowEmpty ? value : value.trim();
}

bool _hasVerifiedMouthOpenRange(ModelResource resource) {
  if (resource.native['normalizedMouthOpen'] == true) return true;
  bool isRange(Object? value) {
    if (value is List && value.length == 2) {
      final closed = value[0], open = value[1];
      return closed is num &&
          open is num &&
          closed.isFinite &&
          open.isFinite &&
          closed <= 0 &&
          open >= 1;
    }
    if (value is Map) {
      final closed = value['closed'] ?? value['min'];
      final open = value['open'] ?? value['max'];
      return closed is num &&
          open is num &&
          closed.isFinite &&
          open.isFinite &&
          closed <= 0 &&
          open >= 1;
    }
    return false;
  }

  return isRange(resource.native['mouthOpenRange']) ||
      isRange(resource.native['scrubRange']);
}
