import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:ryza_chat_mvp/src/model_resource_catalog.dart';

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _png(int width, int height) {
  final bytes = Uint8List(33);
  bytes.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
  bytes.setAll(12, ascii.encode('IHDR'));
  ByteData.sublistView(bytes)
    ..setUint32(16, width)
    ..setUint32(20, height);
  return bytes;
}

Uint8List _spineJsonZip({String version = '4.2.43'}) => _zip({
  'hero.json': utf8.encode(
    jsonEncode({
      'skeleton': {'spine': version},
      'bones': [
        {'name': 'root'},
        {'name': 'head', 'parent': 'root'},
      ],
      'slots': [
        {'name': 'face', 'bone': 'head', 'attachment': 'face'},
        {'name': 'tap', 'bone': 'root', 'attachment': 'tap'},
      ],
      'skins': {
        'default': {
          'tap': {
            'tap': {
              'type': 'boundingbox',
              'vertices': [0, 0, 1, 0, 1, 1],
            },
          },
        },
      },
      'ik': [
        {'name': 'legs'},
      ],
      'animations': {
        'idle': {
          'bones': {
            'root': {
              'rotate': [
                {'time': 0},
                {'time': 2.5, 'angle': 1},
              ],
            },
          },
        },
        'instant': <String, Object?>{},
      },
      'events': {'loop_start': <String, Object?>{}},
    }),
  ),
  'hero.atlas': utf8.encode('hero.png\nsize: 1,1\n'),
  'hero.png': _png(1, 1),
  'hero_gesture.json': utf8.encode(
    jsonEncode({
      'emotionalGesture': {
        'MotionGroups': [
          {
            'GroupId': 'idle_group',
            'Label': 'Idle',
            'AnimName_1': 'idle',
            'AnimName_2': '',
            'OccupancyLetters': 'A',
          },
        ],
      },
    }),
  ),
});

Uint8List _unsupportedSpineBinaryZip() {
  final version = ascii.encode('3.6.53');
  return _zip({
    'hero.skel': [...List<int>.filled(8, 0), version.length + 1, ...version],
    'hero.atlas': utf8.encode('hero.png\nsize: 1,1\n'),
    'hero.png': _png(1, 1),
  });
}

Uint8List _knownTemplateSpineJsonZip() => _zip({
  'crf_skn_002_0001_01.json': utf8.encode(
    jsonEncode({
      'skeleton': {'spine': '4.2.43'},
      'bones': [
        {'name': 'root'},
      ],
      'animations': {
        'motion_A_001_idle': <String, Object?>{},
        'motion_add_B_002_active': <String, Object?>{},
      },
    }),
  ),
  'crf_skn_002_0001_01.atlas': utf8.encode(
    'crf_skn_002_0001_01.png\nsize: 1,1\n',
  ),
  'crf_skn_002_0001_01.png': _png(1, 1),
});

Uint8List _live2dZip() => _zip({
  'haru/haru.model3.json': utf8.encode(
    jsonEncode({
      'Version': 3,
      'FileReferences': {
        'Moc': 'haru.moc3',
        'Textures': ['textures/texture.png'],
        'DisplayInfo': 'haru.cdi3.json',
        'Motions': {
          'Idle': [
            {
              'File': 'motions/idle.motion3.json',
              'FadeInTime': 0.5,
              'FadeOutTime': 0.7,
            },
          ],
        },
        'Expressions': [
          {'Name': 'Smile', 'File': 'expressions/smile.exp3.json'},
        ],
      },
      'Groups': [
        {
          'Target': 'Parameter',
          'Name': 'LipSync',
          'Ids': ['ParamMouthOpenY'],
        },
      ],
      'HitAreas': [
        {'Id': 'HitAreaHead', 'Name': 'Head'},
      ],
    }),
  ),
  'haru/haru.moc3': [1, 2, 3],
  'haru/textures/texture.png': [1],
  'haru/haru.cdi3.json': utf8.encode(
    jsonEncode({
      'Parameters': [
        {'Id': 'ParamAngleX', 'Name': 'Face angle X'},
      ],
    }),
  ),
  'haru/motions/idle.motion3.json': utf8.encode(
    jsonEncode({
      'Meta': {'Duration': 3.25},
      'Curves': [
        {'Target': 'Parameter', 'Id': 'ParamAngleX'},
      ],
    }),
  ),
  'haru/expressions/smile.exp3.json': utf8.encode(
    jsonEncode({
      'Parameters': [
        {'Id': 'ParamEyeLOpen', 'Value': 0.8},
      ],
    }),
  ),
  'haru/performance.manifest.json': utf8.encode(
    jsonEncode({
      'actions': {
        'idle': {'group': 'Idle', 'index': 0, 'description': 'calm idle'},
      },
      'expressions': {
        'happy': {'name': 'Smile'},
      },
      'parameters': {'mouthOpen': 'ParamMouthOpenY'},
    }),
  ),
});

