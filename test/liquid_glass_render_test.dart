import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/liquid_glass_optics.dart';

const _captureKey = ValueKey('glass-render-capture');
const _markerColor = Color(0xFFFFE400);

class _ColourBackdrop extends CustomPainter {
  const _ColourBackdrop();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width / 2, size.height),
      Paint()..color = const Color(0xFFFF2A5A),
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height),
      Paint()..color = const Color(0xFF0FDEE6),
    );
  }

  @override
  bool shouldRepaint(_ColourBackdrop oldDelegate) => false;
}

Widget _scene({bool enabled = true, GlassTone? tone}) => Stack(
  fit: StackFit.expand,
  children: [
    const CustomPaint(painter: _ColourBackdrop()),
    Positioned.fill(
      left: 24,
      right: 24,
      top: 24,
      bottom: 24,
      child: GlassSurface(
        liquidGlass: enabled,
        tone: tone,
        fallbackColor: const Color(0xB83B3F45),
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Positioned(
              top: 24,
              left: 20,
              child: Text(
                'Clear glass · 当前角色',
                style: TextStyle(
                  color: tone == GlassTone.dark ? Colors.white : null,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Positioned(
              left: 150,
              top: 60,
              width: 32,
              height: 22,
              child: ColoredBox(color: _markerColor),
            ),
          ],
        ),
      ),
    ),
  ],
);

Future<void> _mount(
  WidgetTester tester, {
  required Brightness brightness,
  bool enabled = true,
  GlassTone? tone,
}) async {
  tester.view.physicalSize = const Size(420, 260);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: atelierTheme(AppAccentTheme.jade, brightness),
      home: RepaintBoundary(
        key: _captureKey,
        child: _scene(enabled: enabled, tone: tone),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<ui.Image> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  return (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
}

List<int> _pixel(ByteData bytes, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return List.generate(4, (channel) => bytes.getUint8(offset + channel));
}

Future<ByteData> _rgba(WidgetTester tester, ui.Image image) async =>
    (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final backdrop in [Colors.black, Colors.white]) {
      testWidgets('text glass has readable contrast $brightness $backdrop', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: atelierTheme(AppAccentTheme.jade, brightness),
            home: RepaintBoundary(
              key: _captureKey,
              child: ColoredBox(
                color: backdrop,
                child: Center(
                  child: GlassSurface(
                    liquidGlass: true,
                    readableText: true,
                    tone: GlassTone.dark,
                    child: const SizedBox(width: 280, height: 220),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final image = await _capture(tester);
        final pixels = await _rgba(tester, image);
        final bounds = tester.getRect(find.byType(GlassSurface));
        for (final point in [
          bounds.center,
          bounds.topLeft + const Offset(24, 24),
        ]) {
          final rgba = _pixel(
            pixels,
            image.width,
            point.dx.toInt(),
            point.dy.toInt(),
          );
          final surface = Color.fromARGB(rgba[3], rgba[0], rgba[1], rgba[2]);
          for (final foreground in [Colors.white, Colors.white70]) {
            final text = Color.alphaBlend(foreground, surface);
            final ratio =
                (text.computeLuminance() + .05) /
                (surface.computeLuminance() + .05);
            expect(ratio, greaterThanOrEqualTo(4.5));
          }
        }
        image.dispose();
      });
    }
  }

  testWidgets('tint and sheen compose separately over a black backdrop', (
    tester,
  ) async {
    for (final opacity in [1.0, .65]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: atelierTheme(AppAccentTheme.jade, Brightness.light),
          home: RepaintBoundary(
            key: _captureKey,
            child: ColoredBox(
              color: Colors.black,
              child: Center(
                child: GlassSurface(
                  liquidGlass: true,
                  backdropBlur: false,
                  fillOpacity: opacity,
                  child: const SizedBox(width: 200, height: 160),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final image = await _capture(tester);
      final data = await _rgba(tester, image);
      final colour = _pixel(
        data,
        image.width,
        image.width ~/ 2,
        image.height ~/ 2,
      );
      // Multiplying the tint and gradient alphas paints only a few grey levels
      // here; drawing them as distinct layers retains the intended tint.
      for (final channel in colour.take(3)) {
        expect(channel, greaterThan(opacity == 1 ? 48 : 30));
      }
      expect(colour[3], 255);
      image.dispose();
    }
  });

  for (final entry in [
    (Brightness.light, null),
    (Brightness.dark, null),
    (Brightness.light, GlassTone.dark),
  ]) {
    testWidgets('glass retains backdrop colour and crisp foreground $entry', (
      tester,
    ) async {
      await _mount(tester, brightness: entry.$1, tone: entry.$2);
      final image = await _capture(tester);
      addTearDown(image.dispose);
      final data = await _rgba(tester, image);
      final red = _pixel(data, image.width, 80, 180);
      final cyan = _pixel(data, image.width, 300, 180);
      expect(red[0], greaterThan(170));
      expect(red[0] - red[1], greaterThan(80));
      expect(cyan[1], greaterThan(140));
      expect(cyan[2], greaterThan(140));
      expect(red[3], 255);
      expect(cyan[3], 255);
      // Backdrop tint and glints must not move or tint foreground pixels.
      for (final point in [
        const Offset(174, 84),
        const Offset(190, 95),
        const Offset(205, 105),
      ]) {
        final marker = _pixel(
          data,
          image.width,
          point.dx.toInt(),
          point.dy.toInt(),
        );
        expect(marker, [255, 228, 0, 255]);
      }
      expect(_pixel(data, image.width, 173, 95)[2], greaterThan(30));
      expect(_pixel(data, image.width, 206, 95)[2], greaterThan(30));
      expect(find.text('Clear glass · 当前角色'), findsOneWidget);
      expect(find.byType(LiquidGlassOptics), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets('glass disabled preserves the existing grey fallback', (
    tester,
  ) async {
    await _mount(tester, brightness: Brightness.light, enabled: false);
    final image = await _capture(tester);
    addTearDown(image.dispose);
    final data = await _rgba(tester, image);
    expect(
      tester.widget<LiquidGlassOptics>(find.byType(LiquidGlassOptics)).enabled,
      isFalse,
    );
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isFalse,
    );
    final red = _pixel(data, image.width, 80, 180);
    expect(red[0], lessThan(150));
    expect(red[1], greaterThan(35));
    expect(red[3], 255);
    expect(_pixel(data, image.width, 190, 95), [255, 228, 0, 255]);
  });

  testWidgets(
    'glass supports intrinsic dialog layout and settles after touch',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    backgroundColor: Colors.transparent,
                    child: GlassSurface(
                      liquidGlass: true,
                      child: IntrinsicWidth(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Memory recovery'),
                              TextButton(
                                onPressed: () {},
                                child: const Text('Continue'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Memory recovery'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Continue'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lightweight glass keeps the backdrop filter free of runtime shaders',
    (tester) async {
      await _mount(tester, brightness: Brightness.light);
      final filters = tester.widgetList<BackdropFilter>(
        find.byType(BackdropFilter),
      );
      expect(filters, isNotEmpty);
      expect(
        filters.every((filter) => !filter.filter.toString().contains('shader')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('export both glass themes over a colourful scene', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(840, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: _captureKey,
          child: Row(
            children: [
              for (final brightness in [Brightness.light, Brightness.dark])
                Expanded(
                  child: Theme(
                    data: atelierTheme(AppAccentTheme.jade, brightness),
                    child: _scene(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final image = await _capture(tester);
    final png = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    ))!;
    await tester.runAsync(() async {
      final folder = Directory('build/glass-preview');
      await folder.create(recursive: true);
      await File('${folder.path}/light-dark.png').writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    });
    image.dispose();
  });
}
