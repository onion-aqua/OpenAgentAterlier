import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_face_pull_rig.dart';
import 'package:spine_flutter/spine_flutter.dart';

// Actual C++ rendering and geometry only; this never launches the application.
// AAR_SPINE_NATIVE_TEST=1 enables rigs; AAR_FACE_PULL_RENDER=1 saves local PNGs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';
  final render = Platform.environment['AAR_FACE_PULL_RENDER'] == '1';
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
      'actual face pull, recovery and instance isolation for $skin',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        final other = SkeletonDrawable(
          drawable.atlas,
          drawable.skeletonData,
          false,
        );
        final rig = CharacterFacePullRig();
        final frames = <ui.Image>[];
        try {
          final skeleton = drawable.skeleton;
          final head = skeleton.findBone('head')!;
          final face = skeleton.findSlot(
            id == '0001_99' ? '034_face' : '039_face',
          )!;
          final mesh = face.getAttachment()! as MeshAttachment;
          final baseline = mesh.computeWorldVertices(face);
          final source = mesh.getVertices().toList();
          final allMeshSources = {
            for (final slot in skeleton.getSlots())
              if (slot.getAttachment() case final MeshAttachment attachment)
                attachment.runtimeIdentity: attachment.getVertices().toList(),
          };
          final otherFace = other.skeleton.findSlot(face.getData().getName())!;
          final otherBaseline = mesh.computeWorldVertices(otherFace);
          rig.bind(skeleton);
          final crop = _worldBounds(baseline).inflate(60);
          if (render) frames.add(await _faceFrame(drawable, crop));
          for (final side in [0, 1]) {
            final target = rig.cheekTargets(skeleton)[side];
            expect(rig.begin(skeleton, target), isTrue);
            final bounds = rig.faceLocalBounds!;
            final anchor = rig.dynamics.anchor;
            final central = _toWorld(
              head,
              ui.Offset(bounds.center.dx, anchor.dy),
            );
            rig.reset();
            expect(rig.begin(skeleton, central), isFalse);
            expect(rig.begin(skeleton, target), isTrue);
            rig.drag(
              _toWorld(head, anchor + ui.Offset(side == 0 ? -140 : 140, 15)),
            );
            expect(rig.dynamics.displacement.dx.abs(), greaterThan(20));
            final beforePull = _captureSlots(skeleton);
            rig.apply(1 / 60);
            final changed = mesh.computeWorldVertices(face);
            var maximumShift = 0.0;
            var wideScopeVertices = 0;
            var movedVertices = 0;
            for (var i = 0; i < changed.length; i += 2) {
              final world = ui.Offset(baseline[i], baseline[i + 1]);
              final local = head.worldToLocal(world.dx, world.dy);
              final distance = (ui.Offset(local.x, local.y) - anchor).distance;
              if (distance < bounds.width * .45) wideScopeVertices++;
              final actual = ui.Offset(
                changed[i] - baseline[i],
                changed[i + 1] - baseline[i + 1],
              );
              if (actual.distance > .005) movedVertices++;
              if (distance >= bounds.width * .26) {
                expect(actual.dx, closeTo(0, .005));
                expect(actual.dy, closeTo(0, .005));
              }
              maximumShift = math.max(maximumShift, actual.distance);
            }
            expect(
              movedVertices,
              lessThanOrEqualTo(wideScopeVertices * .5),
              reason:
                  'Cheek pulling must affect at most half the face vertices '
                  'of the previous wide scope on the actual owned rigs.',
            );
            expect(maximumShift, greaterThan(15));
            _expectOnlySkinChanges(beforePull);
            expect(changed.every((value) => value.isFinite), isTrue);
            expect(mesh.getVertices(), orderedEquals(source));
            expect(otherFace.getDeform(), isEmpty);
            expect(
              mesh.computeWorldVertices(otherFace),
              orderedEquals(otherBaseline),
            );
            final changedSlots = skeleton.getSlots().where(
              (slot) => slot.getDeform().isNotEmpty,
            );
            expect(changedSlots.length, greaterThanOrEqualTo(1));
            for (final slot in changedSlots) {
              expect(_isSkinSlot(slot.getData().getName()), isTrue);
            }
            for (final slot in skeleton.getSlots()) {
              if (slot.getAttachment() case final MeshAttachment attachment) {
                expect(
                  attachment.getVertices(),
                  orderedEquals(allMeshSources[attachment.runtimeIdentity]!),
                );
              }
            }
            final firstApply = face.getDeform();
            rig.apply(1 / 60);
            expect(face.getDeform(), orderedEquals(firstApply));
            if (render && side == 0) {
              frames.add(await _faceFrame(drawable, crop));
            }
            rig.restore();
            expect(face.getDeform(), isEmpty);
            expect(mesh.computeWorldVertices(face), orderedEquals(baseline));
            rig.apply(1 / 60);
            rig.release();
            for (var frame = 0; frame < 120; frame++) {
              rig.restore();
              rig.apply(1 / 60);
            }
            expect(rig.active, isFalse);
            expect(face.getDeform(), isEmpty);
            expect(mesh.computeWorldVertices(face), orderedEquals(baseline));
          }
          if (render) {
            frames.add(await _faceFrame(drawable, crop));
            final beforePixels = await frames.first.toByteData();
            final afterPixels = await frames.last.toByteData();
            expect(
              afterPixels!.buffer.asUint8List(),
              orderedEquals(beforePixels!.buffer.asUint8List()),
              reason:
                  'Returned rendering must exactly match the starting pose.',
            );
            await _saveComparison(skin, frames);
          }

          // Authored deformation survives the transient pull and its reset.
          final authored = List.generate(
            source.length ~/ 3 * 2,
            (i) => i.isEven ? 0.3 : -0.15,
          );
          face.setDeform(authored);
          final authoredFloat = face.getDeform();
          final authoredWorld = mesh.computeWorldVertices(face);
          final target = rig.cheekTargets(skeleton).first;
          expect(rig.begin(skeleton, target), isTrue);
          rig.drag(target + const ui.Offset(-80, 0));
          rig.apply(1 / 60);
          rig.restore();
          expect(face.getDeform(), orderedEquals(authoredFloat));
          expect(mesh.computeWorldVertices(face), orderedEquals(authoredWorld));
          rig.apply(1 / 60);
          rig.reset();
          expect(face.getDeform(), orderedEquals(authoredFloat));

          // Same-name replacement must not receive an old attachment snapshot.
          expect(rig.begin(skeleton, rig.cheekTargets(skeleton).first), isTrue);
          rig.drag(target + const ui.Offset(-80, 0));
          rig.apply(1 / 60);
          final replacement = mesh.copy() as MeshAttachment;
          try {
            expect(replacement.runtimeIdentity, isNot(mesh.runtimeIdentity));
            face.setAttachment(replacement);
            final ownDeform = List<double>.filled(authored.length, 0.7);
            face.setDeform(ownDeform);
            final ownFloat = face.getDeform();
            rig.restore();
            expect(face.getDeform(), orderedEquals(ownFloat));
            rig.reset();
            face.setAttachment(mesh);
          } finally {
            replacement.dispose();
          }
          face.clearDeform();
          rig.bind(other.skeleton);
          expect(rig.active, isFalse);
          expect(otherFace.getDeform(), isEmpty);

          // Exercise the same restore -> animation/physics -> pull order as the
          // live character, rather than only changing a frozen setup pose.
          final idle = drawable.skeletonData.getAnimations().firstWhere(
            (animation) =>
                animation.getName().startsWith('motion_A_') &&
                animation.getName().endsWith('_idle'),
          );
          drawable.animationState.setAnimationByName(0, idle.getName(), true);
          other.animationState.setAnimationByName(0, idle.getName(), true);
          rig.bind(skeleton);
          final animatedTarget = rig.cheekTargets(skeleton).last;
          expect(rig.begin(skeleton, animatedTarget), isTrue);
          rig.drag(animatedTarget + const ui.Offset(100, 8));
          for (var frame = 0; frame < 180; frame++) {
            if (frame == 20) rig.release();
            rig.restore();
            drawable.update(1 / 60);
            other.update(1 / 60);
            rig.apply(1 / 60);
            final actualMesh = face.getAttachment()! as MeshAttachment;
            expect(
              actualMesh.computeWorldVertices(face).every((v) => v.isFinite),
              isTrue,
            );
          }
          expect(rig.active, isFalse);
          final actualMesh = face.getAttachment()! as MeshAttachment;
          final unmodifiedMesh = otherFace.getAttachment()! as MeshAttachment;
          final actualWorld = actualMesh.computeWorldVertices(face);
          final expectedWorld = unmodifiedMesh.computeWorldVertices(otherFace);
          for (var i = 0; i < actualWorld.length; i++) {
            expect(actualWorld[i], closeTo(expectedWorld[i], 0.005));
          }
        } finally {
          rig.reset();
          for (final frame in frames) {
            frame.dispose();
          }
          other.dispose();
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Requires AAR_SPINE_NATIVE_TEST=1, rebuilt DLL and owned rigs.'
          : false,
    );
    test(
      'eyes and mouth remain authored in every eye pose for $skin',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        final rig = CharacterFacePullRig();
        try {
          final skeleton = drawable.skeleton;
          final eyePoses = drawable.skeletonData
              .getAnimations()
              .map((animation) => animation.getName())
              .where(
                (name) =>
                    name.startsWith('facial_eye_') && name.endsWith('_idle'),
              )
              .toList(growable: false);
          expect(
            eyePoses.length,
            greaterThanOrEqualTo(id == '0001_99' ? 12 : 17),
          );
          rig.bind(skeleton);
          for (final pose in eyePoses) {
            for (final side in [0, 1]) {
              rig.reset();
              skeleton.setToSetupPose();
              drawable.animationState.clearTracks();
              drawable.animationState.setAnimationByName(0, pose, false);
              drawable.update(.5);
              final head = skeleton.findBone('head')!;
              final face = skeleton.findSlot(
                id == '0001_99' ? '034_face' : '039_face',
              )!;
              final target = rig.cheekTargets(skeleton)[side];
              expect(rig.begin(skeleton, target), isTrue, reason: pose);
              final bounds = rig.faceLocalBounds!;
              rig.drag(
                _toWorld(
                  head,
                  rig.dynamics.anchor + ui.Offset(side == 0 ? -140 : 140, 15),
                ),
              );
              for (var frame = 0; frame < 3; frame++) {
                if (frame > 0) {
                  rig.restore();
                  drawable.update(.1);
                }
                // Capture after this frame's authored animation/constraints;
                // normal blinking and gaze movement are allowed between frames.
                final before = _captureSlots(skeleton);
                final skinBaseline = _worldVertices(face);
                rig.apply(1 / 60);
                _expectOnlySkinChanges(
                  before,
                  reason: '$pose / $side / $frame',
                );
                final pulled = _worldVertices(face);
                _expectTriangleOrientation(
                  face,
                  skinBaseline,
                  pulled,
                  reason: '$pose / $side / $frame',
                );
                _expectProtectedSkinPinned(
                  before,
                  head,
                  skinBaseline,
                  pulled,
                  bounds.width,
                  reason: '$pose / $side / $frame',
                );
                expect(pulled.every((value) => value.isFinite), isTrue);
                expect(
                  _maximumShift(skinBaseline, pulled),
                  greaterThan(1),
                  reason:
                      'A protected eye pose must still allow cheek skin '
                      'movement: $pose / $side / $frame',
                );
              }
              final beforeRestore = _captureSlots(skeleton);
              rig.reset();
              _expectOnlySkinChanges(beforeRestore, reason: '$pose / reset');
            }
          }
        } finally {
          rig.reset();
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Requires AAR_SPINE_NATIVE_TEST=1, rebuilt DLL and owned rigs.'
          : false,
    );
    test(
      'large skin drags preserve triangle winding for $skin',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        final rig = CharacterFacePullRig();
        try {
          final skeleton = drawable.skeleton;
          final head = skeleton.findBone('head')!;
          final face = skeleton.findSlot(
            id == '0001_99' ? '034_face' : '039_face',
          )!;
          final baseline = _worldVertices(face);
          final local = <double>[];
          for (var i = 0; i + 1 < baseline.length; i += 2) {
            final point = head.worldToLocal(baseline[i], baseline[i + 1]);
            local.addAll([point.x, point.y]);
          }
          final bounds = _worldBounds(local);
          final targets = [
            ...rig.cheekTargets(skeleton),
            for (final x in [.12, .88])
              for (final y in [.20, .30])
                _toWorld(
                  head,
                  ui.Offset(
                    bounds.left + bounds.width * x,
                    bounds.top + bounds.height * y,
                  ),
                ),
          ];
          var acceptedPoints = 0;
          for (
            var targetIndex = 0;
            targetIndex < targets.length;
            targetIndex++
          ) {
            final target = targets[targetIndex];
            rig.reset();
            if (!rig.begin(skeleton, target)) {
              // A protected feature or an outside-of-mesh boundary point may
              // refuse capture; the two audited cheek centers always work.
              expect(targetIndex, greaterThanOrEqualTo(2));
              continue;
            }
            acceptedPoints++;
            for (final direction in const [
              ui.Offset(-1, 0),
              ui.Offset(1, 0),
              ui.Offset(0, -1),
              ui.Offset(0, 1),
              ui.Offset(-1, -1),
              ui.Offset(1, -1),
              ui.Offset(-1, 1),
              ui.Offset(1, 1),
            ]) {
              rig.reset();
              expect(rig.begin(skeleton, target), isTrue);
              rig.drag(
                _toWorld(
                  head,
                  rig.dynamics.anchor +
                      ui.Offset(direction.dx * 1400, direction.dy * 1600),
                ),
              );
              final before = _captureSlots(skeleton);
              final beforeFace = _worldVertices(face);
              rig.apply(1 / 60);
              final reason = '$skin / target $targetIndex / $direction';
              final pulled = _worldVertices(face);
              _expectOnlySkinChanges(before, reason: reason);
              _expectTriangleOrientation(
                face,
                beforeFace,
                pulled,
                reason: reason,
              );
              expect(pulled.every((value) => value.isFinite), isTrue);
              rig.reset();
              expect(_worldVertices(face), orderedEquals(baseline));
            }
          }
          expect(acceptedPoints, greaterThanOrEqualTo(4));
        } finally {
          rig.reset();
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Requires AAR_SPINE_NATIVE_TEST=1, rebuilt DLL and owned rigs.'
          : false,
    );
  }
}

