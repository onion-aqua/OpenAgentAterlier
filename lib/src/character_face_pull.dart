import 'dart:math' as math;
import 'dart:ui';

/// Local, bounded cheek pulling. Coordinates must use the same space as the
/// face mesh; neither the simulation nor its limits depend on screen pixels.
class CharacterFacePullDynamics {
  static const _frequency = 20.0;
  static const _dampingRatio = 0.72;
  static const _decay = _frequency * _dampingRatio;
  static final _oscillation =
      _frequency * math.sqrt(1 - _dampingRatio * _dampingRatio);

  Offset _anchor = Offset.zero;
  Offset _displacement = Offset.zero;
  Offset _velocity = Offset.zero;
  double _horizontalLimit = 0;
  double _verticalLimit = 0;
  double _settleDistance = 0;
  bool _isDragging = false;

  Offset get anchor => _anchor;
  Offset get displacement => _displacement;
  bool get isDragging => _isDragging;
  bool get active => _isDragging || _displacement != Offset.zero;

  void begin(
    Offset anchor, {
    required double faceWidth,
    required double faceHeight,
  }) {
    reset();
    if (!_finite(anchor) ||
        !faceWidth.isFinite ||
        !faceHeight.isFinite ||
        faceWidth <= 0 ||
        faceHeight <= 0) {
      return;
    }
    // Bound pathological imported geometry before spring arithmetic. Real
    // skeleton coordinates are many orders of magnitude below this ceiling.
    _horizontalLimit = math.min(faceWidth, 1e12) * 0.12;
    _verticalLimit = math.min(faceHeight, 1e12) * 0.08;
    if (_horizontalLimit <= 0 || _verticalLimit <= 0) return;
    _settleDistance = math.max(
      1e-6,
      math.min(_horizontalLimit, _verticalLimit) * 0.001,
    );
    _anchor = anchor;
    _isDragging = true;
  }

  Offset drag(Offset point) {
    if (!_isDragging || !_finite(point)) return _displacement;
    _displacement = Offset(
      _rubberPull(point.dx - _anchor.dx, _horizontalLimit),
      _rubberPull(point.dy - _anchor.dy, _verticalLimit),
    );
    // Release starts at rest so sparse pointer events cannot produce a fling.
    _velocity = Offset.zero;
    return _displacement;
  }

  void release() {
    _isDragging = false;
  }

  /// Cancel immediately when the character, scene, or touch ownership changes.
  void reset() {
    _anchor = Offset.zero;
    _displacement = Offset.zero;
    _velocity = Offset.zero;
    _horizontalLimit = 0;
    _verticalLimit = 0;
    _settleDistance = 0;
    _isDragging = false;
  }

  /// Exact damped-spring evolution avoids frame-rate dependent integration.
  /// Invalid time steps leave the current state intact; a long suspension
  /// settles the spring rather than replaying an old pull on app resume.
  Offset advance(double dt) {
    if (_isDragging || !active || !dt.isFinite || dt <= 0) {
      return _displacement;
    }
    if (dt >= 5) {
      reset();
      return _displacement;
    }
    final attenuation = math.exp(-_decay * dt);
    final cosine = math.cos(_oscillation * dt);
    final sine = math.sin(_oscillation * dt);
    final coefficient = (_velocity + _displacement * _decay) / _oscillation;
    final nextDisplacement =
        (_displacement * cosine + coefficient * sine) * attenuation;
    final nextVelocity =
        (_velocity * cosine -
            (_displacement * _oscillation + coefficient * _decay) * sine) *
        attenuation;
    if (!_finite(nextDisplacement) || !_finite(nextVelocity)) {
      reset();
      return _displacement;
    }
    _displacement = nextDisplacement;
    _velocity = nextVelocity;
    if (_displacement.distance < _settleDistance &&
        _velocity.distance < _settleDistance * _frequency) {
      reset();
    }
    return _displacement;
  }

  static double _rubberPull(double distance, double limit) {
    if (distance == 0) return 0;
    final magnitude = limit * (1 - math.exp(-distance.abs() / limit));
    return distance < 0 ? -magnitude : magnitude;
  }
}

/// Smoothly preserves vertices outside the touch neighborhood. The derivative
/// is zero at the grab point and at the boundary, preventing a hard mesh seam.
double facePullWeight(Offset vertex, Offset anchor, {required double radius}) {
  if (!_finite(vertex) || !_finite(anchor) || !radius.isFinite || radius <= 0) {
    return 0;
  }
  final distance = (vertex - anchor).distance;
  final t = distance / radius;
  if (t >= 1) return 0;
  final remaining = 1 - t;
  return remaining * remaining * (1 + 2 * t);
}

