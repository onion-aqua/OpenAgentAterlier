import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/mapped_spine_view.dart';
import 'package:ryza_chat_mvp/src/model_performance_mapping.dart';
import 'package:ryza_chat_mvp/src/model_resource_catalog.dart';

ModelResourceCatalog _catalog() => ModelResourceCatalog(
  format: ModelResourceFormat.spine,
  sourceFingerprint: 'mapped-capabilities',
  runtimeVersion: '4.2.43',
  entryFile: 'model.skel',
  resources: const [
    ModelResource(
      id: 'animation:wait',
      kind: ModelResourceKinds.animation,
      name: 'wait',
      native: {'name': 'wait'},
    ),
    ModelResource(
      id: 'animation:wave',
      kind: ModelResourceKinds.animation,
      name: 'wave',
      native: {'name': 'wave'},
    ),
    ModelResource(
      id: 'animation:face_smile',
      kind: ModelResourceKinds.animation,
      name: 'face_smile',
      native: {'name': 'face_smile'},
    ),
    ModelResource(
      id: 'animation:lip',
      kind: ModelResourceKinds.animation,
      name: 'lip',
      native: {
        'name': 'lip',
        'normalizedMouthOpen': true,
        'mouthOpenRange': [0, 1],
      },
    ),
  ],
);

Map<String, Object?> _binding(String target, String description) => {
  'target': target,
  'description': description,
  'confidence': 0.9,
  'evidence': 'exact animation name',
};

ModelPerformanceMapping _mapping(ModelResourceCatalog catalog) =>
    ModelPerformanceMapping.fromJson({
      'schemaVersion': 1,
      'sourceFingerprint': catalog.sourceFingerprint,
      'format': 'spine',
      'label': 'Mapped rig',
      'idle': 'animation:wait',
      'actions': {'wave': _binding('animation:wave', 'wave hello')},
      'expressions': {
        'happy': _binding('animation:face_smile', 'smiling face'),
      },
      'parameters': {'mouthOpen': _binding('animation:lip', 'mouth opening')},
      'notes': <String>[],
    }, catalog: catalog);

void main() {
  test(
    'generated mapping bridge exposes only playable native capabilities',
    () {
      final catalog = _catalog();
      final gesture = jsonEncode(_mapping(catalog).toSpineGesture(catalog));
      final capabilities = MappedSpineCapabilities.parse(
        gesture,
        hasAnimation: const {'wait', 'wave', 'face_smile', 'lip'}.contains,
      );

      expect(capabilities.idle, 'wait');
      expect(capabilities.actions['wave']?.animation, 'wave');
      expect(capabilities.actions['wave']?.description, 'wave hello');
      expect(capabilities.expressions, {'happy': 'face_smile'});
      expect(capabilities.parameters, {'mouthOpen': 'lip'});
      expect(capabilities.groupId('wave'), 'grp_mapped_wave');
      expect(capabilities.actionForGroup('grp_mapped_wave'), 'wave');
      expect(capabilities.actionForGroup('grp_mapped_unknown'), isNull);
      expect(capabilities.actionForGroup('other_wave'), isNull);
    },
  );

  test('optional capabilities whose clips are absent stay unavailable', () {
    final catalog = _catalog();
    final gesture = jsonEncode(_mapping(catalog).toSpineGesture(catalog));
    final capabilities = MappedSpineCapabilities.parse(
      gesture,
      hasAnimation: const {'wait'}.contains,
    );

    expect(capabilities.idle, 'wait');
    expect(capabilities.actions, isEmpty);
    expect(capabilities.expressions, isEmpty);
    expect(capabilities.parameters, isEmpty);
  });

  test('idle is mandatory and must exist in the loaded skeleton', () {
    final missingIdle = jsonEncode({
      'ModelMapping.Runtime': {
        'idleAnimations': ['missing'],
        'actions': <String, Object?>{},
        'expressions': <String, Object?>{},
        'parameters': <String, Object?>{},
      },
    });
    expect(
      () => MappedSpineCapabilities.parse(
        missingIdle,
        hasAnimation: (_) => false,
      ),
      throwsFormatException,
    );
    expect(
      () => MappedSpineCapabilities.parse(
        jsonEncode({'emotionalGesture': <String, Object?>{}}),
        hasAnimation: (_) => true,
      ),
      throwsFormatException,
    );
  });

  test('malformed optional rows never create executable capabilities', () {
    final gesture = jsonEncode({
      'ModelMapping.Runtime': {
        'idleAnimations': ['wait'],
        'actions': {
          'missing': {'description': 'no animation'},
          'wrong': 'not an object',
          'bad_description': {'animation': 'wait', 'description': 7},
        },
        'expressions': {'happy': 7, 'neutral': 'not_loaded'},
        'parameters': {'mouthOpen': false},
      },
    });
    final capabilities = MappedSpineCapabilities.parse(
      gesture,
      hasAnimation: const {'wait'}.contains,
    );
    expect(capabilities.actions, isEmpty);
    expect(capabilities.expressions, isEmpty);
    expect(capabilities.parameters, isEmpty);
  });
}
