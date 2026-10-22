import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spine_flutter/spine_flutter.dart';

// Offline regression on the actual owned rigs and C++ runtime. No app or
// device is launched. Build the local native DLL and add its folder to PATH.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';
  const atlasPath =
      'assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01.atlas';
  for (final weighted in [false, true]) {
    test(
      'deformation uses ${weighted ? 'per-influence offsets' : 'absolute local vertices'}',
      () async {
        await initSpineFlutter();
        final atlas = await Atlas.fromFile(atlasPath);
        const positions = [0.0, 0.0, 10.0, 0.0, 0.0, 10.0];
        final vertices = weighted
            ? [
                for (var i = 0; i < positions.length; i += 2) ...[
                  2,
                  0,
                  positions[i],
                  positions[i + 1],
                  0.5,
                  1,
                  positions[i],
                  positions[i + 1],
                  0.5,
                ],
              ]
            : positions;
        final data = SkeletonData.fromJson(
          atlas,
          jsonEncode({
            'skeleton': {'spine': '4.2.36'},
            'bones': [
              {'name': 'root', 'x': 2, 'y': 3},
              {'name': 'child', 'parent': 'root', 'x': 10},
            ],
            'slots': [
              {'name': 'mesh', 'bone': 'root', 'attachment': 'face'},
              {'name': 'region', 'bone': 'root', 'attachment': 'face'},
            ],
            'skins': [
              {
                'name': 'default',
                'attachments': {
                  'mesh': {
                    'face': {
                      'type': 'mesh',
                      'path': 'face_01',
                      'uvs': [0, 0, 1, 0, 0, 1],
                      'triangles': [0, 1, 2],
                      'vertices': vertices,
                      'hull': 3,
                    },
                  },
                  'region': {
                    'face': {'path': 'face_01', 'width': 10, 'height': 10},
                  },
                },
              },
            ],
          }),
        );
        final drawable = SkeletonDrawable(atlas, data, true);
        try {
          final slot = drawable.skeleton.findSlot('mesh')!;
          final region = drawable.skeleton.findSlot('region')!;
          final mesh = slot.getAttachment()! as MeshAttachment;
          final before = mesh.computeWorldVertices(slot);
          final deform = weighted
              ? List.generate(12, (i) => i.isEven ? 2.0 : -1.0)
              : List.generate(6, (i) => positions[i] + (i.isEven ? 2.0 : -1.0));
          slot.setDeform(deform);
          final after = mesh.computeWorldVertices(slot);
          final bone = slot.getBone();
          final deltaX = 2 * bone.getA() - bone.getB();
          final deltaY = 2 * bone.getC() - bone.getD();
          for (var i = 0; i < before.length; i++) {
            expect(
              after[i] - before[i],
              closeTo(i.isEven ? deltaX : deltaY, 0.0001),
            );
          }
          expect(() => region.setDeform(deform), throwsArgumentError);
          slot.clearDeform();
          expect(mesh.computeWorldVertices(slot), orderedEquals(before));
        } finally {
          drawable.dispose();
        }
      },
      skip: !enabled || !File(atlasPath).existsSync()
          ? 'Requires AAR_SPINE_NATIVE_TEST=1, native DLL and local owned atlas.'
          : false,
    );
  }
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
      'face deformation API changes vertices without mutating shared $skin',
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
        try {
          final slotName = id == '0001_99' ? '034_face' : '039_face';
          final slot = drawable.skeleton.findSlot(slotName)!;
          final otherSlot = other.skeleton.findSlot(slotName)!;
          final attachment = slot.getAttachment()! as MeshAttachment;
          final original = attachment.getVertices().toList();
          final before = attachment.computeWorldVertices(slot);
          final otherBefore = attachment.computeWorldVertices(otherSlot);
          final expected = attachment.getBones().isEmpty
              ? original.length
              : original.length ~/ 3 * 2;
          expect(expected, id == '0001_99' ? 276 : 482);
          expect(slot.getDeform(), isEmpty);

          final deformation = attachment.getBones().isEmpty
              ? original.map((value) => value + 5).toList()
              : List<double>.filled(expected, 5);
          slot.setDeform(deformation);
          expect(slot.getDeform(), orderedEquals(deformation));
          final snapshot = slot.getDeform();
          snapshot[0] = 100;
          expect(slot.getDeform()[0], deformation[0]);
          final changed = attachment.computeWorldVertices(slot);
          expect(changed.every((value) => value.isFinite), isTrue);
          expect(
            List.generate(
              changed.length,
              (i) => (changed[i] - before[i]).abs(),
            ).any((delta) => delta > 0.1),
            isTrue,
          );
          expect(attachment.getVertices(), orderedEquals(original));
          expect(otherSlot.getDeform(), isEmpty);
          expect(
            attachment.computeWorldVertices(otherSlot),
            orderedEquals(otherBefore),
          );

          expect(
            () => slot.setDeform(deformation.sublist(1)),
            throwsArgumentError,
          );
          final invalid = List<double>.of(deformation)..[0] = double.nan;
          expect(() => slot.setDeform(invalid), throwsArgumentError);
          invalid[0] = double.infinity;
          expect(() => slot.setDeform(invalid), throwsArgumentError);
          invalid[0] = 1e300; // Finite double, but not a finite native float.
          expect(() => slot.setDeform(invalid), throwsArgumentError);
          expect(slot.getDeform(), orderedEquals(deformation));

          slot.clearDeform();
          expect(slot.getDeform(), isEmpty);
          expect(attachment.computeWorldVertices(slot), orderedEquals(before));
          slot.setDeform(deformation);
          slot.setDeform(const []);
          expect(slot.getDeform(), isEmpty);
          slot.setDeform(deformation);
          slot.setAttachment(null);
          expect(slot.getDeform(), isEmpty);
          expect(() => slot.setDeform(deformation), throwsArgumentError);
          slot.setAttachment(attachment);
          expect(attachment.computeWorldVertices(slot), orderedEquals(before));
        } finally {
          other.dispose();
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Requires AAR_SPINE_NATIVE_TEST=1, native DLL and local owned rigs.'
          : false,
    );
  }
}
