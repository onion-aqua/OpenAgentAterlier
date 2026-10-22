#!/usr/bin/env python3
"""Add cheek deform and native physics access to the local Spine runtime.

Usage: python tool/apply_spine_face_deform_patch.py [--check]
       python tool/apply_spine_face_deform_patch.py --runtime PATH

Android and Windows compile src/spine-cpp-lite. This script contains only the
small integration changes; it never copies character assets or the complete
third-party runtime. It preserves unrelated local changes, is idempotent, and
preflights every hunk before writing. Rebuild native libraries after applying.
"""

from argparse import ArgumentParser
from pathlib import Path
import sys

# Exact context prevents silently patching an incompatible runtime revision.
PATCHES = [
    (
        'lib/spine_flutter.dart',
        r"""  Attachment._(this._attachment);

  /// The attachment's name.
""",
        r"""  Attachment._(this._attachment);

  /// Identity of the native attachment during its lifetime. This distinguishes
  /// replacements that share a name without storing or mutating their data.
  /// It is only for transient runtime comparisons, never persistence or logs.
  int get runtimeIdentity => _attachment.address;

  /// The attachment's name.
""",
    ),
    (
        'lib/spine_flutter.dart',
        r"""
  void setAttachment(Attachment? attachment) {
    _bindings.spine_slot_set_attachment(_slot, attachment != null ? attachment._attachment.cast() : nullptr);
  }

  @override
""",
        r"""
  void setAttachment(Attachment? attachment) {
    _bindings.spine_slot_set_attachment(_slot, attachment != null ? attachment._attachment.cast() : nullptr);
  }

  /// A snapshot of this slot's current vertex deformation. Mutating the returned
  /// list does not change the slot. Empty means the setup vertices are used.
  /// Values are absolute local x/y positions for an unweighted attachment, and
  /// local x/y offsets for every bone influence of a weighted attachment.
  List<double> getDeform() {
    final length = _bindings.spine_slot_get_num_deform(_slot);
    if (length == 0) return <double>[];
    return _bindings.spine_slot_get_deform(_slot).asTypedList(length).toList();
  }

  /// Copies [values] into this slot's deformation without modifying the shared
  /// attachment. The length must match all local coordinates (unweighted) or
  /// two offsets per bone influence (weighted). Empty input clears it.
  /// Apply procedural changes after AnimationState.apply so timelines can keep
  /// providing the animation's base deformation on every frame.
  void setDeform(List<double> values) {
    if (values.isEmpty) {
      clearDeform();
      return;
    }
    final attachment = getAttachment();
    if (attachment is! VertexAttachment) {
      throw ArgumentError('The current slot attachment has no deformable vertices.');
    }
    final expected = attachment.getBones().isEmpty
        ? attachment.getVertices().length
        : attachment.getVertices().length ~/ 3 * 2;
    if (values.length != expected || values.any((value) => !value.isFinite)) {
      throw ArgumentError('Expected $expected finite deformation values, got ${values.length}.');
    }
    final nativeValues = _allocator.allocate(4 * values.length).cast<Float>();
    try {
      nativeValues.asTypedList(values.length).setAll(0, values);
      if (_bindings.spine_slot_set_deform(_slot, nativeValues, values.length) != -1) {
        throw ArgumentError('Invalid vertex deformation for the current attachment.');
      }
    } finally {
      _allocator.free(nativeValues);
    }
  }

  /// Restores use of the setup vertices. This does not change the attachment or
  /// disable deformation timelines in the character's animations.
  void clearDeform() {
    _bindings.spine_slot_clear_deform(_slot);
  }

  @override
""",
    ),
    (
        'lib/spine_flutter_bindings_generated.dart',
        r"""  late final _spine_slot_set_attachment = _spine_slot_set_attachmentPtr
      .asFunction<void Function(spine_slot, spine_attachment)>();

  /// OMITTED getDeform()
  int spine_slot_get_sequence_index(
    spine_slot slot,
  ) {
""",
        r"""  late final _spine_slot_set_attachment = _spine_slot_set_attachmentPtr
      .asFunction<void Function(spine_slot, spine_attachment)>();

  int spine_slot_get_num_deform(spine_slot slot) => _spine_slot_get_num_deform(slot);

  late final _spine_slot_get_num_deform = _lookup<
          ffi.NativeFunction<ffi.Int32 Function(spine_slot)>>('spine_slot_get_num_deform')
      .asFunction<int Function(spine_slot)>();

  ffi.Pointer<ffi.Float> spine_slot_get_deform(spine_slot slot) => _spine_slot_get_deform(slot);

  late final _spine_slot_get_deform = _lookup<
          ffi.NativeFunction<ffi.Pointer<ffi.Float> Function(spine_slot)>>('spine_slot_get_deform')
      .asFunction<ffi.Pointer<ffi.Float> Function(spine_slot)>();

  int spine_slot_set_deform(spine_slot slot, ffi.Pointer<ffi.Float> values, int length) =>
      _spine_slot_set_deform(slot, values, length);

  late final _spine_slot_set_deform = _lookup<
          ffi.NativeFunction<spine_bool Function(spine_slot, ffi.Pointer<ffi.Float>, ffi.Int32)>>('spine_slot_set_deform')
      .asFunction<int Function(spine_slot, ffi.Pointer<ffi.Float>, int)>();

  void spine_slot_clear_deform(spine_slot slot) => _spine_slot_clear_deform(slot);

  late final _spine_slot_clear_deform = _lookup<
          ffi.NativeFunction<ffi.Void Function(spine_slot)>>('spine_slot_clear_deform')
      .asFunction<void Function(spine_slot)>();

  int spine_slot_get_sequence_index(
    spine_slot slot,
  ) {
""",
    ),
    (
        'src/spine-cpp-lite/spine-cpp-lite.h',
        r"""// @optional
SPINE_CPP_LITE_EXPORT spine_attachment spine_slot_get_attachment(spine_slot slot);
SPINE_CPP_LITE_EXPORT void spine_slot_set_attachment(spine_slot slot, spine_attachment attachment);
// OMITTED getDeform()
SPINE_CPP_LITE_EXPORT int32_t spine_slot_get_sequence_index(spine_slot slot);
SPINE_CPP_LITE_EXPORT void spine_slot_set_sequence_index(spine_slot slot, int32_t sequenceIndex);

""",
        r"""// @optional
SPINE_CPP_LITE_EXPORT spine_attachment spine_slot_get_attachment(spine_slot slot);
SPINE_CPP_LITE_EXPORT void spine_slot_set_attachment(spine_slot slot, spine_attachment attachment);
// Deform values are absolute local positions for unweighted attachments and
// per-bone-influence local offsets for weighted attachments. The getter's
// borrowed buffer is invalidated by any slot attachment/deform change.
SPINE_CPP_LITE_EXPORT int32_t spine_slot_get_num_deform(spine_slot slot);
SPINE_CPP_LITE_EXPORT float *spine_slot_get_deform(spine_slot slot);
// Returns false without modifying the slot for an invalid attachment, length,
// or non-finite value. Empty input clears the deformation.
SPINE_CPP_LITE_EXPORT spine_bool spine_slot_set_deform(spine_slot slot, const float *values, int32_t length);
SPINE_CPP_LITE_EXPORT void spine_slot_clear_deform(spine_slot slot);
SPINE_CPP_LITE_EXPORT int32_t spine_slot_get_sequence_index(spine_slot slot);
SPINE_CPP_LITE_EXPORT void spine_slot_set_sequence_index(spine_slot slot, int32_t sequenceIndex);

""",
    ),
    (
        'src/spine-cpp-lite/spine-cpp-lite.cpp',
        r"""#include <spine/spine.h>
#include <spine/Version.h>
#include <spine/Debug.h>

using namespace spine;

""",
        r"""#include <spine/spine.h>
#include <spine/Version.h>
#include <spine/Debug.h>
#include <cmath>

using namespace spine;

""",
    ),
    (
        'src/spine-cpp-lite/spine-cpp-lite.cpp',
        r"""	if (slot == nullptr) return;
	Slot *_slot = (Slot *) slot;
	_slot->setAttachment((Attachment *) attachment);
}

int32_t spine_slot_get_sequence_index(spine_slot slot) {
""",
        r"""	if (slot == nullptr) return;
	Slot *_slot = (Slot *) slot;
	_slot->setAttachment((Attachment *) attachment);
}

int32_t spine_slot_get_num_deform(spine_slot slot) {
	if (slot == nullptr) return 0;
	return (int32_t) ((Slot *) slot)->getDeform().size();
}

float *spine_slot_get_deform(spine_slot slot) {
	if (slot == nullptr) return nullptr;
	return ((Slot *) slot)->getDeform().buffer();
}

spine_bool spine_slot_set_deform(spine_slot slot, const float *values, int32_t length) {
	if (slot == nullptr || length < 0) return 0;
	Slot *_slot = (Slot *) slot;
	if (length == 0) {
		_slot->getDeform().clear();
		return -1;
	}
	Attachment *attachment = _slot->getAttachment();
	if (values == nullptr || attachment == nullptr || !attachment->getRTTI().instanceOf(VertexAttachment::rtti)) return 0;
	VertexAttachment *vertexAttachment = static_cast<VertexAttachment *>(attachment);
	size_t expected = vertexAttachment->getVertices().size();
	if (vertexAttachment->getBones().size() > 0) expected = expected / 3 * 2;
	if ((size_t) length != expected) return 0;
	for (int32_t i = 0; i < length; i++) {
		if (!std::isfinite(values[i])) return 0;
	}
	Vector<float> &deform = _slot->getDeform();
	deform.setSize(expected, 0);
	for (int32_t i = 0; i < length; i++) deform[i] = values[i];
	return -1;
}

void spine_slot_clear_deform(spine_slot slot) {
	if (slot == nullptr) return;
	((Slot *) slot)->getDeform().clear();
}

int32_t spine_slot_get_sequence_index(spine_slot slot) {
""",
    ),


    (
        'lib/spine_flutter.dart',
        r"""class Skeleton {
  final spine_skeleton _skeleton;
""",
        r"""/// Native physics constraints owned by the skeleton, never shared setup data.
class PhysicsConstraint {
  final spine_physics_constraint _constraint;
  PhysicsConstraint._(this._constraint);

  Bone getBone() => Bone._(_bindings.spine_physics_constraint_get_bone(_constraint));
  bool isActive() => _bindings.spine_physics_constraint_is_active(_constraint) != 0;
  double getMix() => _bindings.spine_physics_constraint_get_mix(_constraint);
  double getXOffset() => _bindings.spine_physics_constraint_get_x_offset(_constraint);
  double getYOffset() => _bindings.spine_physics_constraint_get_y_offset(_constraint);
  double getRotateOffset() => _bindings.spine_physics_constraint_get_rotate_offset(_constraint);

  /// Stimulate inertia before Physics.update without moving setup bones.
  void translate(double x, double y) {
    if (!x.isFinite || !y.isFinite || x.abs() > 1e6 || y.abs() > 1e6) {
      throw ArgumentError('Physics displacement must be finite and bounded.');
    }
    _bindings.spine_physics_constraint_translate(_constraint, x, y);
  }

  /// Clear transient history on lifecycle cancellation, not normal release.
  void resetFully() => _bindings.spine_physics_constraint_reset(_constraint);
}

class Skeleton {
  final spine_skeleton _skeleton;
""",
    ),
    (
        'lib/spine_flutter.dart',
        r"""  /// The skeleton's IK constraints.
  List<IkConstraint> getIkConstraints() {
""",
        r"""  /// Physics constraints authored into this skeleton instance.
  List<PhysicsConstraint> getPhysicsConstraints() {
    final count = _bindings.spine_skeleton_get_num_physics_constraints(_skeleton);
    final constraints = _bindings.spine_skeleton_get_physics_constraints(_skeleton);
    return [for (var i = 0; i < count; i++) PhysicsConstraint._(constraints[i])];
  }

  /// The skeleton's IK constraints.
  List<IkConstraint> getIkConstraints() {
""",
    ),
    (
        'lib/spine_flutter_bindings_generated.dart',
        r"""      _lookup<ffi.NativeFunction<ffi.Void Function(spine_physics_constraint)>>(
          'spine_physics_constraint_reset');
""",
        r"""      _lookup<ffi.NativeFunction<ffi.Void Function(spine_physics_constraint)>>(
          'spine_physics_constraint_reset_fully');
""",
    ),
]


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'packages' / 'spine_flutter')
    parser.add_argument('--check', action='store_true',
                        help='Check compatibility and report pending hunks without writing.')
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    contents = {}
    changed = set()
    pending = 0
    for relative, old, new in PATCHES:
        path = runtime / relative
        if path not in contents:
            if not path.is_file():
                raise RuntimeError(f'Local Spine runtime file is missing: {path}')
            contents[path] = path.read_text(encoding='utf-8')
        text = contents[path]
        if text.count(new) == 1:
            continue
        if text.count(old) != 1:
            raise RuntimeError(f'Unsupported or partially changed runtime: {path}. '
                               'No files were written; review this hunk manually.')
        contents[path] = text.replace(old, new, 1)
        changed.add(path)
        pending += 1
    if args.check:
        print(f'Compatible runtime; {pending} pending deformation API hunks.')
        return 0
    for path in sorted(changed):
        path.write_text(contents[path], encoding='utf-8', newline='')
    print(f'Deformation API ready; updated {len(changed)} files. Rebuild native libraries if changed.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
