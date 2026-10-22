import 'dart:math' as math;
import 'dart:ui';

import 'package:spine_flutter/spine_flutter.dart';

import 'character_face_pull.dart';

/// A transient cheek-skin layer restored before authored animation/physics.
/// Facial features and the body never receive procedural deformation.
class CharacterFacePullRig {
  final dynamics = CharacterFacePullDynamics();
  Skeleton? _skeleton;
  Bone? _head;
  Slot? _face;
  List<Slot> _faceSkinSlots = const [];
  List<Slot> _featureSlots = const [];
  List<Bone> _bones = const [];
  final _restore = <_DeformSnapshot>[];
  List<Slot> _activeSlots = const [];
  Slot? _activePrimary;
  Bone? _referenceBone;
  Rect? _bounds;
  double _radius = 0;

  bool get active => dynamics.active;
  bool get isDragging => dynamics.isDragging;
  Rect? get faceLocalBounds => _bounds;

  void bind(Skeleton skeleton) {
    if (identical(skeleton, _skeleton)) return;
    // The previous drawable may already be disposed when a new one loads.
    reset(restorePose: false);
    _skeleton = skeleton;
    _head = skeleton.findBone('head');
    final slots = skeleton.getSlots();
    _face = slots
        .where(
          (slot) =>
              RegExp(r'(?:^|_)face$').hasMatch(slot.getData().getName()) &&
              slot.getAttachment() is MeshAttachment,
        )
        .firstOrNull;
    _head ??= _face?.getBone();
    _faceSkinSlots = slots
        .where(
          (slot) => RegExp(
            r'(?:^|_)(?:face|face_cheek|face_cheek_line|face_pale|cheek)$',
          ).hasMatch(slot.getData().getName()),
        )
        .toList(growable: false);
    _featureSlots = slots
        .where(
          (slot) => RegExp(
            r'eye|mouth|nose',
            caseSensitive: false,
          ).hasMatch(slot.getData().getName()),
        )
        .toList(growable: false);
    _bones = skeleton.getBones();
  }

  /// Offline regression targets below the eye sockets, on the cheek skin.
  List<Offset> cheekTargets(Skeleton skeleton) {
    bind(skeleton);
    final geometry = _geometry(_face, _head);
    if (geometry == null) return const [];
    final bounds = geometry.bounds;
    return [
      for (final x in [.18, .82])
        geometry.space.toWorld(
          Offset(
            bounds.left + bounds.width * x,
            bounds.top + bounds.height * .26,
          ),
        ),
    ];
  }

  bool begin(Skeleton skeleton, Offset point) {
    bind(skeleton);
    restore();
    if (!point.dx.isFinite || !point.dy.isFinite) return false;
    final face = _geometry(_face, _head);
    if (face != null) {
      final local = face.space.toLocal(point);
      if (local != null) {
        final x = (local.dx - face.bounds.left) / face.bounds.width;
        final y = (local.dy - face.bounds.top) / face.bounds.height;
        final protected = _faceProtectedAreas(face.space, face.bounds);
        if (x >= .05 &&
            x <= .95 &&
            (x <= .34 || x >= .66) &&
            y >= .14 &&
            y <= .36 &&
            !protected.any((rect) => rect.contains(local)) &&
            _insideMesh(local, face.vertices, face.mesh.getTriangles())) {
          _start(
            _face!,
            _head!,
            _faceSkinSlots,
            face,
            local,
            radius: face.bounds.width * .26,
            width: face.bounds.width,
            height: face.bounds.height,
          );
          return isDragging;
        }
      }
    }
    return false;
  }

  void _start(
    Slot primary,
    Bone bone,
    List<Slot> slots,
    _SkinGeometry geometry,
    Offset local, {
    required double radius,
    required double width,
    required double height,
  }) {
    _activePrimary = primary;
    _referenceBone = bone;
    _activeSlots = slots;
    _bounds = geometry.bounds;
    _radius = radius;
    dynamics.begin(local, faceWidth: width, faceHeight: height);
  }

  void drag(Offset point) {
    if (!isDragging || _referenceBone == null) return;
    final local = _BoneSpace(_referenceBone!).toLocal(point);
    if (local != null) dynamics.drag(local);
  }

  void release() => dynamics.release();

  void restore() {
    for (final snapshot in _restore) {
      final attachment = snapshot.slot.getAttachment();
      if (attachment is VertexAttachment &&
          attachment.runtimeIdentity == snapshot.attachmentIdentity) {
        snapshot.slot.setDeform(snapshot.values);
      }
    }
    _restore.clear();
  }

  void reset({bool restorePose = true}) {
    if (restorePose) restore();
    _restore.clear();
    dynamics.reset();
    _bounds = null;
    _activeSlots = const [];
    _activePrimary = null;
    _referenceBone = null;
  }

