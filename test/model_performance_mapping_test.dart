import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/model_performance_mapping.dart';
import 'package:ryza_chat_mvp/src/model_resource_catalog.dart';

ModelResourceCatalog _spineCatalog() => ModelResourceCatalog(
  format: ModelResourceFormat.spine,
  sourceFingerprint: 'abc123',
  runtimeVersion: '4.2.43',
  entryFile: 'data.json',
  resources: const [
    ModelResource(
      id: 'animation:wait',
      kind: ModelResourceKinds.animation,
      name: 'wait',
      native: {'name': 'wait'},
    ),
    ModelResource(
      id: 'animation:hello',
      kind: ModelResourceKinds.animation,
      name: 'hello',
      native: {'name': 'hello'},
    ),
    ModelResource(
      id: 'animation:face_smile',
      kind: ModelResourceKinds.animation,
      name: 'face_smile',
      native: {'name': 'face_smile'},
    ),
    ModelResource(
      id: 'animation:mouth_scrub',
      kind: ModelResourceKinds.animation,
      name: 'mouth_scrub',
      native: {
        'name': 'mouth_scrub',
        'normalizedMouthOpen': true,
        'mouthOpenRange': [0, 1],
      },
    ),
    ModelResource(
      id: 'bone:head',
      kind: ModelResourceKinds.bone,
      name: 'head',
      native: {'name': 'head'},
    ),
  ],
);

ModelResourceCatalog _live2dCatalog() => ModelResourceCatalog(
  format: ModelResourceFormat.live2d,
  sourceFingerprint: 'live-fingerprint',
  runtimeVersion: 'Cubism 3+',
  entryFile: 'model.model3.json',
  resources: const [
    ModelResource(
      id: 'motion:Idle:0',
      kind: ModelResourceKinds.motion,
      name: 'Idle[0]',
      native: {'group': 'Idle', 'index': 0, 'file': 'idle.motion3.json'},
    ),
    ModelResource(
      id: 'motion:TapBody:1',
      kind: ModelResourceKinds.motion,
      name: 'TapBody[1]',
      native: {'group': 'TapBody', 'index': 1, 'file': 'wave.motion3.json'},
    ),
    ModelResource(
      id: 'motion::0',
      kind: ModelResourceKinds.motion,
      name: '[0]',
      native: {'group': '', 'index': 0, 'file': 'unnamed.motion3.json'},
    ),
    ModelResource(
      id: 'expression:Smile',
      kind: ModelResourceKinds.expression,
      name: 'Smile',
      native: {'name': 'Smile', 'index': 0, 'file': 'smile.exp3.json'},
    ),
    ModelResource(
      id: 'parameter:ParamMouthOpenY',
      kind: ModelResourceKinds.parameter,
      name: 'ParamMouthOpenY',
      native: {'id': 'ParamMouthOpenY'},
    ),
  ],
);

Map<String, Object?> _binding(
  String target, {
  String description = 'directly verified',
}) => {
  'target': target,
  'description': description,
  'confidence': 0.9,
  'evidence': 'exact resource name',
};

Map<String, Object?> _mapping({
  String fingerprint = 'abc123',
  String format = 'spine',
  Object? idle = 'animation:wait',
  Map<String, Object?>? actions,
  Map<String, Object?>? expressions,
  Map<String, Object?>? parameters,
}) => {
  'schemaVersion': 1,
  'sourceFingerprint': fingerprint,
  'format': format,
  'label': 'Mapped model',
  'idle': idle,
  'actions': actions ?? {'wave': _binding('animation:hello')},
  'expressions': expressions ?? {'happy': _binding('animation:face_smile')},
  'parameters': parameters ?? {},
  'notes': ['Uncertain resources were left unbound.'],
};