Uint8List _vrmGlb() {
  final jsonBytes = utf8.encode(
    jsonEncode({
      'asset': {'version': '2.0'},
      'extensions': {
        'VRMC_vrm': {
          'specVersion': '1.0',
          'humanoid': {
            'humanBones': {
              'hips': {'node': 0},
              'head': {'node': 1},
            },
          },
          'expressions': {
            'preset': {
              'happy': <String, Object?>{},
              'blink': <String, Object?>{},
            },
            'custom': {'smirk': <String, Object?>{}},
          },
        },
      },
    }),
  );
  final paddedLength = (jsonBytes.length + 3) & ~3;
  final result = Uint8List(20 + paddedLength);
  result.setAll(0, ascii.encode('glTF'));
  final data = ByteData.sublistView(result);
  data
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, result.length, Endian.little)
    ..setUint32(12, paddedLength, Endian.little)
    ..setUint32(16, 0x4e4f534a, Endian.little);
  result.fillRange(20, result.length, 0x20);
  result.setAll(20, jsonBytes);
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog enforces globally unique resource IDs', () {
    expect(
      () => ModelResourceCatalog(
        format: ModelResourceFormat.spine,
        sourceFingerprint: 'hash',
        runtimeVersion: '4.2',
        entryFile: 'data.skel',
        resources: const [
          ModelResource(id: 'animation:idle', kind: 'animation', name: 'idle'),
          ModelResource(id: 'animation:idle', kind: 'animation', name: 'idle'),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('prompt export is complete and refuses silent truncation', () {
    final catalog = ModelResourceCatalog(
      format: ModelResourceFormat.live2d,
      sourceFingerprint: 'hash',
      runtimeVersion: 'Cubism 3',
      entryFile: 'model.model3.json',
      resources: const [
        ModelResource(
          id: 'motion:Idle:0',
          kind: ModelResourceKinds.motion,
          name: 'Idle[0]',
          native: {'group': 'Idle', 'index': 0},
        ),
      ],
    );
    expect(catalog.resourceById('motion:Idle:0')?.name, 'Idle[0]');
    expect((catalog.toPromptJson()['resources'] as List), hasLength(1));
    expect(() => catalog.toPromptJson(maxEncodedBytes: 1), throwsStateError);
  });

  test('Spine JSON exposes compact metadata and package mapping', () async {
    final catalog = await inspectModelResources(
      _spineJsonZip(),
      format: ModelResourceFormat.spine,
    );
    expect(catalog.runtimeSupported, isTrue);
    expect(catalog.runtimeVersion, '4.2.43');
    expect(catalog.entryFile, 'hero.json');
    expect(catalog.sourceFingerprint, hasLength(64));
    expect(catalog.resourceById('animation:idle')?.duration, 2.5);
    expect(catalog.resourceById('bone:head')?.native['parent'], 'root');
    expect(catalog.resourceById('slot:face')?.native['bone'], 'head');
    expect(catalog.resourceById('skin:default'), isNotNull);
    expect(catalog.resourceById('hitArea:default:tap:tap'), isNotNull);
    expect(catalog.resourceById('constraint:ik:legs'), isNotNull);
    expect(catalog.resourceById('event:loop_start'), isNotNull);
    expect(
      (catalog.existingMapping['motionGroups'] as Map)['idle_group'],
      isNotNull,
    );
  });

  test('known Spine base uses compact built-in template evidence', () async {
    final catalog = await inspectModelResources(
      _knownTemplateSpineJsonZip(),
      format: ModelResourceFormat.spine,
    );
    expect(catalog.existingMapping['templateId'], 'seated_01');
    expect(catalog.existingMapping['gestureFile'], 'builtin:seated_01');
    final groups = catalog.existingMapping['motionGroups'] as Map;
    expect(groups.length, greaterThan(50));
    expect((groups['grp_b_01'] as Map)['resources'], [
      'animation:motion_add_B_002_active',
    ]);
    expect(jsonEncode(catalog.toPromptJson()), isNot(contains('DriverDefs')));
  });

  test('Spine 3.6 JSON selects the Android legacy renderer', () async {
    final catalog = await inspectModelResources(
      _spineJsonZip(version: '3.6.53'),
      format: ModelResourceFormat.spine,
    );
    expect(catalog.runtimeSupported, isTrue);
    expect(catalog.compatibilityIssues, isEmpty);
    expect(catalog.resourceById('animation:idle'), isNotNull);
  });

  test('Spine 3.6 stays blocked on platforms without its renderer', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final catalog = await inspectModelResources(
      _spineJsonZip(version: '3.6.53'),
      format: ModelResourceFormat.spine,
    );
    expect(catalog.runtimeSupported, isFalse);
    expect(catalog.compatibilityIssues.single, contains('requires Android'));
  });

  test('unsupported Spine binary is rejected before native loading', () async {
    final catalog = await inspectModelResources(
      _unsupportedSpineBinaryZip(),
      format: ModelResourceFormat.spine,
    );
    expect(catalog.runtimeVersion, '3.6.53');
    expect(catalog.runtimeSupported, isFalse);
    expect(catalog.resources, isEmpty);
    expect(catalog.compatibilityIssues.single, contains('bundled 4.2 runtime'));
  });

  test('does not treat Spine 4.20 as runtime-compatible 4.2', () async {
    final catalog = await inspectModelResources(
      _spineJsonZip(version: '4.20.1'),
      format: ModelResourceFormat.spine,
    );
    expect(catalog.runtimeSupported, isFalse);
    expect(catalog.runtimeVersion, '4.20.1');
  });

  test('rejects ambiguous Spine binary and JSON skeleton entries', () async {
    final version = ascii.encode('4.2.43');
    final ambiguous = _zip({
      'hero.skel': [...List<int>.filled(8, 0), version.length + 1, ...version],
      'hero.json': utf8.encode(
        jsonEncode({
          'skeleton': {'spine': '4.2.43'},
          'bones': [
            {'name': 'root'},
          ],
          'animations': <String, Object?>{},
        }),
      ),
      'hero.atlas': utf8.encode('hero.png\nsize: 1,1\n'),
      'hero.png': _png(1, 1),
    });
    await expectLater(
      inspectModelResources(ambiguous, format: ModelResourceFormat.spine),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('ambiguous'),
        ),
      ),
    );

    final matchingPlainJson = _zip({
      'hero.skel': [...List<int>.filled(8, 0), version.length + 1, ...version],
      'hero.json': utf8.encode(jsonEncode({'metadata': true})),
      'hero.atlas': utf8.encode('hero.png\nsize: 1,1\n'),
      'hero.png': _png(1, 1),
    });
    await expectLater(
      inspectModelResources(
        matchingPlainJson,
        format: ModelResourceFormat.spine,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('ambiguous'),
        ),
      ),
    );
  });

  test('uses only the gesture mapping matching the skeleton base', () async {
    final catalog = await inspectModelResources(
      _zip({
        'hero.json': utf8.encode(
          jsonEncode({
            'skeleton': {'spine': '4.2.43'},
            'bones': [
              {'name': 'root'},
            ],
            'animations': {'idle': <String, Object?>{}},
          }),
        ),
        'hero.atlas': utf8.encode('hero.png\nsize: 1,1\n'),
        'hero.png': _png(1, 1),
        'other_gesture.json': utf8.encode(
          jsonEncode({
            'emotionalGesture': {
              'MotionGroups': [
                {'GroupId': 'wrong', 'AnimName_1': 'not_in_hero'},
              ],
            },
          }),
        ),
      }),
      format: ModelResourceFormat.spine,
    );

    expect(catalog.runtimeSupported, isTrue);
    expect(catalog.existingMapping, isEmpty);
  });

  test(
    'reports malformed matching gesture and preview before mapping',
    () async {
      final catalog = await inspectModelResources(
        _zip({
          'hero.json': utf8.encode(
            jsonEncode({
              'skeleton': {'spine': '4.2.43'},
              'bones': [
                {'name': 'root'},
              ],
              'animations': {'idle': <String, Object?>{}},
            }),
          ),
          'hero.atlas': utf8.encode('hero.png\nsize: 1,1\n'),
          'hero.png': _png(1, 1),
          'hero_gesture.json': utf8.encode(jsonEncode({'unexpected': true})),
          'preview.png': Uint8List(33),
        }),
        format: ModelResourceFormat.spine,
      );

      expect(catalog.runtimeSupported, isFalse);
      expect(
        catalog.compatibilityIssues,
        containsAll([
          'The matching Spine gesture mapping is invalid.',
          'The Spine preview preview.png is not a valid PNG.',
        ]),
      );
    },
  );

  test(
    'Spine catalog reports importer structure limits before mapping',
    () async {
      final skeleton = utf8.encode(
        jsonEncode({
          'skeleton': {'spine': '4.2.43'},
          'bones': [
            {'name': 'root'},
          ],
          'animations': {'idle': <String, Object?>{}},
        }),
      );

      final missingAtlas = await inspectModelResources(
        _zip({'hero.json': skeleton, 'hero.png': _png(1, 1)}),
        format: ModelResourceFormat.spine,
      );
      expect(missingAtlas.runtimeSupported, isFalse);
      expect(
        missingAtlas.compatibilityIssues,
        contains('The Spine importer requires exactly one atlas file.'),
      );

      final mismatched = await inspectModelResources(
        _zip({
          'hero.json': skeleton,
          'other.atlas': utf8.encode(
            'hero.png\nsize: 1,1\nother.png\nsize: 1,1\n',
          ),
          'hero.png': _png(1, 1),
          'other.png': _png(1, 1),
        }),
        format: ModelResourceFormat.spine,
      );
      expect(mismatched.runtimeSupported, isFalse);
      expect(
        mismatched.compatibilityIssues,
        containsAll([
          'The atlas and skeleton must use the same base name.',
          'The Spine importer requires one atlas page named hero.png.',
        ]),
      );

      final unsafeBase = await inspectModelResources(
        _zip({
          '角色.json': skeleton,
          '角色.atlas': utf8.encode('角色.png\nsize: 1,1\n'),
          '角色.png': _png(1, 1),
        }),
        format: ModelResourceFormat.spine,
      );
      expect(unsafeBase.runtimeSupported, isFalse);
      expect(
        unsafeBase.compatibilityIssues,
        contains(
          'The Spine base name must use only ASCII letters, digits, _ or -.',
        ),
      );

      final tooMany = <String, List<int>>{
        'hero.json': skeleton,
        'hero.atlas': utf8.encode('hero.png\nsize: 1,1\n'),
        'hero.png': _png(1, 1),
        for (var index = 0; index < 62; index++)
          'docs/readme_$index.txt': utf8.encode('$index'),
      };
      final crowded = await inspectModelResources(
        _zip(tooMany),
        format: ModelResourceFormat.spine,
      );
      expect(crowded.runtimeSupported, isFalse);
      expect(
        crowded.compatibilityIssues,
        contains(
          'The Spine ZIP has more than the importer limit of 64 entries.',
        ),
      );
    },
  );

  test(
    'Live2D catalogs motions, expressions, parameters and hit areas',
    () async {
      final catalog = await inspectModelResources(
        _live2dZip(),
        format: ModelResourceFormat.live2d,
      );
      expect(catalog.runtimeSupported, isTrue);
      expect(catalog.entryFile, 'haru/haru.model3.json');
      expect(catalog.runtimeVersion, 'Cubism 3');
      expect(catalog.resourceById('motion:Idle:0')?.duration, 3.25);
      expect(catalog.resourceById('expression:Smile'), isNotNull);
      expect(catalog.resourceById('parameter:ParamMouthOpenY'), isNotNull);
      expect(
        catalog.resourceById('parameter:ParamAngleX')?.name,
        'Face angle X',
      );
      expect(catalog.resourceById('parameter:ParamEyeLOpen'), isNotNull);
      expect(catalog.resourceById('hitArea:HitAreaHead')?.name, 'Head');
      expect(
        ((catalog.existingMapping['actions'] as Map)['idle']
            as Map)['resourceId'],
        'motion:Idle:0',
      );
    },
  );

  test(
    'VRM GLB exposes humanoid and expression metadata without renderer',
    () async {
      final catalog = await inspectModelResources(
        _zip({'avatar.vrm': _vrmGlb()}),
        format: ModelResourceFormat.vrm,
      );
      expect(catalog.runtimeSupported, isFalse);
      expect(catalog.runtimeVersion, 'VRM 1.0');
      expect(catalog.resourceById('bone:hips')?.native['node'], 0);
      expect(catalog.resourceById('bone:head')?.native['node'], 1);
      expect(catalog.resourceById('expression:happy'), isNotNull);
      expect(catalog.resourceById('expression:smirk'), isNotNull);
      expect(catalog.compatibilityIssues.single, contains('no VRM renderer'));
    },
  );

  test('raw VRM GLB uses the same safe metadata parser', () async {
    final raw = _vrmGlb();
    final catalog = await inspectModelResources(
      raw,
      format: ModelResourceFormat.vrm,
    );
    expect(catalog.entryFile, 'model.vrm');
    expect(catalog.runtimeVersion, 'VRM 1.0');
    expect(catalog.resourceById('bone:hips'), isNotNull);
    expect(catalog.resourceById('expression:happy'), isNotNull);
  });

  test(
    'unsafe and duplicate ZIP paths are rejected before inspection',
    () async {
      final unsafe = _zip({'../hero.json': utf8.encode('{}')});
      await expectLater(
        inspectModelResources(unsafe, format: ModelResourceFormat.spine),
        throwsFormatException,
      );

      final archive = Archive()
        ..addFile(ArchiveFile.bytes('hero.json', utf8.encode('{}')))
        ..addFile(ArchiveFile.bytes('HERO.JSON', utf8.encode('{}')));
      final duplicate = Uint8List.fromList(ZipEncoder().encode(archive));
      await expectLater(
        inspectModelResources(duplicate, format: ModelResourceFormat.spine),
        throwsFormatException,
      );
    },
  );

  final mano = File(
    r'C:\Users\cheny\Documents\Codex\2026-10-21\https-github-com-sallyn0225-eidolon-sc\outputs\mano-1030010010.zip',
  );
  test(
    'real Mano package preserves all bindable metadata without mesh payloads',
    () async {
      final catalog = await inspectModelResources(
        mano.readAsBytesSync(),
        format: ModelResourceFormat.spine,
      );
      expect(catalog.sourceFingerprint, hasLength(64));
      expect(catalog.runtimeVersion, '3.6.53');
      expect(catalog.runtimeSupported, isTrue);
      expect(catalog.existingMapping, isEmpty);
      expect(
        catalog.resources.where(
          (resource) => resource.kind == ModelResourceKinds.animation,
        ),
        hasLength(62),
      );
      expect(
        catalog.resources.where(
          (resource) => resource.kind == ModelResourceKinds.bone,
        ),
        hasLength(72),
      );
      expect(
        catalog.resources.where(
          (resource) => resource.kind == ModelResourceKinds.slot,
        ),
        hasLength(61),
      );
      expect(
        catalog.resourceById('animation:hello')?.duration,
        closeTo(8.3667, 0.001),
      );
      expect(
        catalog.resourceById('animation:touch')?.duration,
        closeTo(10.0667, 0.001),
      );
      expect(catalog.resourceById('hitArea:default:touch:touch'), isNotNull);
      expect(jsonEncode(catalog.toPromptJson()), isNot(contains('vertices')));
    },
    skip: !mano.existsSync(),
  );

  final spine42 = File('build/test_imports/spine_seated_template_test.zip');
  test(
    'Spine 4.2 binary uses native runtime metadata reflection',
    () async {
      final catalog = await inspectModelResources(
        spine42.readAsBytesSync(),
        format: ModelResourceFormat.spine,
      );
      expect(catalog.runtimeSupported, isTrue);
      expect(catalog.runtimeVersion, startsWith('4.2.'));
      expect(catalog.entryFile, endsWith('.skel'));
      expect(
        catalog.resources.any(
          (resource) => resource.kind == ModelResourceKinds.animation,
        ),
        isTrue,
      );
      expect(
        catalog.resources.any(
          (resource) => resource.kind == ModelResourceKinds.bone,
        ),
        isTrue,
      );
      expect(
        catalog.resources.any(
          (resource) => resource.kind == ModelResourceKinds.slot,
        ),
        isTrue,
      );
      expect(
        catalog.resources.any(
          (resource) => resource.kind == ModelResourceKinds.skin,
        ),
        isTrue,
      );
    },
    skip:
        !spine42.existsSync() ||
        Platform.environment['MODEL_RESOURCE_NATIVE_TEST'] != '1',
  );
}