  /// After animation/constraints/physics, immediately before painting.
  void apply(double delta) {
    if (!active || _referenceBone == null || _activePrimary == null) return;
    restore();
    final current = _activePrimary!.getAttachment();
    dynamics.advance(delta);
    if (!active || dynamics.displacement.distanceSquared < 1e-12) return;
    final space = _BoneSpace(_referenceBone!);
    if (!space.invertible) return;
    final bounds =
        _geometry(_activePrimary, _referenceBone)?.bounds ?? _bounds!;
    final protected = _faceProtectedAreas(space, bounds);
    var worldDelta = space.vectorToWorld(dynamics.displacement);
    if (current is MeshAttachment) {
      final vertices = current.computeWorldVertices(_activePrimary!);
      final shifts = <double>[];
      for (var i = 0; i + 1 < vertices.length; i += 2) {
        final local = space.toLocal(Offset(vertices[i], vertices[i + 1]));
        final weight = local == null
            ? 0.0
            : skinPullWeight(
                local,
                dynamics.anchor,
                radius: _radius,
                protectedAreas: protected,
                protectionFade: bounds.width * .05,
              );
        shifts.addAll([worldDelta.dx * weight, worldDelta.dy * weight]);
      }
      // Pinning the eye sockets can compress cheek triangles during an upward
      // pull. Limit only unsafe frames and use one scale for every skin layer.
      worldDelta *= skinPullTopologyScale(
        vertices,
        shifts,
        current.getTriangles(),
      );
    }
    final boneSpaces = <int, _BoneSpace>{};
    for (final slot in _activeSlots) {
      final mesh = slot.getAttachment();
      if (mesh is! MeshAttachment) continue;
      final vertices = mesh.computeWorldVertices(slot);
      final source = mesh.getVertices();
      final influences = mesh.getBones();
      final weighted = influences.isNotEmpty;
      final count = weighted ? source.length ~/ 3 * 2 : source.length;
      if (count == 0 || count > 10000) continue;
      final original = slot.getDeform();
      if (original.isNotEmpty && original.length != count) continue;
      final next = original.isEmpty
          ? weighted
                ? List<double>.filled(count, 0)
                : source.toList()
          : List<double>.of(original);
      var boneCursor = 0, deformCursor = 0;
      var changed = false;
      for (var i = 0; i + 1 < vertices.length; i += 2) {
        final local = space.toLocal(Offset(vertices[i], vertices[i + 1]));
        final weight = local == null
            ? 0.0
            : skinPullWeight(
                local,
                dynamics.anchor,
                radius: _radius,
                protectedAreas: protected,
                protectionFade: bounds.width * .05,
              );
        final offset = worldDelta * weight;
        if (weighted) {
          if (boneCursor >= influences.length) break;
          final number = influences[boneCursor++];
          for (var j = 0; j < number; j++) {
            if (boneCursor >= influences.length || deformCursor + 1 >= count) {
              break;
            }
            final index = influences[boneCursor++];
            if (index >= 0 && index < _bones.length && weight > 0) {
              final boneSpace = boneSpaces.putIfAbsent(
                index,
                () => _BoneSpace(_bones[index]),
              );
              final shift = boneSpace.vectorToLocal(offset);
              if (shift != null) {
                next[deformCursor] += shift.dx;
                next[deformCursor + 1] += shift.dy;
                changed = true;
              }
            }
            deformCursor += 2;
          }
        } else if (i + 1 < count && weight > 0) {
          final shift = _BoneSpace(slot.getBone()).vectorToLocal(offset);
          if (shift != null) {
            next[i] += shift.dx;
            next[i + 1] += shift.dy;
            changed = true;
          }
        }
      }
      if (changed && next.every((v) => v.isFinite)) {
        _restore.add(_DeformSnapshot(slot, mesh.runtimeIdentity, original));
        slot.setDeform(next);
      }
    }
  }

  List<Rect> _faceProtectedAreas(_BoneSpace space, Rect faceBounds) {
    final areas = <String, Rect>{};
    for (final slot in _featureSlots) {
      final vertices = _attachmentWorldVertices(slot);
      if (vertices == null) continue;
      final local = _localVertices(space, vertices);
      if (local == null) continue;
      final bounds = _vertexBounds(local);
      if (bounds == null) continue;
      final name = slot.getData().getName().toLowerCase();
      final side = bounds.center.dx < faceBounds.center.dx ? 'r' : 'l';
      final kind = name.contains('mouth')
          ? 'mouth'
          : name.contains('nose')
          ? 'nose'
          : name.contains('eyebrow')
          ? 'brow_$side'
          : 'eye_$side';
      areas[kind] = areas[kind]?.expandToInclude(bounds) ?? bounds;
    }
    // If a special expression removes an eye attachment, retain an anatomical
    // exclusion rather than exposing that skin to a drag when the eye reopens.
    for (final leftSide in [true, false]) {
      final key = leftSide ? 'eye_r' : 'eye_l';
      areas.putIfAbsent(
        key,
        () => Rect.fromLTRB(
          faceBounds.left + faceBounds.width * (leftSide ? .07 : .54),
          faceBounds.top + faceBounds.height * .31,
          faceBounds.left + faceBounds.width * (leftSide ? .46 : .93),
          faceBounds.top + faceBounds.height * .54,
        ),
      );
    }
    return areas.values
        .map((rect) => rect.inflate(faceBounds.width * .015))
        .toList(growable: false);
  }