void main() {
  test('validates and round trips a fingerprint-bound Spine mapping', () {
    final catalog = _spineCatalog();
    final mapping = ModelPerformanceMapping.parse(
      jsonEncode(_mapping()),
      catalog: catalog,
    );

    expect(mapping.actions['wave']!.target, 'animation:hello');
    expect(
      ModelPerformanceMapping.fromJson(
        mapping.toJson(),
        catalog: catalog,
      ).toJson(),
      mapping.toJson(),
    );
  });

  test('rejects unknown fields, resources, kinds and semantics', () {
    final catalog = _spineCatalog();
    final unknownField = _mapping()..['runtimeSupported'] = true;
    expect(
      () => ModelPerformanceMapping.fromJson(unknownField, catalog: catalog),
      throwsFormatException,
    );
    expect(
      () => ModelPerformanceMapping.fromJson(
        _mapping(actions: {'wave': _binding('animation:missing')}),
        catalog: catalog,
      ),
      throwsFormatException,
    );
    expect(
      () => ModelPerformanceMapping.fromJson(
        _mapping(actions: {'wave': _binding('bone:head')}),
        catalog: catalog,
      ),
      throwsFormatException,
    );
    expect(
      () => ModelPerformanceMapping.fromJson(
        _mapping(expressions: {'surprised': _binding('animation:face_smile')}),
        catalog: catalog,
      ),
      throwsFormatException,
    );
    expect(
      () => ModelPerformanceMapping.fromJson(
        _mapping(parameters: {'unknownRole': _binding('animation:hello')}),
        catalog: catalog,
      ),
      throwsFormatException,
    );
  });

  test('rejects invalid confidence and stale fingerprint', () {
    final catalog = _spineCatalog();
    final bad = _binding('animation:hello')..['confidence'] = double.nan;
    expect(
      () => ModelPerformanceMapping.fromJson(
        _mapping(actions: {'wave': bad}),
        catalog: catalog,
      ),
      throwsFormatException,
    );
    expect(
      () => ModelPerformanceMapping.fromJson(
        _mapping(fingerprint: 'stale'),
        catalog: catalog,
      ),
      throwsFormatException,
    );
  });

  test('accepts standard and custom action slugs for direct grp playback', () {
    final mapping = ModelPerformanceMapping.fromJson(
      _mapping(
        actions: {
          'acknowledge': _binding('animation:hello'),
          'custom_hand_pose': _binding('animation:hello'),
        },
      ),
      catalog: _spineCatalog(),
    );

    expect(
      mapping.actions.keys,
      containsAll(['acknowledge', 'custom_hand_pose']),
    );
  });

  test('Spine mouthOpen requires verified normalized scrub metadata', () {
    expect(
      () => ModelPerformanceMapping.fromJson(
        _mapping(parameters: {'mouthOpen': _binding('animation:hello')}),
        catalog: _spineCatalog(),
      ),
      throwsFormatException,
    );

    final mapping = ModelPerformanceMapping.fromJson(
      _mapping(parameters: {'mouthOpen': _binding('animation:mouth_scrub')}),
      catalog: _spineCatalog(),
    );
    expect(mapping.parameters['mouthOpen']!.target, 'animation:mouth_scrub');
  });

  test('Spine bridge exposes native names in isolated runtime metadata', () {
    final catalog = _spineCatalog();
    final mapping = ModelPerformanceMapping.fromJson(
      _mapping(),
      catalog: catalog,
    );
    final gesture = mapping.toSpineGesture(catalog);
    final runtime = gesture['ModelMapping.Runtime'] as Map;

    expect(runtime['idleAnimations'], ['wait']);
    expect(runtime['posture'], 'mapped');
    expect(runtime['rigProfile'], 'generic_spine');
    expect((runtime['actions'] as Map)['wave']['animation'], 'hello');
    expect((runtime['expressions'] as Map)['happy'], 'face_smile');
    expect(runtime['parameters'], isEmpty);
    final groups = (gesture['emotionalGesture'] as Map)['MotionGroups'] as List;
    expect(groups.single['AnimName_1'], 'hello');
  });

  test(
    'Live2D bridge uses verified group, index, expression and parameter',
    () {
      final catalog = _live2dCatalog();
      final mapping = ModelPerformanceMapping.fromJson(
        _mapping(
          fingerprint: 'live-fingerprint',
          format: 'live2d',
          idle: 'motion:Idle:0',
          actions: {'wave': _binding('motion:TapBody:1')},
          expressions: {'happy': _binding('expression:Smile')},
          parameters: {'mouthOpen': _binding('parameter:ParamMouthOpenY')},
        ),
        catalog: catalog,
      );
      final manifest = mapping.toLive2dManifest(catalog);

      expect(manifest['idle'], {'group': 'Idle', 'index': 0});
      expect(manifest['actions'], {
        'wave': {
          'group': 'TapBody',
          'index': 1,
          'description': 'directly verified',
        },
      });
      expect(manifest['expressions'], {
        'happy': {'name': 'Smile'},
      });
      expect(manifest['parameters'], {'mouthOpen': 'ParamMouthOpenY'});
    },
  );

  test('Live2D may deliberately leave idle and uncertain sections empty', () {
    final catalog = _live2dCatalog();
    final mapping = ModelPerformanceMapping.fromJson(
      _mapping(
        fingerprint: 'live-fingerprint',
        format: 'live2d',
        idle: null,
        actions: const {},
        expressions: const {},
        parameters: const {},
      ),
      catalog: catalog,
    );
    expect(mapping.idle, isNull);
    expect(mapping.toLive2dManifest(catalog)['actions'], isEmpty);
  });

  test('Live2D bridge preserves an unnamed Cubism motion group', () {
    final catalog = _live2dCatalog();
    final mapping = ModelPerformanceMapping.fromJson(
      _mapping(
        fingerprint: 'live-fingerprint',
        format: 'live2d',
        idle: 'motion::0',
        actions: {'wave': _binding('motion::0')},
        expressions: const {},
        parameters: const {},
      ),
      catalog: catalog,
    );

    final manifest = mapping.toLive2dManifest(catalog);
    expect(manifest['idle'], {'group': '', 'index': 0});
    expect((manifest['actions'] as Map)['wave']['group'], '');
  });

  test('Spine rejects a missing idle while Live2D permits it', () {
    expect(
      () => ModelPerformanceMapping.fromJson(
        _mapping(idle: null),
        catalog: _spineCatalog(),
      ),
      throwsFormatException,
    );

    final live2d = ModelPerformanceMapping.fromJson(
      _mapping(
        fingerprint: 'live-fingerprint',
        format: 'live2d',
        idle: null,
        actions: const {},
        expressions: const {},
        parameters: const {},
      ),
      catalog: _live2dCatalog(),
    );
    expect(live2d.idle, isNull);
  });
}
