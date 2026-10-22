import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_touch_physics.dart';

void main() {
  Offset continuous(Offset velocity, int fps, {double seconds = 1}) {
    final dynamics = CharacterTouchPhysicsDynamics()..begin();
    var sum = Offset.zero;
    for (var frame = 0; frame < (seconds * fps).round(); frame++) {
      dynamics.move(velocity);
      sum += dynamics.advance(1 / fps);
    }
    return sum;
  }

  test('fast touches excite more than slow ones with a soft speed ceiling', () {
    final slow = continuous(const Offset(.05, 0), 60);
    final medium = continuous(const Offset(.5, 0), 60);
    final fast = continuous(const Offset(2, 0), 60);
    final extreme = continuous(const Offset(1000000, 0), 60);
    expect(slow.dx, greaterThan(0));
    expect(medium.dx, greaterThan(slow.dx * 4));
    expect(fast.dx, greaterThan(medium.dx));
    // Keep the stronger response perceptible without removing the speed limit.
    expect(fast.dx, greaterThan(2.2));
    expect(
      extreme.dx,
      lessThan(CharacterTouchPhysicsDynamics.maximumImpulseRate),
    );
    expect(extreme.dx - fast.dx, lessThan(fast.dx * .06));
    expect(fast.dy, 0);
  });

  test('continuous excitation agrees at 30, 60 and 120 FPS', () {
    const velocity = Offset(.6, -.4);
    final thirty = continuous(velocity, 30);
    final sixty = continuous(velocity, 60);
    final hundredTwenty = continuous(velocity, 120);
    expect((thirty - sixty).distance, lessThan(1e-12));
    expect((sixty - hundredTwenty).distance, lessThan(1e-12));
    final speed = velocity.distance;
    final rate =
        CharacterTouchPhysicsDynamics.maximumImpulseRate *
        (1 -
            math.exp(
              -speed / CharacterTouchPhysicsDynamics.velocitySaturation,
            ));
    final tau = CharacterTouchPhysicsDynamics.smoothingSeconds;
    final expected = rate * (1 - tau * (1 - math.exp(-1 / tau)));
    expect(sixty.distance, closeTo(expected, 1e-12));
  });

  test('many pointer events in one frame do not multiply excitation', () {
    final single = CharacterTouchPhysicsDynamics()..begin();
    final batched = CharacterTouchPhysicsDynamics()..begin();
    for (var frame = 0; frame < 60; frame++) {
      single.move(const Offset(.8, -.2));
      for (var event = 0; event < 15; event++) {
        batched.move(const Offset(.8, -.2));
      }
      expect(batched.advance(1 / 60), single.advance(1 / 60));
    }
  });

  test(
    'a flick released before the first render retains bounded final speed',
    () {
      Offset flick(Offset velocity, {int events = 1, int fps = 60}) {
        final dynamics = CharacterTouchPhysicsDynamics()..begin();
        for (var event = 0; event < events; event++) {
          dynamics.move(velocity);
        }
        dynamics.release();
        // Duplicate platform release callbacks must not consume or multiply it.
        dynamics.release();
        expect(dynamics.isTouching, isFalse);
        expect(dynamics.active, isTrue);
        var sum = Offset.zero;
        for (var frame = 0; frame < fps; frame++) {
          final impulse = dynamics.advance(1 / fps);
          expect(
            impulse.distance,
            lessThanOrEqualTo(
              CharacterTouchPhysicsDynamics.maximumFrameImpulse,
            ),
          );
          sum += impulse;
        }
        expect(dynamics.active, isFalse);
        return sum;
      }

      final slow = flick(const Offset(.05, 0));
      final fast = flick(const Offset(2, 0));
      expect(slow.dx, greaterThan(0));
      expect(fast.dx, greaterThan(slow.dx * 5));
      expect(fast.distance, lessThan(.05));
      expect(flick(const Offset(2, 0), events: 1000), fast);
      expect(
        (flick(const Offset(2, 0), fps: 30) -
                flick(const Offset(2, 0), fps: 120))
            .distance,
        lessThan(1e-4),
      );
    },
  );

  test('release does not add a second sample after a move was rendered', () {
    final dynamics = CharacterTouchPhysicsDynamics()..begin();
    const velocity = Offset(.8, 0);
    dynamics.move(velocity);
    dynamics.advance(1 / 60);
    dynamics.release();
    final targetRate =
        CharacterTouchPhysicsDynamics.maximumImpulseRate *
        (1 -
            math.exp(
              -velocity.dx / CharacterTouchPhysicsDynamics.velocitySaturation,
            ));
    final smoothRate =
        targetRate *
        (1 -
            math.exp(
              -(1 / 60) / CharacterTouchPhysicsDynamics.smoothingSeconds,
            ));
    final expected =
        smoothRate *
        CharacterTouchPhysicsDynamics.releaseDecaySeconds *
        (1 -
            math.exp(
              -(1 / 60) / CharacterTouchPhysicsDynamics.releaseDecaySeconds,
            ));
    expect(dynamics.advance(1 / 60).dx, closeTo(expected, 1e-12));
  });

  test('release after a long stationary hold never revives an old move', () {
    final dynamics = CharacterTouchPhysicsDynamics()..begin();
    dynamics.move(const Offset(2, 0));
    for (var frame = 0; frame < 120; frame++) {
      dynamics.advance(1 / 60);
    }
    dynamics.release();
    expect(dynamics.active, isFalse);
    for (var frame = 0; frame < 30; frame++) {
      expect(dynamics.advance(1 / 60), Offset.zero);
    }
    dynamics.begin();
    dynamics.move(const Offset(2, 0));
    dynamics.release();
    dynamics.reset();
    expect(dynamics.active, isFalse);
    expect(dynamics.advance(1 / 60), Offset.zero);
  });

  test('direction changes are smoothed instead of instantly reversing', () {
    final dynamics = CharacterTouchPhysicsDynamics()..begin();
    for (var i = 0; i < 30; i++) {
      dynamics.move(const Offset(1, 0));
      dynamics.advance(1 / 60);
    }
    dynamics.move(const Offset(-1, 0));
    final first = dynamics.advance(1 / 120);
    expect(first.dx, greaterThan(0));
    for (var i = 0; i < 20; i++) {
      dynamics.move(const Offset(-1, 0));
      dynamics.advance(1 / 120);
    }
    dynamics.move(const Offset(-1, 0));
    expect(dynamics.advance(1 / 120).dx, lessThan(0));
  });

  test(
    'stationary touch stops injecting without requiring pointer release',
    () {
      final dynamics = CharacterTouchPhysicsDynamics()..begin();
      dynamics.move(const Offset(2, 0));
      for (var frame = 0; frame < 45; frame++) {
        dynamics.advance(1 / 120);
      }
      expect(dynamics.isTouching, isTrue);
      expect(dynamics.advance(1 / 60), Offset.zero);
      dynamics.move(const Offset(0, .5));
      expect(dynamics.advance(1 / 60).dy, greaterThan(0));
    },
  );

  test('stale pointer timeout is independent of the frame containing it', () {
    Offset stopped(int fps) {
      final dynamics = CharacterTouchPhysicsDynamics()..begin();
      dynamics.move(const Offset(.5, .3));
      var sum = Offset.zero;
      for (var frame = 0; frame < fps; frame++) {
        sum += dynamics.advance(1 / fps);
      }
      return sum;
    }

    // The settle threshold drops only a negligible tail of the exact curve.
    expect((stopped(30) - stopped(120)).distance, lessThan(1e-4));
    expect((stopped(60) - stopped(120)).distance, lessThan(1e-4));
  });

  test(
    'release decays briefly and delegates spring return to native physics',
    () {
      final dynamics = CharacterTouchPhysicsDynamics()..begin();
      for (var frame = 0; frame < 30; frame++) {
        dynamics.move(const Offset(2, 0));
        dynamics.advance(1 / 60);
      }
      dynamics.release();
      expect(dynamics.isTouching, isFalse);
      expect(dynamics.active, isTrue);
      final first = dynamics.advance(1 / 120);
      final second = dynamics.advance(1 / 120);
      expect(first.dx, greaterThan(second.dx));
      expect(second.dx, greaterThan(0));
      var remainder = first + second;
      for (var frame = 0; frame < 20; frame++) {
        final impulse = dynamics.advance(1 / 120);
        expect(impulse.dx, greaterThanOrEqualTo(0));
        remainder += impulse;
      }
      expect(remainder.distance, lessThan(.05));
      expect(dynamics.active, isFalse);
      expect(dynamics.advance(1 / 60), Offset.zero);
      dynamics.move(const Offset(100, 0));
      expect(dynamics.advance(1 / 60), Offset.zero);
    },
  );

  test('explicit zero velocity promptly decays the previous input', () {
    final dynamics = CharacterTouchPhysicsDynamics()..begin();
    for (var i = 0; i < 10; i++) {
      dynamics.move(const Offset(1, 0));
      dynamics.advance(1 / 60);
    }
    dynamics.move(Offset.zero);
    final first = dynamics.advance(1 / 60);
    final second = dynamics.advance(1 / 60);
    expect(second.distance, lessThan(first.distance * .5));
    for (var i = 0; i < 10; i++) {
      dynamics.advance(1 / 60);
    }
    expect(dynamics.advance(1 / 60), Offset.zero);
  });

  test('reset and a new touch discard all previous excitation', () {
    final dynamics = CharacterTouchPhysicsDynamics()..begin();
    dynamics.move(const Offset(1, 1));
    dynamics.advance(1 / 60);
    dynamics.reset();
    expect(dynamics.isTouching, isFalse);
    expect(dynamics.active, isFalse);
    expect(dynamics.advance(1 / 60), Offset.zero);
    dynamics.move(const Offset(10, 10));
    expect(dynamics.advance(1 / 60), Offset.zero);
    dynamics.begin();
    expect(dynamics.isTouching, isTrue);
    expect(dynamics.advance(1 / 60), Offset.zero);
    dynamics.move(const Offset(1, 0));
    dynamics.advance(1 / 60);
    dynamics.begin();
    expect(dynamics.advance(1 / 60), Offset.zero);
  });

  test(
    'invalid velocity or elapsed time cancels rather than replaying force',
    () {
      for (final badVelocity in const [
        Offset(double.nan, 0),
        Offset(0, double.infinity),
        Offset(double.negativeInfinity, 1),
      ]) {
        final dynamics = CharacterTouchPhysicsDynamics()..begin();
        dynamics.move(const Offset(1, 0));
        dynamics.advance(1 / 60);
        dynamics.move(badVelocity);
        expect(dynamics.active, isFalse);
        expect(dynamics.advance(1 / 60), Offset.zero);
      }
      for (final delta in [double.nan, double.infinity, -.01, .20001, 1000.0]) {
        final dynamics = CharacterTouchPhysicsDynamics()..begin();
        dynamics.move(const Offset(1, 0));
        expect(dynamics.advance(delta), Offset.zero);
        expect(dynamics.active, isFalse);
        expect(dynamics.advance(1 / 60), Offset.zero);
      }
    },
  );

  test(
    'zero elapsed time generates no impulse and preserves the live input',
    () {
      final dynamics = CharacterTouchPhysicsDynamics()..begin();
      dynamics.move(const Offset(1, 0));
      expect(dynamics.advance(0), Offset.zero);
      expect(dynamics.isTouching, isTrue);
      expect(dynamics.advance(1 / 60).dx, greaterThan(0));
    },
  );

  test('extreme finite velocities and long frames stay bounded and finite', () {
    for (final velocity in const [
      Offset(1e308, -1e308),
      Offset(-1e308, 0),
      Offset(1e-308, -1e-308),
    ]) {
      final dynamics = CharacterTouchPhysicsDynamics()..begin();
      for (var frame = 0; frame < 30; frame++) {
        dynamics.move(velocity);
        final impulse = dynamics.advance(.2);
        expect(impulse.dx.isFinite && impulse.dy.isFinite, isTrue);
        expect(
          impulse.distance,
          lessThanOrEqualTo(
            CharacterTouchPhysicsDynamics.maximumFrameImpulse + 1e-15,
          ),
        );
      }
      dynamics.reset();
      expect(dynamics.advance(1 / 60), Offset.zero);
    }
  });
}
