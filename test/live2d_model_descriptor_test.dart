import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_expression.dart';
import 'package:ryza_chat_mvp/src/live2d_model_descriptor.dart';

Map<String, dynamic> _model({
  List<Map<String, Object?>>? motions,
  List<Map<String, Object?>>? expressions,
  List<Map<String, Object?>>? groups,
}) => {
  'FileReferences': {
    'Moc': 'model.moc3',
    'Textures': ['textures/texture_00.png'],
    'Physics': 'physics.json',
    'Pose': 'pose.json',
    'Motions': {
      'Idle':
          motions ??
          [
            {'File': 'motions/idle.motion3.json'},
          ],
      'TapBody': [
        {'File': 'motions/wave.motion3.json', 'FadeInTime': 0.2},
      ],
    },
    'Expressions':
        expressions ??
        [
          {'Name': 'neutral', 'File': 'expressions/neutral.exp3.json'},
          {'Name': 'smile', 'File': 'expressions/smile.exp3.json'},
        ],
  },
  'Groups':
      groups ??
      [
        {
          'Target': 'Parameter',
          'Name': 'EyeBlink',
          'Ids': ['ParamEyeLOpen', 'ParamEyeROpen'],
        },
      ],
  'HitAreas': [
    {'Id': 'Head', 'Name': 'Head'},
  ],
};

void main() {
  test(
    'parses model references, groups, motions, expressions and hit areas',
    () {
      final descriptor = Live2DModelDescriptor.parse(jsonEncode(_model()));

      expect(descriptor.mocFile, 'model.moc3');
      expect(descriptor.textureFiles, ['textures/texture_00.png']);
      expect(descriptor.physicsFile, 'physics.json');
      expect(descriptor.poseFile, 'pose.json');
      expect(descriptor.motionGroups, containsAll(<String>['Idle', 'TapBody']));
      expect(descriptor.motions['TapBody']!.single.fadeInSeconds, 0.2);
      expect(
        descriptor.expressions.map((item) => item.name),
        contains('smile'),
      );
      expect(descriptor.parameterGroups['EyeBlink'], [
        'ParamEyeLOpen',
        'ParamEyeROpen',
      ]);
      expect(descriptor.hitAreas.single.id, 'Head');
      expect(descriptor.warnings, isEmpty);
    },
  );

  test(
    'manifest mappings are validated and aliases resolve exact resources',
    () {
      final descriptor = Live2DModelDescriptor.parse(
        jsonEncode(_model()),
        manifestJson: jsonEncode({
          'modelId': 'sample',
          'idle': {'group': 'Idle', 'index': 0},
          'actions': {
            'wave': {
              'group': 'TapBody',
              'index': 0,
              'aliases': ['hello gesture'],
            },
          },
          'expressions': {
            'happy': {'name': 'smile'},
          },
          'parameters': {'mouthOpen': 'ParamMouthOpenY'},
        }),
      );

      expect(descriptor.modelId, 'sample');
      expect(descriptor.idleMotion?.group, 'Idle');
      expect(descriptor.idleMotion?.index, 0);
      expect(
        descriptor.resolveAction('wave')!.file,
        'motions/wave.motion3.json',
      );
      expect(descriptor.resolveAction('hello gesture')!.group, 'TapBody');
      expect(
        descriptor
            .resolveExpression(CharacterExpression.happy)
            .expression!
            .name,
        'smile',
      );
      expect(descriptor.parameterBindings['mouthOpen'], 'ParamMouthOpenY');
    },
  );

  test(
    'missing actions return null rather than a semantically similar motion',
    () {
      final descriptor = Live2DModelDescriptor.parse(jsonEncode(_model()));

      expect(descriptor.resolveAction('hug'), isNull);
      // A generic Cubism group such as TapBody is not enough evidence to
      // infer a semantic wave. The model needs an explicit manifest mapping.
      expect(descriptor.resolveAction('wave'), isNull);
    },
  );

  test('missing expressions use explicit neutral fallback', () {
    final descriptor = Live2DModelDescriptor.parse(
      jsonEncode(
        _model(
          expressions: [
            {'Name': 'neutral', 'File': 'expressions/neutral.exp3.json'},
          ],
        ),
      ),
    );

    final result = descriptor.resolveExpression(CharacterExpression.angry);
    expect(result.usedNeutralFallback, isTrue);
    expect(result.resolved, CharacterExpression.neutral);
    expect(result.expression!.name, 'neutral');
  });

  test('rejects absolute and parent traversal paths', () {
    final badAbsolute = _model();
    (badAbsolute['FileReferences'] as Map<String, Object?>)['Moc'] =
        'C:/outside/model.moc3';
    expect(
      () => Live2DModelDescriptor.parse(jsonEncode(badAbsolute)),
      throwsFormatException,
    );

    final badParent = _model();
    (badParent['FileReferences'] as Map<String, Object?>)['Textures'] = [
      '../outside.png',
    ];
    expect(
      () => Live2DModelDescriptor.parse(jsonEncode(badParent)),
      throwsFormatException,
    );
  });

  test('invalid manifest mappings are ignored with a warning', () {
    final descriptor = Live2DModelDescriptor.parse(
      jsonEncode(_model()),
      manifestJson: jsonEncode({
        'idle': {'group': 'Unknown', 'index': 1},
        'actions': {
          'missing': {'group': 'Unknown', 'index': 4},
        },
        'expressions': {
          'angry': {'name': 'does-not-exist'},
        },
      }),
    );

    expect(descriptor.actionMappings, isEmpty);
    expect(descriptor.expressionMappings, isEmpty);
    expect(descriptor.idleMotion, isNull);
    expect(descriptor.warnings, hasLength(3));
  });

  test('an empty Cubism motion group can be selected as idle', () {
    final model = _model();
    final references = model['FileReferences'] as Map<String, Object?>;
    final motions = references['Motions'] as Map<String, Object?>;
    motions[''] = [
      {'File': 'motions/unnamed.motion3.json'},
    ];
    final descriptor = Live2DModelDescriptor.parse(
      jsonEncode(model),
      manifestJson: jsonEncode({
        'idle': {'group': '', 'index': 0},
      }),
    );

    expect(descriptor.motions, contains(''));
    expect(descriptor.idleMotion?.group, '');
    expect(descriptor.idleMotion?.file, 'motions/unnamed.motion3.json');
    expect(descriptor.warnings, isEmpty);
  });
}