/// Local skin influence with fixed protected features such as the eye socket.
/// Protection is zero inside each rectangle and fades smoothly outside it,
/// including around corners. All coordinates use the same mesh-local space.
double skinPullWeight(
  Offset vertex,
  Offset anchor, {
  required double radius,
  required List<Rect> protectedAreas,
  required double protectionFade,
}) {
  if (!_finite(vertex) ||
      !_finite(anchor) ||
      !radius.isFinite ||
      radius <= 0 ||
      !protectionFade.isFinite ||
      protectionFade <= 0) {
    return 0;
  }
  var weight = facePullWeight(vertex, anchor, radius: radius);
  for (final area in protectedAreas) {
    if (!area.left.isFinite ||
        !area.top.isFinite ||
        !area.right.isFinite ||
        !area.bottom.isFinite ||
        !area.width.isFinite ||
        !area.height.isFinite ||
        area.width < 0 ||
        area.height < 0) {
      return 0;
    }
    final dx = math.max(
      0.0,
      math.max(area.left - vertex.dx, vertex.dx - area.right),
    );
    final dy = math.max(
      0.0,
      math.max(area.top - vertex.dy, vertex.dy - area.bottom),
    );
    final scale = math.max(dx, dy);
    if (scale == 0) return 0;
    // Normalize before squaring so large finite imported coordinates cannot
    // overflow the distance calculation. Overflowing differences are outside
    // any finite fade and therefore leave this protection factor at one.
    if (!scale.isFinite) continue;
    final t =
        (scale / protectionFade) *
        math.sqrt((dx / scale) * (dx / scale) + (dy / scale) * (dy / scale));
    if (t >= 1) continue;
    weight *= t * t * (3 - 2 * t);
  }
  return weight;
}

/// Uniformly limits skin shifts before any triangle folds or collapses.
/// [vertices] and [shifts] contain matching x/y pairs in the same space;
/// [triangles] contains vertex indices. The signed area must stay above
/// [minimumAreaRatio] of its original value throughout the entire pull path,
/// rather than only at the final displacement. Initially degenerate triangles
/// have no stable orientation and are ignored. Malformed geometry returns zero.
double skinPullTopologyScale(
  List<double> vertices,
  List<double> shifts,
  List<int> triangles, {
  double minimumAreaRatio = .12,
}) {
  if (vertices.length.isOdd ||
      shifts.length != vertices.length ||
      triangles.length % 3 != 0 ||
      !minimumAreaRatio.isFinite ||
      minimumAreaRatio <= 0 ||
      minimumAreaRatio >= 1 ||
      !vertices.every((v) => v.isFinite) ||
      !shifts.every((v) => v.isFinite) ||
      triangles.any((i) => i < 0 || i >= vertices.length ~/ 2)) {
    return 0;
  }
  var firstLimit = double.infinity;
  for (var i = 0; i < triangles.length; i += 3) {
    final origin = triangles[i] * 2;
    final first = triangles[i + 1] * 2;
    final second = triangles[i + 2] * 2;
    final x1 = vertices[first] - vertices[origin];
    final y1 = vertices[first + 1] - vertices[origin + 1];
    final x2 = vertices[second] - vertices[origin];
    final y2 = vertices[second + 1] - vertices[origin + 1];
    final area = (x1 * y2 - y1 * x2) * .5;
    if (!area.isFinite) return 0;
    if (area.abs() < 1e-8) continue;
    final dx1 = shifts[first] - shifts[origin];
    final dy1 = shifts[first + 1] - shifts[origin + 1];
    final dx2 = shifts[second] - shifts[origin];
    final dy2 = shifts[second + 1] - shifts[origin + 1];
    // Divide by the signed original area so either triangle winding starts at
    // ratio one. The ratio at scale s is a*s*s + b*s + 1.
    final a = (dx1 * dy2 - dy1 * dx2) * .5 / area;
    final b = (dx1 * y2 - dy1 * x2 + x1 * dy2 - y1 * dx2) * .5 / area;
    if (!a.isFinite || !b.isFinite) return 0;
    final c = 1 - minimumAreaRatio;
    if (a == 0) {
      if (b < 0) firstLimit = math.min(firstLimit, -c / b);
      continue;
    }
    // Scale coefficients before the discriminant to avoid squaring very large
    // finite values. The stable quadratic formula also avoids cancellation
    // when one root lies much closer to zero than the other.
    final normalization = math.max(c, math.max(a.abs(), b.abs()));
    final na = a / normalization;
    final nb = b / normalization;
    final nc = c / normalization;
    final discriminant = nb * nb - 4 * na * nc;
    if (!discriminant.isFinite || nc == 0) return 0;
    if (discriminant < 0) continue;
    final root = math.sqrt(discriminant);
    final q = -.5 * (nb + (nb < 0 ? -root : root));
    if (q == 0) return 0;
    final firstRoot = q / na;
    final secondRoot = nc / q;
    if (firstRoot > 0) firstLimit = math.min(firstLimit, firstRoot);
    if (secondRoot > 0) firstLimit = math.min(firstLimit, secondRoot);
  }
  // Float-valued native vertices need margin before the first collapse point.
  return firstLimit <= 1 ? (firstLimit * .98).clamp(0.0, 1.0) : 1;
}

bool _finite(Offset point) => point.dx.isFinite && point.dy.isFinite;