bool _isSkinSlot(String name) => const {
  '039_face',
  '038_face_cheek',
  '037_face_cheek_line',
  '029_face_pale',
  '034_face',
  'a_032_cheek',
}.contains(name);

class _SlotGeometry {
  _SlotGeometry(
    this.slot,
    this.name,
    this.attachmentIdentity,
    this.deform,
    this.world,
  );
  final Slot slot;
  final String name;
  final int? attachmentIdentity;
  final List<double> deform;
  final List<double> world;
}

List<_SlotGeometry> _captureSlots(Skeleton skeleton) => [
  for (final slot in skeleton.getSlots())
    _SlotGeometry(
      slot,
      slot.getData().getName(),
      slot.getAttachment()?.runtimeIdentity,
      slot.getDeform(),
      _worldVertices(slot),
    ),
];

List<double> _worldVertices(Slot slot) {
  final attachment = slot.getAttachment();
  if (attachment is VertexAttachment) {
    return attachment.computeWorldVertices(slot);
  }
  if (attachment is RegionAttachment) {
    return attachment.computeWorldVertices(slot);
  }
  return const [];
}

void _expectOnlySkinChanges(List<_SlotGeometry> before, {String? reason}) {
  for (final saved in before) {
    if (_isSkinSlot(saved.name)) continue;
    final description = '${saved.name}: ${reason ?? 'skin-only pull'}';
    expect(
      saved.slot.getAttachment()?.runtimeIdentity,
      saved.attachmentIdentity,
      reason: description,
    );
    expect(
      saved.slot.getDeform(),
      orderedEquals(saved.deform),
      reason: description,
    );
    expect(
      _worldVertices(saved.slot),
      orderedEquals(saved.world),
      reason: description,
    );
  }
}

