import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:spine_flutter/spine_flutter.dart';

/// Compact, immutable alpha samples for the rendered Spine atlas pages.
///
/// Only Dart bytes remain after construction; changing costumes or disposing
/// the source atlas cannot invalidate an already completed mask.
class CharacterTouchHitMask {
  CharacterTouchHitMask._(this._pages);

  static const _maximumEdge = 1024;
  static const _minimumAlpha = 24;

  final List<_AlphaPage> _pages;

  static Future<CharacterTouchHitMask> fromAtlas(Atlas atlas) =>
      fromImages(atlas.atlasPages);

  /// Clones every image synchronously before starting asynchronous readback.
  /// Callers may release the original image handles as soon as this returns.
  static Future<CharacterTouchHitMask> fromImages(List<ui.Image> images) {
    final clones = <ui.Image>[];
    try {
      for (final image in images) {
        clones.add(image.clone());
      }
    } catch (_) {
      for (final clone in clones) {
        clone.dispose();
      }
      rethrow;
    }
    return _fromClones(clones);
  }

  static Future<CharacterTouchHitMask> _fromClones(
    List<ui.Image> clones,
  ) async {
    try {
      final pages = <_AlphaPage>[];
      for (final image in clones) {
        pages.add(await _readPage(image));
      }
      return CharacterTouchHitMask._(List.unmodifiable(pages));
    } finally {
      for (final clone in clones) {
        clone.dispose();
      }
    }
  }

  static Future<_AlphaPage> _readPage(ui.Image source) async {
    final scale = math.min(
      1.0,
      _maximumEdge / math.max(source.width, source.height),
    );
    final width = math.max(1, (source.width * scale).round());
    final height = math.max(1, (source.height * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      source,
      ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()
        ..isAntiAlias = false
        ..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    ui.Image? scaled;
    try {
      scaled = await picture.toImage(width, height);
      final rgba = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) {
        throw StateError('Unable to read character touch alpha mask.');
      }
      final alpha = Uint8List(width * height);
      for (var i = 0; i < alpha.length; i++) {
        alpha[i] = rgba.getUint8(i * 4 + 3);
      }
      return _AlphaPage(width, height, alpha);
    } finally {
      scaled?.dispose();
      picture.dispose();
    }
  }

  bool opaqueAt(int pageIndex, double u, double v) {
    if (pageIndex < 0 ||
        pageIndex >= _pages.length ||
        !u.isFinite ||
        !v.isFinite ||
        u < 0 ||
        u > 1 ||
        v < 0 ||
        v > 1) {
      return false;
    }
    final page = _pages[pageIndex];
    final x = math.min(page.width - 1, (u * page.width).floor());
    final y = math.min(page.height - 1, (v * page.height).floor());
    return page.alpha[y * page.width + x] >= _minimumAlpha;
  }
}

class _AlphaPage {
  const _AlphaPage(this.width, this.height, this.alpha);

  final int width;
  final int height;
  final Uint8List alpha;
}
