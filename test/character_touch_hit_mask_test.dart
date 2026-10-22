import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_touch_hit_mask.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> image(
    int width,
    int height,
    void Function(ui.Canvas) paint,
  ) async {
    final recorder = ui.PictureRecorder();
    paint(ui.Canvas(recorder));
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  test('transparent texels are rejected and visible texels pass', () async {
    final source = await image(8, 4, (canvas) {
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 4, 4),
        ui.Paint()..color = const ui.Color(0xffffffff),
      );
    });
    final pending = CharacterTouchHitMask.fromImages([source]);
    source.dispose();
    final mask = await pending;
    expect(mask.opaqueAt(0, .25, .5), isTrue);
    expect(mask.opaqueAt(0, .75, .5), isFalse);
  });

  test(
    'alpha threshold keeps visible edges and excludes nearly clear pixels',
    () async {
      final source = await image(4, 1, (canvas) {
        for (var i = 0; i < 4; i++) {
          canvas.drawRect(
            ui.Rect.fromLTWH(i.toDouble(), 0, 1, 1),
            ui.Paint()
              ..color = ui.Color.fromARGB([0, 23, 24, 255][i], 255, 255, 255),
          );
        }
      });
      final pending = CharacterTouchHitMask.fromImages([source]);
      source.dispose();
      final mask = await pending;
      expect(mask.opaqueAt(0, .125, .5), isFalse);
      expect(mask.opaqueAt(0, .375, .5), isFalse);
      expect(mask.opaqueAt(0, .625, .5), isTrue);
      expect(mask.opaqueAt(0, .875, .5), isTrue);
    },
  );

  test(
    'UV boundaries map to edge pixels while invalid coordinates fail',
    () async {
      final source = await image(2, 2, (canvas) {
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          ui.Paint()..color = const ui.Color(0xffffffff),
        );
        canvas.drawRect(
          const ui.Rect.fromLTWH(1, 1, 1, 1),
          ui.Paint()..color = const ui.Color(0xffffffff),
        );
      });
      final pending = CharacterTouchHitMask.fromImages([source]);
      source.dispose();
      final mask = await pending;
      expect(mask.opaqueAt(0, 0, 0), isTrue);
      expect(mask.opaqueAt(0, 1, 1), isTrue);
      expect(mask.opaqueAt(0, 1, 0), isFalse);
      expect(mask.opaqueAt(0, 0, 1), isFalse);
      for (final value in [
        -.001,
        1.001,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(mask.opaqueAt(0, value, .5), isFalse);
        expect(mask.opaqueAt(0, .5, value), isFalse);
      }
      expect(mask.opaqueAt(-1, .5, .5), isFalse);
      expect(mask.opaqueAt(1, .5, .5), isFalse);
    },
  );

  test(
    'large non-square pages retain their normalized opaque region',
    () async {
      final source = await image(2048, 512, (canvas) {
        canvas.drawRect(
          const ui.Rect.fromLTWH(512, 128, 1024, 256),
          ui.Paint()..color = const ui.Color(0xffffffff),
        );
      });
      final pending = CharacterTouchHitMask.fromImages([source]);
      source.dispose();
      final mask = await pending;
      expect(mask.opaqueAt(0, .5, .5), isTrue);
      expect(mask.opaqueAt(0, .3, .3), isTrue);
      expect(mask.opaqueAt(0, .1, .5), isFalse);
      expect(mask.opaqueAt(0, .5, .1), isFalse);
      expect(mask.opaqueAt(0, .9, .5), isFalse);
      expect(mask.opaqueAt(0, .5, .9), isFalse);
    },
  );

  test('all pages are cloned before asynchronous generation begins', () async {
    final first = await image(2, 2, (canvas) {
      canvas.drawPaint(ui.Paint()..color = const ui.Color(0xffffffff));
    });
    final second = await image(1, 4, (_) {});
    final third = await image(4, 1, (canvas) {
      canvas.drawRect(
        const ui.Rect.fromLTWH(2, 0, 2, 1),
        ui.Paint()..color = const ui.Color(0xffffffff),
      );
    });
    final pending = CharacterTouchHitMask.fromImages([first, second, third]);
    first.dispose();
    second.dispose();
    third.dispose();
    final mask = await pending;
    expect(mask.opaqueAt(0, .5, .5), isTrue);
    expect(mask.opaqueAt(1, .5, .5), isFalse);
    expect(mask.opaqueAt(2, .25, .5), isFalse);
    expect(mask.opaqueAt(2, .75, .5), isTrue);
    expect(mask.opaqueAt(3, .5, .5), isFalse);
  });

  test('an empty atlas has no opaque samples', () async {
    final mask = await CharacterTouchHitMask.fromImages([]);
    expect(mask.opaqueAt(0, 0, 0), isFalse);
  });
}
