import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_touch_physics_rig.dart';
import 'package:spine_flutter/spine_flutter.dart';

// Uses the owned rigs and actual C++ physics without launching an app/device.
// AAR_SPINE_NATIVE_TEST=1 enables it; AAR_TOUCH_PHYSICS_RENDER=1 saves PNGs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';
  final render = Platform.environment['AAR_TOUCH_PHYSICS_RENDER'] == '1';
  setUpAll(() async {
    final fontFile = File('C:/Windows/Fonts/arial.ttf');
    if (enabled && render && fontFile.existsSync()) {
      final loader = FontLoader('TouchPhysicsAudit')
        ..addFont(fontFile.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final id in [
    '0001_01',
    '0001_99',
    '0002_01',
    '0003_01',
    '0004_01',
    '0005_01',
    '0006_01',
  ]) {
    final skin = 'crf_skn_002_$id';
    final root = 'assets/character/ryza/$skin/$skin';
    test(
      'native touch physics follows speed and settles for $skin',
      () async {
        await initSpineFlutter();
        final control = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        final slow = SkeletonDrawable(
          control.atlas,
          control.skeletonData,
          false,
        );
        final fast = SkeletonDrawable(
          control.atlas,
          control.skeletonData,
          false,
        );
        final slowRig = CharacterTouchPhysicsRig();
        final fastRig = CharacterTouchPhysicsRig();
        final frames = <ui.Image>[];
        try {
          for (final drawable in [control, slow, fast]) {
            expect(
              drawable.skeletonData.findAnimation('motion_A_001_idle'),
              isNotNull,
            );
            drawable.animationState.setAnimationByName(
              0,
              'motion_A_001_idle',
              true,
            );
            for (var frame = 0; frame < 30; frame++) {
              drawable.update(1 / 60);
            }
          }
          await slowRig.prepare(slow);
          await fastRig.prepare(fast);
          final setupSources = _sourceMeshes(control.skeleton);
          final physics = control.skeleton.getPhysicsConstraints();
          expect(physics.where((c) => c.isActive()), isNotEmpty);
          final bounds = control.skeleton.getBounds();
          final crop = ui.Rect.fromLTWH(
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
          ).inflate(35);
          final contact = _visiblePhysicsPoint(slow, slowRig);
          final point = contact.current(slow.skeleton);
          expect(
            slowRig.begin(
              slow.skeleton,
              crop.bottomRight + const ui.Offset(500, 500),
            ),
            isFalse,
          );
          expect(slowRig.begin(slow.skeleton, point), isTrue);
          expect(fastRig.begin(fast.skeleton, point), isTrue);
          var slowPeak = 0.0;
          var fastPeak = 0.0;
          var fastWorldPeak = 0.0;
          for (var frame = 0; frame < 45; frame++) {
            slowRig.move(
              contact.current(slow.skeleton),
              const ui.Offset(.12, 0),
            );
            fastRig.move(contact.current(fast.skeleton), const ui.Offset(2, 0));
            control.update(1 / 60);
            _step(slow, slowRig);
            _step(fast, fastRig);
            _expectRootAndTrack(control, slow);
            _expectRootAndTrack(control, fast);
            slowPeak = math.max(
              slowPeak,
              _physicsDifference(control.skeleton, slow.skeleton),
            );
            fastPeak = math.max(
              fastPeak,
              _physicsDifference(control.skeleton, fast.skeleton),
            );
            final worldDifference = _worldDifference(
              control.skeleton,
              fast.skeleton,
            );
            if (worldDifference > fastWorldPeak) {
              fastWorldPeak = worldDifference;
              if (render) {
                for (final frame in frames) {
                  frame.dispose();
                }
                frames.clear();
                frames.add(await _render(control, crop, 'No touch'));
                frames.add(await _render(slow, crop, 'Slow'));
                frames.add(await _render(fast, crop, 'Fast'));
              }
            }
          }
          expect(slowPeak, greaterThan(.05));
          expect(fastPeak, greaterThan(slowPeak * 2));
          expect(fastWorldPeak, greaterThan(1));
          _expectSources(slow.skeleton, setupSources);
          _expectSources(fast.skeleton, setupSources);
          slowRig.release();
          fastRig.release();
          expect(slowRig.isTouching, isFalse);
          expect(fastRig.isTouching, isFalse);
          final beforeRelease = _physicsDifference(
            control.skeleton,
            fast.skeleton,
          );
          // Releasing stops the driving input, preserving the current spring.
          expect(beforeRelease, greaterThan(.05));
          var settled = 0.0;
          for (var frame = 0; frame < 240; frame++) {
            control.update(1 / 60);
            _step(slow, slowRig);
            _step(fast, fastRig);
            settled = _physicsDifference(control.skeleton, fast.skeleton);
          }
          expect(fastRig.active, isFalse);
          expect(settled, lessThan(fastPeak * .1 + .025));
          if (render) frames.add(await _render(fast, crop, 'Settled'));

          fastRig.reset();
          expect(fastRig.active, isFalse);
          expect(fastRig.isTouching, isFalse);

          // Rebinding must drop the old gesture and not stimulate another rig.
          final controlBefore = _physicsValues(control.skeleton);
          await fastRig.prepare(control);
          expect(
            fastRig.begin(control.skeleton, contact.current(control.skeleton)),
            isTrue,
          );
          fastRig.apply(0);
          expect(
            _physicsValues(control.skeleton),
            orderedEquals(controlBefore),
          );
          fastRig.reset(resetNative: false);
          fastRig.move(point, const ui.Offset(2, 0));
          fastRig.apply(1 / 60);
          expect(
            _physicsValues(control.skeleton),
            orderedEquals(controlBefore),
          );
          expect(fastRig.active, isFalse);

          if (render) {
            await _saveComparison(skin, frames, {
              'constraints': physics.length,
              'slowPeak': slowPeak,
              'fastPeak': fastPeak,
              'fastWorldPeak': fastWorldPeak,
              'settledDifference': settled,
            });
          }
        } finally {
          slowRig.reset(resetNative: false);
          fastRig.reset(resetNative: false);
          for (final frame in frames) {
            frame.dispose();
          }
          slow.dispose();
          fast.dispose();
          control.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Requires AAR_SPINE_NATIVE_TEST=1, native DLL and owned models.'
          : false,
    );
  }
  _localPhysicsTests(enabled);
}

void _step(SkeletonDrawable drawable, CharacterTouchPhysicsRig rig) {
  drawable.update(
    1 / 60,
    afterApply: () {
      final pose = _localPose(drawable.skeleton);
      final deform = [
        for (final slot in drawable.skeleton.getSlots()) slot.getDeform(),
      ];
      final track = drawable.animationState.getCurrent(0)!;
      final trackTime = track.getTrackTime();
      rig.apply(1 / 60);
      expect(_localPose(drawable.skeleton), orderedEquals(pose));
      expect([
        for (final slot in drawable.skeleton.getSlots()) slot.getDeform(),
      ], equals(deform));
      expect(track.getTrackTime(), trackTime);
      expect(track.getAnimation().getName(), 'motion_A_001_idle');
    },
  );
}

List<double> _localPose(Skeleton skeleton) => [
  for (final bone in skeleton.getBones()) ...[
    bone.getX(),
    bone.getY(),
    bone.getRotation(),
    bone.getScaleX(),
    bone.getScaleY(),
    bone.getShearX(),
    bone.getShearY(),
  ],
];

List<double> _physicsValues(Skeleton skeleton) => [
  for (final constraint in skeleton.getPhysicsConstraints()) ...[
    constraint.getXOffset(),
    constraint.getYOffset(),
    constraint.getRotateOffset(),
  ],
];

double _physicsDifference(Skeleton a, Skeleton b) {
  final av = _physicsValues(a), bv = _physicsValues(b);
  var maximum = 0.0;
  for (var i = 0; i < av.length; i++) {
    // Convert rotations to an approximate visible 100-unit lever displacement.
    maximum = math.max(maximum, (av[i] - bv[i]).abs() * (i % 3 == 2 ? 100 : 1));
  }
  return maximum;
}

void _expectRootAndTrack(SkeletonDrawable control, SkeletonDrawable tested) {
  final root = control.skeleton.getBones().first;
  final other = tested.skeleton.getBones().first;
  expect(other.getX(), root.getX());
  expect(other.getY(), root.getY());
  expect(other.getRotation(), root.getRotation());
  expect(other.getWorldX(), root.getWorldX());
  expect(other.getWorldY(), root.getWorldY());
  final track = tested.animationState.getCurrent(0)!;
  expect(
    track.getTrackTime(),
    control.animationState.getCurrent(0)!.getTrackTime(),
  );
  expect(track.getAnimation().getName(), 'motion_A_001_idle');
}

class _MeshContact {
  final String slot;
  final List<int> triangle;
  final List<double> weights;
  _MeshContact(this.slot, this.triangle, this.weights);

  ui.Offset current(Skeleton skeleton) {
    final target = skeleton.findSlot(slot)!;
    final mesh = target.getAttachment()! as MeshAttachment;
    final world = mesh.computeWorldVertices(target);
    return ui.Offset(
      List.generate(
        3,
        (i) => world[triangle[i] * 2] * weights[i],
      ).reduce((a, b) => a + b),
      List.generate(
        3,
        (i) => world[triangle[i] * 2 + 1] * weights[i],
      ).reduce((a, b) => a + b),
    );
  }
}

_MeshContact _visiblePhysicsPoint(
  SkeletonDrawable drawable,
  CharacterTouchPhysicsRig rig,
) {
  final physical = {
    for (final constraint in drawable.skeleton.getPhysicsConstraints())
      constraint.getBone().getData().getIndex(),
  };
  final bones = drawable.skeleton.getBones();
  bool physicalBone(int index) {
    Bone? bone = bones[index];
    while (bone != null) {
      if (physical.contains(bone.getData().getIndex())) return true;
      bone = bone.getParent();
    }
    return false;
  }

  for (final slot in drawable.skeleton.getDrawOrder().reversed) {
    if (!slot.getBone().isActive() || slot.getColor().a <= .01) continue;
    final mesh = slot.getAttachment();
    if (mesh is! MeshAttachment || mesh.getColor().a <= .01) continue;
    final weighted = mesh.getBones();
    var hasPhysics = false;
    if (weighted.isEmpty) {
      hasPhysics = physicalBone(slot.getBone().getData().getIndex());
    } else {
      for (var i = 0; i < weighted.length;) {
        final count = weighted[i++];
        for (var j = 0; j < count; j++) {
          hasPhysics = physicalBone(weighted[i++]) || hasPhysics;
        }
      }
    }
    if (!hasPhysics) continue;
    final triangles = mesh.getTriangles();
    for (var i = 0; i + 2 < triangles.length; i += 3) {
      for (final weights in const [
        [1 / 3, 1 / 3, 1 / 3],
        [.7, .15, .15],
        [.15, .7, .15],
        [.15, .15, .7],
      ]) {
        final contact = _MeshContact(
          slot.getData().getName(),
          triangles.sublist(i, i + 3),
          weights,
        );
        if (rig.begin(drawable.skeleton, contact.current(drawable.skeleton))) {
          rig.reset();
          return contact;
        }
      }
    }
  }
  fail('No opaque visible authored physics mesh was touchable.');
}

// Two independent authored springs exercise routing without depending on a
// costume's incidental overlap. Textures and alpha still come from the real
// owned atlas. The mesh slots deliberately belong to root, while every vertex
// is weighted to a non-physics child of its own physical bone.
class _LocalFixture {
  final SkeletonDrawable drawable;
  final rig = CharacterTouchPhysicsRig();
  _LocalFixture(this.drawable);

  static Future<_LocalFixture> create({
    bool withClip = false,
    bool prepare = true,
  }) async {
    const root =
        'assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01';
    final atlas = await Atlas.fromFile('$root.atlas');
    Map<String, Object> quad(int bone, double x) => {
      'type': 'mesh',
      'path': 'face_01',
      'uvs': [.5, .5, .5, .5, .5, .5, .5, .5],
      'triangles': [0, 1, 2, 2, 3, 0],
      'vertices': [
        for (final point in const [
          [-45.0, -45.0],
          [-45.0, 45.0],
          [45.0, 45.0],
          [45.0, -45.0],
        ]) ...[1, bone, point[0] + x, point[1], 1],
      ],
      'hull': 4,
    };
    final data = SkeletonData.fromJson(
      atlas,
      jsonEncode({
        'skeleton': {'spine': '4.2.40'},
        'bones': [
          {'name': 'root'},
          {'name': 'left', 'parent': 'root', 'x': -120, 'length': 40},
          {'name': 'left_tip', 'parent': 'left'},
          {'name': 'right', 'parent': 'root', 'x': 120, 'length': 40},
          {'name': 'right_tip', 'parent': 'right'},
        ],
        'slots': [
          if (withClip) {'name': 'clip', 'bone': 'root', 'attachment': 'clip'},
          {'name': 'fixture_face', 'bone': 'root', 'attachment': 'left'},
          {'name': 'right', 'bone': 'root', 'attachment': 'right'},
          {'name': 'cover', 'bone': 'root', 'attachment': 'cover'},
        ],
        'physics': [
          for (final bone in ['left', 'right'])
            {
              'name': '${bone}_physics',
              'order': bone == 'left' ? 0 : 1,
              'bone': bone,
              'x': 1,
              'y': 1,
              'strength': 100,
              'damping': .4,
              'mix': 1,
            },
        ],
        'skins': [
          {
            'name': 'default',
            'attachments': {
              if (withClip)
                'clip': {
                  'clip': {
                    'type': 'clipping',
                    'end': 'fixture_face',
                    'vertexCount': 4,
                    'vertices': [-165, -45, -165, 45, -120, 45, -120, -45],
                  },
                },
              'fixture_face': {'left': quad(2, 0)},
              'right': {'right': quad(4, 0)},
              'cover': {
                'cover': quad(0, -120),
                'transparent': {...quad(0, -120), 'path': '005_hair_acc'},
              },
            },
          },
        ],
        'animations': {
          'idle': {},
          'cover_behind': {
            'drawOrder': [
              {
                'time': 0,
                'offsets': [
                  {'slot': 'cover', 'offset': -2},
                ],
              },
            ],
          },
        },
      }),
    );
    final fixture = _LocalFixture(SkeletonDrawable(atlas, data, true));
    fixture.drawable.skeleton.findSlot('cover')!.setColor(Color(1, 1, 1, 0));
    for (var i = 0; i < 30; i++) {
      fixture.drawable.update(1 / 60);
    }
    if (prepare) await fixture.rig.prepare(fixture.drawable);
    return fixture;
  }

  ui.Offset point(String bone) {
    final b = drawable.skeleton.findBone(bone)!;
    return ui.Offset(b.getWorldX(), b.getWorldY());
  }

  PhysicsConstraint constraint(String bone) => drawable.skeleton
      .getPhysicsConstraints()
      .firstWhere((c) => c.getBone().getData().getName() == bone);

  void step() => drawable.update(1 / 60, afterApply: () => rig.apply(1 / 60));

  void dispose() {
    rig.reset(resetNative: false);
    drawable.dispose();
  }
}

void _localPhysicsTests(bool enabled) {
  const asset =
      'assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01.atlas';
  final skip = !enabled || !File(asset).existsSync()
      ? 'Requires AAR_SPINE_NATIVE_TEST=1, native DLL and owned atlas.'
      : false;

  test('touch remains disabled until alpha is ready and reuses it', () async {
    final fixture = await _LocalFixture.create(prepare: false);
    try {
      final point = fixture.point('left');
      expect(fixture.rig.begin(fixture.drawable.skeleton, point), isFalse);
      final preparing = fixture.rig.prepare(fixture.drawable);
      expect(fixture.rig.begin(fixture.drawable.skeleton, point), isFalse);
      await preparing;
      expect(fixture.rig.begin(fixture.drawable.skeleton, point), isTrue);
      fixture.rig.reset();
      expect(fixture.rig.begin(fixture.drawable.skeleton, point), isTrue);
    } finally {
      fixture.dispose();
    }
  }, skip: skip);

  test('weighted touch excites only its nearest physical ancestor', () async {
    final fixture = await _LocalFixture.create();
    try {
      expect(
        fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
        isTrue,
      );
      for (var i = 0; i < 20; i++) {
        fixture.rig.move(fixture.point('left'), const ui.Offset(2, 0));
        fixture.step();
        final other = fixture.constraint('right');
        expect(other.getXOffset(), 0);
        expect(other.getYOffset(), 0);
        expect(other.getRotateOffset(), 0);
      }
      expect(fixture.constraint('left').getXOffset().abs(), greaterThan(.1));
      final root = fixture.drawable.skeleton.findBone('root')!;
      expect([root.getWorldX(), root.getWorldY()], [0, 0]);
      fixture.rig.reset();
      final selected = fixture.constraint('left');
      expect(selected.getXOffset(), 0);
      expect(selected.getYOffset(), 0);
      expect(selected.getRotateOffset(), 0);
    } finally {
      fixture.dispose();
    }
  }, skip: skip);

  test(
    'one finger can enter a physical part after starting elsewhere',
    () async {
      for (final startOnCover in [false, true]) {
        final fixture = await _LocalFixture.create();
        try {
          final cover = fixture.drawable.skeleton.findSlot('cover')!;
          if (startOnCover) cover.setColor(Color(1, 1, 1, 1));
          final start = startOnCover ? fixture.point('left') : ui.Offset.zero;
          expect(fixture.rig.begin(fixture.drawable.skeleton, start), isFalse);
          expect(fixture.rig.isTouching, isTrue);
          expect(fixture.rig.active, isFalse);
          fixture.rig.move(start, const ui.Offset(3, 0));
          fixture.step();
          expect(_physicsValues(fixture.drawable.skeleton), everyElement(0));
          cover.setColor(Color(1, 1, 1, 0));
          fixture.rig.move(fixture.point('left'), const ui.Offset(2, 0));
          fixture.step();
          expect(fixture.constraint('left').getXOffset().abs(), greaterThan(0));
          expect(fixture.constraint('right').getXOffset(), 0);
          expect(fixture.constraint('right').getYOffset(), 0);
          expect(fixture.constraint('right').getRotateOffset(), 0);
        } finally {
          fixture.dispose();
        }
      }
    },
    skip: skip,
  );

  test('opaque non-physics foreground blocks springs behind it', () async {
    final fixture = await _LocalFixture.create();
    try {
      final cover = fixture.drawable.skeleton.findSlot('cover')!;
      cover.setColor(Color(1, 1, 1, 1));
      expect(
        fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
        isFalse,
      );
      fixture.rig.move(fixture.point('left'), const ui.Offset(5, 0));
      fixture.step();
      expect(_physicsValues(fixture.drawable.skeleton), everyElement(0));
      cover.setColor(Color(1, 1, 1, 0));
      expect(
        fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
        isTrue,
      );
    } finally {
      fixture.dispose();
    }
  }, skip: skip);

  test('touch occlusion follows animated draw order', () async {
    final fixture = await _LocalFixture.create();
    try {
      fixture.drawable.skeleton.findSlot('cover')!.setColor(Color(1, 1, 1, 1));
      expect(
        fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
        isFalse,
      );
      fixture.drawable.animationState.setAnimationByName(
        0,
        'cover_behind',
        false,
      );
      fixture.drawable.update(1 / 60);
      expect(
        fixture.drawable.skeleton.getDrawOrder().first.getData().getName(),
        'cover',
      );
      expect(
        fixture.drawable.skeleton.getSlots().last.getData().getName(),
        'cover',
      );
      expect(
        fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
        isTrue,
      );
    } finally {
      fixture.dispose();
    }
  }, skip: skip);

  test('transparent atlas pixels do not block a physical surface', () async {
    final fixture = await _LocalFixture.create();
    try {
      final cover = fixture.drawable.skeleton.findSlot('cover')!;
      final opaque = cover.getAttachment()!;
      fixture.drawable.skeleton.setAttachment('cover', 'transparent');
      cover.setColor(Color(1, 1, 1, 1));
      final mesh = cover.getAttachment()! as MeshAttachment;
      final image = fixture
          .drawable
          .atlas
          .atlasPages[mesh.getRegion()!.getTexture().address];
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(rgba, isNotNull);
      final sourceUvs = mesh.getRegionUVs();
      var foundTransparent = false;
      for (var u = .02; u < 1 && !foundTransparent; u += .04) {
        for (var v = .02; v < 1 && !foundTransparent; v += .04) {
          for (var i = 0; i < sourceUvs.length; i += 2) {
            sourceUvs[i] = u;
            sourceUvs[i + 1] = v;
          }
          mesh.updateRegion();
          final atlasUvs = mesh.getUVs();
          final x = (atlasUvs[0] * image.width).floor();
          final y = (atlasUvs[1] * image.height).floor();
          var clear = true;
          // Require a clear source area wider than a downsampled mask texel.
          for (var dy = -6; dy <= 6 && clear; dy++) {
            for (var dx = -6; dx <= 6; dx++) {
              final px = x + dx, py = y + dy;
              if (px < 0 ||
                  py < 0 ||
                  px >= image.width ||
                  py >= image.height ||
                  rgba!.getUint8((py * image.width + px) * 4 + 3) != 0) {
                clear = false;
                break;
              }
            }
          }
          foundTransparent = clear;
        }
      }
      expect(
        foundTransparent,
        isTrue,
        reason: 'Owned atlas has clear padding.',
      );
      expect(cover.getColor().a, 1);
      expect(
        fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
        isTrue,
      );
      fixture.rig.reset();
      cover.setAttachment(opaque);
      expect(
        fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
        isFalse,
      );
    } finally {
      fixture.dispose();
    }
  }, skip: skip);

  test(
    'Spine clipping rejects cut parts and ends at its designated slot',
    () async {
      final fixture = await _LocalFixture.create(withClip: true);
      try {
        expect(
          fixture.rig.begin(
            fixture.drawable.skeleton,
            const ui.Offset(-140, 0),
          ),
          isTrue,
        );
        fixture.rig.reset();
        expect(
          fixture.rig.begin(
            fixture.drawable.skeleton,
            const ui.Offset(-100, 0),
          ),
          isFalse,
        );
        expect(
          fixture.rig.begin(fixture.drawable.skeleton, fixture.point('right')),
          isTrue,
        );
      } finally {
        fixture.dispose();
      }
    },
    skip: skip,
  );

  test('sliding outside discards force without erasing natural inertia', () async {
    final fastOutside = await _LocalFixture.create();
    final stationaryOutside = await _LocalFixture.create();
    try {
      for (final fixture in [fastOutside, stationaryOutside]) {
        expect(
          fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
          isTrue,
        );
        for (var i = 0; i < 12; i++) {
          fixture.rig.move(fixture.point('left'), const ui.Offset(2, 0));
          fixture.step();
        }
      }
      expect(
        fastOutside.constraint('left').getXOffset().abs(),
        greaterThan(.1),
      );
      fastOutside.rig.move(const ui.Offset(2000, 2000), const ui.Offset(8, 0));
      stationaryOutside.rig.move(const ui.Offset(2000, 2000), ui.Offset.zero);
      expect(fastOutside.rig.isTouching, isTrue);
      for (var i = 0; i < 6; i++) {
        fastOutside.step();
        stationaryOutside.step();
        expect(
          _physicsValues(fastOutside.drawable.skeleton),
          orderedEquals(_physicsValues(stationaryOutside.drawable.skeleton)),
        );
        if (i == 0) {
          expect(
            fastOutside.constraint('left').getXOffset().abs(),
            greaterThan(.05),
          );
        }
      }
      // A continuous finger can re-enter a physical part after crossing blank.
      fastOutside.rig.move(fastOutside.point('right'), const ui.Offset(2, 0));
      fastOutside.step();
      expect(
        fastOutside.constraint('right').getXOffset().abs(),
        greaterThan(0),
      );
    } finally {
      fastOutside.dispose();
      stationaryOutside.dispose();
    }
  }, skip: skip);

  test('crossing into another part does not carry old velocity', () async {
    final fixture = await _LocalFixture.create();
    try {
      expect(
        fixture.rig.begin(fixture.drawable.skeleton, fixture.point('left')),
        isTrue,
      );
      for (var i = 0; i < 12; i++) {
        fixture.rig.move(fixture.point('left'), const ui.Offset(4, 0));
        fixture.step();
      }
      fixture.rig.move(fixture.point('right'), ui.Offset.zero);
      for (var i = 0; i < 4; i++) {
        fixture.step();
        expect(fixture.constraint('right').getXOffset(), 0);
        expect(fixture.constraint('right').getYOffset(), 0);
      }
      fixture.rig.move(fixture.point('right'), const ui.Offset(2, 0));
      fixture.step();
      expect(fixture.constraint('right').getXOffset().abs(), greaterThan(0));
    } finally {
      fixture.dispose();
    }
  }, skip: skip);
}

Map<int, List<double>> _sourceMeshes(Skeleton skeleton) => {
  for (final slot in skeleton.getSlots())
    if (slot.getAttachment() case final MeshAttachment mesh)
      mesh.runtimeIdentity: mesh.getVertices().toList(),
};

void _expectSources(Skeleton skeleton, Map<int, List<double>> sources) {
  for (final slot in skeleton.getSlots()) {
    if (slot.getAttachment() case final MeshAttachment mesh) {
      if (sources[mesh.runtimeIdentity] case final List<double> source) {
        expect(mesh.getVertices(), orderedEquals(source));
      }
    }
  }
}

double _worldDifference(Skeleton a, Skeleton b) {
  var maximum = 0.0;
  final aa = a.getSlots(), bb = b.getSlots();
  for (var i = 0; i < aa.length; i++) {
    if (!aa[i].getBone().isActive() || aa[i].getColor().a <= .01) {
      continue;
    }
    final av = aa[i].getAttachment(), bv = bb[i].getAttachment();
    if (av is! MeshAttachment || bv is! MeshAttachment) continue;
    if (av.getColor().a <= .01) continue;
    final ap = av.computeWorldVertices(aa[i]);
    final bp = bv.computeWorldVertices(bb[i]);
    for (var j = 0; j + 1 < ap.length; j += 2) {
      maximum = math.max(
        maximum,
        ui.Offset(ap[j] - bp[j], ap[j + 1] - bp[j + 1]).distance,
      );
    }
  }
  return maximum;
}

Future<ui.Image> _render(
  SkeletonDrawable drawable,
  ui.Rect crop,
  String label,
) async {
  const width = 480, height = 800;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff343a43), ui.BlendMode.src);
  final paragraph =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontFamily: 'TouchPhysicsAudit',
            fontSize: 23,
            textAlign: ui.TextAlign.center,
          ),
        )
        ..pushStyle(ui.TextStyle(color: const ui.Color(0xffffffff)))
        ..addText(label);
  final text = paragraph.build()
    ..layout(const ui.ParagraphConstraints(width: 480));
  canvas.drawParagraph(text, const ui.Offset(0, 8));
  final scale = math.min(width / crop.width, (height - 50) / crop.height);
  canvas.translate(width / 2, 45 + (height - 45) / 2);
  canvas.scale(scale);
  canvas.translate(-crop.center.dx, -crop.center.dy);
  drawable.renderToCanvas(canvas);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    text.dispose();
    picture.dispose();
  }
}

Future<void> _saveComparison(
  String skin,
  List<ui.Image> frames,
  Map<String, num> metrics,
) async {
  final directory = Directory('build/touch_physics_visual')
    ..createSync(recursive: true);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var i = 0; i < frames.length; i++) {
    canvas.drawImage(frames[i], ui.Offset(i * 480.0, 0), ui.Paint());
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(frames.length * 480, 800);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${directory.path}/$skin.png').writeAsBytes(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    await File('${directory.path}/$skin.json')
        .writeAsString(jsonEncode(metrics));
  } finally {
    image.dispose();
    picture.dispose();
  }
}