  _SkinGeometry? _geometry(Slot? slot, Bone? bone) {
    if (slot == null || bone == null) return null;
    final mesh = slot.getAttachment();
    if (mesh is! MeshAttachment) return null;
    final space = _BoneSpace(bone);
    if (!space.invertible) return null;
    final local = _localVertices(space, mesh.computeWorldVertices(slot));
    if (local == null) return null;
    final bounds = _vertexBounds(local);
    if (local.length < 6 ||
        bounds == null ||
        bounds.width < 1 ||
        bounds.height < 1) {
      return null;
    }
    return _SkinGeometry(space, mesh, local, bounds);
  }
}

List<double>? _attachmentWorldVertices(Slot slot) {
  final attachment = slot.getAttachment();
  if (attachment is VertexAttachment) {
    return attachment.computeWorldVertices(slot);
  }
  if (attachment is RegionAttachment) {
    return attachment.computeWorldVertices(slot);
  }
  return null;
}

List<double>? _localVertices(_BoneSpace space, List<double> vertices) {
  final result = <double>[];
  for (var i = 0; i + 1 < vertices.length; i += 2) {
    final local = space.toLocal(Offset(vertices[i], vertices[i + 1]));
    if (local == null || !local.dx.isFinite || !local.dy.isFinite) return null;
    result.addAll([local.dx, local.dy]);
  }
  return result;
}

Rect? _vertexBounds(List<double> vertices) {
  if (vertices.length < 2) return null;
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (var i = 0; i + 1 < vertices.length; i += 2) {
    left = math.min(left, vertices[i]);
    right = math.max(right, vertices[i]);
    top = math.min(top, vertices[i + 1]);
    bottom = math.max(bottom, vertices[i + 1]);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

class _DeformSnapshot {
  _DeformSnapshot(this.slot, this.attachmentIdentity, this.values);
  final Slot slot;
  final int attachmentIdentity;
  final List<double> values;
}

class _SkinGeometry {
  _SkinGeometry(this.space, this.mesh, this.vertices, this.bounds);
  final _BoneSpace space;
  final MeshAttachment mesh;
  final List<double> vertices;
  final Rect bounds;
}

class _BoneSpace {
  _BoneSpace(Bone bone)
    : a = bone.getA(),
      b = bone.getB(),
      c = bone.getC(),
      d = bone.getD(),
      x = bone.getWorldX(),
      y = bone.getWorldY();
  final double a, b, c, d, x, y;
  double get determinant => a * d - b * c;
  bool get invertible =>
      [a, b, c, d, x, y].every((v) => v.isFinite) && determinant.abs() > 1e-8;
  Offset vectorToWorld(Offset p) =>
      Offset(a * p.dx + b * p.dy, c * p.dx + d * p.dy);
  Offset toWorld(Offset p) => vectorToWorld(p) + Offset(x, y);
  Offset? vectorToLocal(Offset p) => !invertible
      ? null
      : Offset(
          (d * p.dx - b * p.dy) / determinant,
          (a * p.dy - c * p.dx) / determinant,
        );
  Offset? toLocal(Offset p) => vectorToLocal(p - Offset(x, y));
}

bool _insideMesh(Offset p, List<double> vertices, List<int> triangles) {
  double cross(Offset a, Offset b, Offset c) =>
      (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  for (var i = 0; i + 2 < triangles.length; i += 3) {
    if (triangles
        .skip(i)
        .take(3)
        .any((index) => index < 0 || index * 2 + 1 >= vertices.length)) {
      continue;
    }
    Offset point(int index) =>
        Offset(vertices[index * 2], vertices[index * 2 + 1]);
    final a = point(triangles[i]),
        b = point(triangles[i + 1]),
        c = point(triangles[i + 2]);
    if (cross(a, b, c).abs() < 1e-8) continue;
    final ab = cross(a, b, p), bc = cross(b, c, p), ca = cross(c, a, p);
    if ((ab >= -1e-5 && bc >= -1e-5 && ca >= -1e-5) ||
        (ab <= 1e-5 && bc <= 1e-5 && ca <= 1e-5)) {
      return true;
    }
  }
  return false;
}
