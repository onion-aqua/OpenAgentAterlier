import 'dart:math' as math;
import 'dart:ui';

/// Converts pointer velocity into bounded translation impulses for Spine's
/// existing physics constraints. Input uses scene widths/heights per second;
/// output is a displacement relative to the caller's reference scene width.
/// This does not animate bones or keep a second spring alongside Spine.
class CharacterTouchPhysicsDynamics {
  /// Relative to the original touch response, not multiplied per revision.
  static const strengthMultiplier = 10.0;

  /// Maximum translation accumulated during one second of continuous motion.
  static const maximumImpulseRate = .25 * strengthMultiplier;

  /// A press and a swipe use the same strength scale.
  static const pressImpulse = .003 * strengthMultiplier;

  /// A speed of one reference dimension/second approaches the rate limit.
  static const velocitySaturation = .65;

  /// Smooth event noise while keeping the response close to the finger.
  static const smoothingSeconds = .035;

  /// Stop driving quickly; Spine itself handles the subsequent spring return.
  static const releaseDecaySeconds = .018;
  static const stationaryTimeoutSeconds = .08;

  /// Preserve one short sample when down/move/up all precede a render frame.
  /// Further pointer events replace this sample instead of adding impulses.
  static const releaseSampleSeconds = .016;

  /// At most 12% of the reference width is injected in any individual frame.
  /// This is above the continuous-motion maximum at 30 FPS and above.
  static const maximumFrameImpulse = .012 * strengthMultiplier;

  static const _settledRate = maximumImpulseRate * .001;
  static const _maximumDelta = .2;

  Offset _targetRate = Offset.zero;
  Offset _smoothedRate = Offset.zero;
  double _inputAge = stationaryTimeoutSeconds;
  double _releaseSampleRemaining = 0;
  bool _hasUnconsumedMove = false;
  bool _isTouching = false;

  bool get isTouching => _isTouching;
  bool get active =>
      _isTouching || _targetRate != Offset.zero || _smoothedRate != Offset.zero;

  void begin() {
    reset();
    _isTouching = true;
  }

  /// Stores the latest velocity rather than adding force per pointer event.
  /// Sparse/batched input therefore cannot multiply the amount of excitation.
  void move(Offset velocity) {
    if (!_isTouching) return;
    if (!velocity.dx.isFinite || !velocity.dy.isFinite) {
      reset();
      return;
    }
    _targetRate = _velocityRate(velocity);
    _inputAge = 0;
    _hasUnconsumedMove = true;
  }

  void release() {
    if (!_isTouching) return;
    _isTouching = false;
    _releaseSampleRemaining = _hasUnconsumedMove && _targetRate != Offset.zero
        ? releaseSampleSeconds
        : 0;
    _hasUnconsumedMove = false;
    if (_releaseSampleRemaining == 0) _targetRate = Offset.zero;
    _inputAge = stationaryTimeoutSeconds;
  }

  /// Cancels all remaining input when a scene, gesture owner or lifecycle
  /// changes. A later pointer move cannot restart excitation without [begin].
  void reset() {
    _isTouching = false;
    _targetRate = Offset.zero;
    _smoothedRate = Offset.zero;
    _inputAge = stationaryTimeoutSeconds;
    _releaseSampleRemaining = 0;
    _hasUnconsumedMove = false;
  }

  /// Returns only this frame's impulse. Exact integration of the smoothing
  /// curve keeps accumulated excitation independent of render frame rate.
  Offset advance(double delta) {
    if (!delta.isFinite || delta < 0 || delta > _maximumDelta) {
      reset();
      return Offset.zero;
    }
    if (delta == 0 || !active) return Offset.zero;

    var impulse = Offset.zero;
    var remaining = delta;
    if (_releaseSampleRemaining > 0) {
      final drivenTime = math.min(remaining, _releaseSampleRemaining);
      impulse += _integrate(_targetRate, drivenTime, smoothingSeconds);
      _releaseSampleRemaining -= drivenTime;
      remaining -= drivenTime;
    }
    if (_isTouching && _inputAge < stationaryTimeoutSeconds) {
      // Split at the timeout so a slow frame never extends stale pointer force.
      final drivenTime = math.min(
        remaining,
        stationaryTimeoutSeconds - _inputAge,
      );
      final tau = _targetRate == Offset.zero
          ? releaseDecaySeconds
          : smoothingSeconds;
      impulse += _integrate(_targetRate, drivenTime, tau);
      _inputAge += drivenTime;
      remaining -= drivenTime;
    }
    _hasUnconsumedMove = false;
    if (_inputAge >= stationaryTimeoutSeconds && _releaseSampleRemaining == 0) {
      _targetRate = Offset.zero;
    }
    if (remaining > 0) {
      impulse += _integrate(Offset.zero, remaining, releaseDecaySeconds);
    }
    if (_targetRate == Offset.zero && _smoothedRate.distance <= _settledRate) {
      _smoothedRate = Offset.zero;
    }
    final length = impulse.distance;
    if (length > maximumFrameImpulse) {
      // Drop excess from a delayed frame; never queue a later burst of force.
      impulse *= maximumFrameImpulse / length;
    }
    return impulse;
  }

  Offset _integrate(Offset target, double delta, double tau) {
    final attenuation = math.exp(-delta / tau);
    final difference = _smoothedRate - target;
    final integral = target * delta + difference * (tau * (1 - attenuation));
    _smoothedRate = target + difference * attenuation;
    return integral;
  }

  static Offset _velocityRate(Offset velocity) {
    // Normalize before squaring to keep even extreme finite input safe.
    final scale = math.max(velocity.dx.abs(), velocity.dy.abs());
    if (scale == 0) return Offset.zero;
    final normalized = velocity / scale;
    final normalizedLength = normalized.distance;
    final speed = scale * normalizedLength;
    final rate =
        maximumImpulseRate * (1 - math.exp(-speed / velocitySaturation));
    return normalized * (rate / normalizedLength);
  }
}