void _expectProtectedSkinPinned(
  List<_SlotGeometry> before,
  Bone head,
  List<double> baseline,
  List<double> pulled,
  double faceWidth, {
  String? reason,
}) {
  final eyeBounds = <ui.Rect>[];
  for (final saved in before) {
    if (!saved.name.contains('eye') ||
        saved.name.contains('eyebrow') ||
        saved.world.length < 4) {
      continue;
    }
    final localVertices = <double>[];
    for (var i = 0; i + 1 < saved.world.length; i += 2) {
      final point = head.worldToLocal(saved.world[i], saved.world[i + 1]);
      localVertices.addAll([point.x, point.y]);
    }
    eyeBounds.add(_worldBounds(localVertices).inflate(faceWidth * .015));
  }
  var protectedVertices = 0;
  for (var i = 0; i + 1 < baseline.length; i += 2) {
    final point = head.worldToLocal(baseline[i], baseline[i + 1]);
    if (eyeBounds.any((rect) => rect.contains(ui.Offset(point.x, point.y)))) {
      protectedVertices++;
      expect(pulled[i], baseline[i], reason: reason);
      expect(pulled[i + 1], baseline[i + 1], reason: reason);
    }
  }
  expect(protectedVertices, greaterThan(0), reason: reason);
}

double _maximumShift(List<double> before, List<double> after) {
  var shift = 0.0;
  for (var i = 0; i + 1 < before.length; i += 2) {
    shift = math.max(
      shift,
      ui.Offset(after[i] - before[i], after[i + 1] - before[i + 1]).distance,
    );
  }
  return shift;
}

