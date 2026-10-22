import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_face_pull.dart';

void main() {
  CharacterFacePullDynamics pulling() =>
      CharacterFacePullDynamics()
        ..begin(const Offset(10, 20), faceWidth: 200, faceHeight: 150);

  test(
    'small pulls follow touch and increasing pulls meet growing resistance',
    () {
      final pull = pulling();
      final small = pull.drag(const Offset(11, 20)).dx;
      expect(small, closeTo(1, 0.03));
      final medium = pull.drag(const Offset(34, 20)).dx;
      final large = pull.drag(const Offset(58, 20)).dx;
      expect(medium, greaterThan(small));
      expect(large - medium, lessThan(medium));
      expect(pull.isDragging, isTrue);
      expect(pull.active, isTrue);
      expect(pull.advance(1), Offset(large, 0));
    },
  );

  test(
    'pulls in either direction respect independent face-relative limits',
    () {
      final pull = pulling();
      final positive = pull.drag(const Offset(100000, 100000));
      expect(positive.dx, closeTo(24, 1e-9));
      expect(positive.dy, closeTo(12, 1e-9));
      final negative = pull.drag(const Offset(-100000, -100000));
      expect(negative.dx, closeTo(-24, 1e-9));
      expect(negative.dy, closeTo(-12, 1e-9));
      pull.release();
      for (var frame = 0; frame < 120; frame++) {
        final displacement = pull.advance(1 / 60);
        expect(displacement.dx.abs(), lessThanOrEqualTo(24));
        expect(displacement.dy.abs(), lessThanOrEqualTo(12));
      }
      expect(pull.displacement, Offset.zero);
      expect(pull.active, isFalse);
    },
  );

  test(
    'release rebounds smoothly and settles instead of snapping on release',
    () {
      final pull = pulling();
      final held = pull.drag(const Offset(34, 32));
      pull.release();
      expect(pull.isDragging, isFalse);
      expect(pull.active, isTrue);
      expect(pull.displacement, held);
      final firstFrame = pull.advance(1 / 120);
      expect(firstFrame.dx, inExclusiveRange(held.dx * 0.95, held.dx));
      var rebounded = false;
      for (var frame = 0; frame < 240; frame++) {
        if (pull.advance(1 / 120).dx < 0) rebounded = true;
      }
      expect(rebounded, isTrue);
      expect(pull.displacement, Offset.zero);
      expect(pull.active, isFalse);
    },
  );

  test('return motion agrees across frame rates and split time steps', () {
    Offset after(int frames, double dt) {
      final pull = pulling()
        ..drag(const Offset(35, -5))
        ..release();
      for (var i = 0; i < frames; i++) {
        pull.advance(dt);
      }
      return pull.displacement;
    }

    final lowFps = after(6, 1 / 24);
    final highFps = after(30, 1 / 120);
    final singleStep = after(1, 0.25);
    expect((lowFps - highFps).distance, lessThan(1e-10));
    expect((singleStep - highFps).distance, lessThan(1e-10));
  });

  test('cancel clears a held pull and cannot replay a stale pointer move', () {
    final pull = pulling()..drag(const Offset(60, 40));
    pull.reset();
    expect(pull.active, isFalse);
    expect(pull.isDragging, isFalse);
    expect(pull.drag(const Offset(100, 200)), Offset.zero);
    expect(pull.advance(0.016), Offset.zero);
    pull.begin(const Offset(5, 5), faceWidth: 40, faceHeight: 40);
    expect(pull.displacement, Offset.zero);
    expect(pull.anchor, const Offset(5, 5));
    expect(pull.drag(const Offset(6, 5)).dx, inExclusiveRange(0, 1));
  });

  test('malformed input and app suspension preserve finite states', () {
    final pull = pulling()..drag(const Offset(30, 35));
    final before = pull.displacement;
    expect(pull.drag(const Offset(double.nan, 30)), before);
    pull.release();
    for (final dt in [double.nan, double.infinity, -1.0, 0.0]) {
      expect(pull.advance(dt), before);
    }
    expect(pull.advance(1000000), Offset.zero);
    expect(pull.active, isFalse);
    for (final size in [double.nan, double.infinity, -1.0, 0.0]) {
      pull.begin(Offset.zero, faceWidth: size, faceHeight: 100);
      expect(pull.active, isFalse);
      expect(pull.drag(const Offset(100, 100)), Offset.zero);
    }
    pull.begin(
      const Offset(-1e300, -1e300),
      faceWidth: 1e300,
      faceHeight: 1e300,
    );
    pull.drag(const Offset(1e300, 1e300));
    pull.release();
    final extreme = pull.advance(0.016);
    expect(extreme.dx.isFinite && extreme.dy.isFinite, isTrue);
  });

  test(
    'local influence is radial, smooth, and vanishes outside its radius',
    () {
      const anchor = Offset(10, 20);
      double weight(Offset vertex) =>
          facePullWeight(vertex, anchor, radius: 10);
      expect(weight(anchor), 1);
      expect(weight(const Offset(15, 20)), 0.5);
      expect(weight(const Offset(10, 25)), 0.5);
      expect(weight(const Offset(20, 20)), 0);
      expect(weight(const Offset(30, 20)), 0);
      expect(weight(const Offset(19.999, 20)), lessThan(1e-6));
      expect(1 - weight(const Offset(10.001, 20)), lessThan(1e-6));
      expect(facePullWeight(anchor, anchor, radius: double.nan), 0);
      expect(facePullWeight(anchor, anchor, radius: 0), 0);
      expect(weight(const Offset(double.infinity, 20)), 0);
    },
  );

  group('skin protection', () {
    const eye = Rect.fromLTRB(-2, -1, 2, 1);
    double weight(
      Offset vertex, {
      List<Rect> areas = const [eye],
      double fade = 4,
    }) => skinPullWeight(
      vertex,
      vertex,
      radius: 10,
      protectedAreas: areas,
      protectionFade: fade,
    );

    test('eye interior and every rectangle boundary remain strictly fixed', () {
      for (final vertex in const [
        Offset.zero,
        Offset(-1, 0.5),
        Offset(-2, 0),
        Offset(2, 0),
        Offset(0, -1),
        Offset(0, 1),
        Offset(2, 1),
      ]) {
        expect(weight(vertex), 0);
      }
    });

    test(
      'outer protection fade is smooth and uses Euclidean corner distance',
      () {
        expect(weight(const Offset(4, 0)), 0.5);
        expect(weight(const Offset(6, 0)), 1);
        expect(weight(const Offset(7, 0)), 1);
        expect(weight(const Offset(2.00001, 0)), lessThan(1e-9));
        expect(1 - weight(const Offset(5.99999, 0)), lessThan(1e-9));
        expect(
          weight(const Offset(3, 0)) - weight(const Offset(2.99999, 0)),
          inExclusiveRange(0, 1e-5),
        );
        // A 3-4-5 offset from the corner, with ten units of fade, is halfway.
        expect(weight(const Offset(5, 5), fade: 10), 0.5);
      },
    );

    test(
      'multiple protection areas multiply and no areas preserve old weight',
      () {
        const secondEye = Rect.fromLTRB(6, -1, 10, 1);
        expect(weight(const Offset(4, 0), areas: [eye, secondEye]), 0.25);
        expect(weight(const Offset(8, 0), areas: [eye, secondEye]), 0);
        const vertex = Offset(3, 4);
        expect(
          skinPullWeight(
            vertex,
            Offset.zero,
            radius: 10,
            protectedAreas: const [],
            protectionFade: 4,
          ),
          facePullWeight(vertex, Offset.zero, radius: 10),
        );
        // Empty geometry is valid, rather than a malformed negative-size rect.
        expect(weight(const Offset(2, 0), areas: [Rect.zero]), 0.5);
      },
    );

    test('malformed parameters safely produce zero', () {
      for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
        expect(weight(const Offset(4, 0), fade: invalid), 0);
        expect(
          skinPullWeight(
            const Offset(4, 0),
            Offset.zero,
            radius: invalid,
            protectedAreas: const [],
            protectionFade: 4,
          ),
          0,
        );
      }
      for (final area in const [
        Rect.fromLTRB(2, 0, 1, 1),
        Rect.fromLTRB(0, 2, 1, 1),
        Rect.fromLTRB(double.nan, 0, 1, 1),
        Rect.fromLTRB(0, 0, double.infinity, 1),
        Rect.fromLTRB(-1e308, 0, 1e308, 1),
      ]) {
        expect(weight(const Offset(4, 0), areas: [area]), 0);
      }
      for (final point in const [
        Offset(double.nan, 0),
        Offset(0, double.infinity),
      ]) {
        expect(weight(point), 0);
        expect(
          skinPullWeight(
            Offset.zero,
            point,
            radius: 10,
            protectedAreas: const [],
            protectionFade: 4,
          ),
          0,
        );
      }
    });

    test('extreme finite geometry never produces a nonfinite weight', () {
      const vertex = Offset(1e308, 1e308);
      expect(
        skinPullWeight(
          vertex,
          vertex,
          radius: 10,
          protectedAreas: const [Rect.fromLTRB(-1e308, -1e308, -9e307, -9e307)],
          protectionFade: 1e308,
        ),
        1,
      );
      expect(
        skinPullWeight(
          Offset.zero,
          Offset.zero,
          radius: 10,
          protectedAreas: const [Rect.fromLTRB(9e307, 9e307, 1e308, 1e308)],
          protectionFade: 1e308,
        ),
        1,
      );
    });
  });

  group('skin topology limit', () {
    const vertices = [0.0, 0.0, 1.0, 0.0, 0.0, 1.0];
    const triangle = [0, 1, 2];
    double areaRatio(List<double> shifts, List<int> indices, double scale) {
      Offset point(int index) => Offset(
        vertices[index * 2] + shifts[index * 2] * scale,
        vertices[index * 2 + 1] + shifts[index * 2 + 1] * scale,
      );
      double cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
      final original1 = Offset(
        vertices[indices[1] * 2] - vertices[indices[0] * 2],
        vertices[indices[1] * 2 + 1] - vertices[indices[0] * 2 + 1],
      );
      final original2 = Offset(
        vertices[indices[2] * 2] - vertices[indices[0] * 2],
        vertices[indices[2] * 2 + 1] - vertices[indices[0] * 2 + 1],
      );
      return cross(
            point(indices[1]) - point(indices[0]),
            point(indices[2]) - point(indices[0]),
          ) /
          cross(original1, original2);
    }

    test(
      'unchanged geometry, translation and expansion retain full movement',
      () {
        for (final shifts in const [
          [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
          [100.0, -200.0, 100.0, -200.0, 100.0, -200.0],
          [0.0, 0.0, 1.0, 0.0, 0.0, 1.0],
        ]) {
          expect(skinPullTopologyScale(vertices, shifts, triangle), 1);
        }
        expect(skinPullTopologyScale(const [], const [], const []), 1);
      },
    );

    test(
      'folding is limited with float margin for either original winding',
      () {
        const shifts = [0.0, 0.0, 0.0, 0.0, 0.0, -2.0];
        for (final indices in const [
          triangle,
          [0, 2, 1],
        ]) {
          final scale = skinPullTopologyScale(vertices, shifts, indices);
          expect(scale, closeTo(.44 * .98, 1e-12));
          expect(areaRatio(shifts, indices, 1), lessThan(0));
          for (var step = 0; step <= 200; step++) {
            expect(
              areaRatio(shifts, indices, scale * step / 200),
              greaterThan(.12),
            );
          }
        }
      },
    );

    test('positive final area cannot hide a fold earlier along the path', () {
      // (1-2s)*(1-4s) becomes negative, then recovers to three at s=1.
      const shifts = [0.0, 0.0, -2.0, 0.0, 0.0, -4.0];
      expect(areaRatio(shifts, triangle, 1), 3);
      expect(areaRatio(shifts, triangle, .3), lessThan(0));
      final scale = skinPullTopologyScale(vertices, shifts, triangle);
      expect(scale, closeTo(.2 * .98, 1e-12));
      for (var step = 0; step <= 200; step++) {
        expect(
          areaRatio(shifts, triangle, scale * step / 200),
          greaterThan(.12),
        );
      }
    });

    test('the earliest triangle limit applies to the entire mesh', () {
      const mesh = [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 3.0, 0.0, 4.0, 0.0, 3.0, 1.0];
      const shifts = [
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        -2.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        -4.0,
      ];
      expect(
        skinPullTopologyScale(mesh, shifts, const [0, 1, 2, 3, 4, 5]),
        closeTo(.22 * .98, 1e-12),
      );
      expect(
        skinPullTopologyScale(vertices, const [0, 0, 0, 0, 0, -.88], triangle),
        closeTo(.98, 1e-12),
      );
    });

    test('initially degenerate triangles do not restrict valid movement', () {
      const degenerate = [0.0, 0.0, 1.0, 0.0, 2.0, 0.0];
      expect(
        skinPullTopologyScale(degenerate, const [
          0,
          0,
          0,
          100,
          0,
          -100,
        ], triangle),
        1,
      );
      const tiny = [0.0, 0.0, 1e-5, 0.0, 0.0, 1e-5];
      expect(
        skinPullTopologyScale(tiny, const [0, 0, 0, 0, 0, -1], triangle),
        1,
      );
    });

    test(
      'malformed arrays, coordinates, indices and ratios safely disable pull',
      () {
        const zeroShifts = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        expect(skinPullTopologyScale(const [0.0], const [0.0], const []), 0);
        expect(skinPullTopologyScale(vertices, const [], triangle), 0);
        for (final indices in const [
          [0, 1],
          [0, 1, -1],
          [0, 1, 3],
        ]) {
          expect(skinPullTopologyScale(vertices, zeroShifts, indices), 0);
        }
        for (final ratio in [0.0, -1.0, 1.0, double.nan, double.infinity]) {
          expect(
            skinPullTopologyScale(
              vertices,
              zeroShifts,
              triangle,
              minimumAreaRatio: ratio,
            ),
            0,
          );
        }
        for (final bad in [
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]) {
          expect(
            skinPullTopologyScale(
              [bad, ...vertices.skip(1)],
              zeroShifts,
              triangle,
            ),
            0,
          );
          expect(
            skinPullTopologyScale(vertices, [
              bad,
              ...zeroShifts.skip(1),
            ], triangle),
            0,
          );
        }
        expect(
          skinPullTopologyScale(
            const [-1e308, 0, 1e308, 0, 0, 1e308],
            zeroShifts,
            triangle,
          ),
          0,
        );
      },
    );
  });
}