void _expectTriangleOrientation(
  Slot face,
  List<double> baseline,
  List<double> pulled, {
  String? reason,
}) {
  final mesh = face.getAttachment()! as MeshAttachment;
  final triangles = mesh.getTriangles();
  double area(List<double> vertices, int a, int b, int c) =>
      (vertices[b * 2] - vertices[a * 2]) *
          (vertices[c * 2 + 1] - vertices[a * 2 + 1]) -
      (vertices[b * 2 + 1] - vertices[a * 2 + 1]) *
          (vertices[c * 2] - vertices[a * 2]);
  var checked = 0;
  for (var i = 0; i + 2 < triangles.length; i += 3) {
    final a = triangles[i], b = triangles[i + 1], c = triangles[i + 2];
    final original = area(baseline, a, b, c);
    if (original.abs() <= .01) continue;
    checked++;
    expect(
      area(pulled, a, b, c) / original,
      greaterThanOrEqualTo(.11),
      reason: '$reason / triangle ${i ~/ 3}',
    );
  }
  expect(checked, greaterThan(0), reason: reason);
}

ui.Offset _toWorld(Bone bone, ui.Offset point) {
  final value = bone.localToWorld(point.dx, point.dy);
  return ui.Offset(value.x, value.y);
}

ui.Rect _worldBounds(List<double> vertices) {
  final xs = [for (var i = 0; i < vertices.length; i += 2) vertices[i]];
  final ys = [for (var i = 1; i < vertices.length; i += 2) vertices[i]];
  return ui.Rect.fromLTRB(
    xs.reduce(math.min),
    ys.reduce(math.min),
    xs.reduce(math.max),
    ys.reduce(math.max),
  );
}

Future<ui.Image> _faceFrame(SkeletonDrawable drawable, ui.Rect crop) async {
  const width = 600;
  const height = 660;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff343a43), ui.BlendMode.src);
  final scale = math.min(width / crop.width, height / crop.height);
  canvas.translate(width / 2, height / 2);
  canvas.scale(scale);
  canvas.translate(-crop.center.dx, -crop.center.dy);
  drawable.renderToCanvas(canvas);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<void> _saveComparison(String skin, List<ui.Image> frames) async {
  final directory = Directory('build/face_pull_visual')
    ..createSync(recursive: true);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff343a43), ui.BlendMode.src);
  for (var i = 0; i < frames.length; i++) {
    canvas.drawImage(frames[i], ui.Offset(i * 600.0, 0), ui.Paint());
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(1800, 660);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${directory.path}/$skin.png').writeAsBytes(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}
