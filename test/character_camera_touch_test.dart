import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';

Widget _scene({
  ValueChanged<CharacterTouchSample>? start,
  ValueChanged<CharacterTouchSample>? move,
  VoidCallback? end,
  ValueChanged<Offset>? tap,
  bool Function(Offset)? dragStart,
  ValueChanged<Offset>? dragUpdate,
  VoidCallback? dragEnd,
  double scale = 1,
  double verticalOffsetFraction = 0,
  double width = 400,
  double height = 600,
  bool keepSceneProportions = false,
}) => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: width,
      height: height,
      child: CharacterCamera(
        initialScale: scale,
        initialVerticalOffsetFraction: verticalOffsetFraction,
        keepSceneProportions: keepSceneProportions,
        onTap: tap ?? (_) {},
        onCharacterTouchStart: start,
        onCharacterTouchMove: move,
        onCharacterTouchEnd: end,
        onCharacterDragStart: dragStart,
        onCharacterDragUpdate: dragUpdate,
        onCharacterDragEnd: dragEnd,
        child: const ColoredBox(color: Colors.white),
      ),
    ),
  ),
);

void main() {
  testWidgets('down and sub-slop motion sample without consuming a tap', (
    tester,
  ) async {
    final starts = <CharacterTouchSample>[];
    final moves = <CharacterTouchSample>[];
    final taps = <Offset>[];
    var ends = 0;
    await tester.pumpWidget(
      _scene(
        start: starts.add,
        move: moves.add,
        end: () => ends++,
        tap: taps.add,
      ),
    );
    final pointer = await tester.createGesture();
    await pointer.down(
      const Offset(100, 200),
      timeStamp: const Duration(seconds: 2),
    );
    expect(starts.single.position, const Offset(100, 200));
    expect(starts.single.timeStamp, const Duration(seconds: 2));
    expect(starts.single.velocity, Offset.zero);
    await pointer.moveBy(
      const Offset(4, 6),
      timeStamp: const Duration(milliseconds: 2020),
    );
    expect(moves.single.position, const Offset(104, 206));
    expect(moves.single.velocity.dx, closeTo(0.5, 1e-9));
    expect(moves.single.velocity.dy, closeTo(0.5, 1e-9));
    await pointer.up();
    expect(ends, 1);
    expect(taps, [const Offset(104, 206)]);
  });

  testWidgets('speed uses pointer timestamps rather than frame or wall time', (
    tester,
  ) async {
    final moves = <CharacterTouchSample>[];
    await tester.pumpWidget(_scene(start: (_) {}, move: moves.add));
    final pointer = await tester.createGesture();
    await pointer.down(const Offset(100, 200));
    await tester.pump(const Duration(seconds: 4));
    await pointer.moveBy(
      const Offset(40, 60),
      timeStamp: const Duration(milliseconds: 20),
    );
    expect(moves.last.velocity, const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 1));
    await pointer.moveBy(
      const Offset(40, 60),
      timeStamp: const Duration(milliseconds: 60),
    );
    expect(moves.last.velocity, const Offset(2.5, 2.5));
    await pointer.up();
  });

  testWidgets(
    'long hold and invalid timestamps establish a fresh speed baseline',
    (tester) async {
      final moves = <CharacterTouchSample>[];
      await tester.pumpWidget(_scene(start: (_) {}, move: moves.add));
      final pointer = await tester.createGesture();
      await pointer.down(const Offset(100, 200));
      await pointer.moveBy(
        const Offset(100, 0),
        timeStamp: const Duration(seconds: 4),
      );
      expect(moves.last.velocity, Offset.zero);
      await pointer.moveBy(
        const Offset(4, 6),
        timeStamp: const Duration(milliseconds: 4020),
      );
      expect(moves.last.velocity, const Offset(0.5, 0.5));
      await pointer.moveBy(
        const Offset(4, 6),
        timeStamp: const Duration(milliseconds: 4020),
      );
      expect(moves.last.velocity, Offset.zero);
      await pointer.moveBy(
        const Offset(4, 6),
        timeStamp: const Duration(milliseconds: 4000),
      );
      expect(moves.last.velocity, Offset.zero);
      await pointer.up();
    },
  );

  testWidgets(
    'camera scale and vertical offset are removed from position and speed',
    (tester) async {
      final starts = <CharacterTouchSample>[];
      final moves = <CharacterTouchSample>[];
      await tester.pumpWidget(
        _scene(
          scale: 2,
          verticalOffsetFraction: 0.2,
          start: starts.add,
          move: moves.add,
        ),
      );
      final pointer = await tester.createGesture();
      await pointer.down(const Offset(100, 200));
      expect(starts.single.position, const Offset(150, 340));
      await pointer.moveBy(
        const Offset(40, 60),
        timeStamp: const Duration(milliseconds: 20),
      );
      expect(moves.single.position, const Offset(170, 370));
      expect(moves.single.velocity, const Offset(2.5, 2.5));
      await pointer.up();
    },
  );

  testWidgets('fitted scene resizing preserves normalized physical speed', (
    tester,
  ) async {
    final starts = <CharacterTouchSample>[];
    final moves = <CharacterTouchSample>[];
    await tester.pumpWidget(
      _scene(start: starts.add, move: moves.add, keepSceneProportions: true),
    );
    await tester.pumpWidget(
      _scene(
        width: 200,
        height: 300,
        start: starts.add,
        move: moves.add,
        keepSceneProportions: true,
      ),
    );
    final pointer = await tester.createGesture();
    await pointer.down(const Offset(100, 150));
    expect(starts.single.position, const Offset(200, 300));
    await pointer.moveBy(
      const Offset(4, 6),
      timeStamp: const Duration(milliseconds: 20),
    );
    expect(moves.single.position, const Offset(208, 312));
    expect(moves.single.velocity, const Offset(1, 1));
    await pointer.up();
  });

  testWidgets('touch samples continue while cheek drag captures the gesture', (
    tester,
  ) async {
    final moves = <CharacterTouchSample>[];
    final drags = <Offset>[];
    var ends = 0;
    var dragEnds = 0;
    var taps = 0;
    await tester.pumpWidget(
      _scene(
        start: (_) {},
        move: moves.add,
        end: () => ends++,
        dragStart: (_) => true,
        dragUpdate: drags.add,
        dragEnd: () => dragEnds++,
        tap: (_) => taps++,
      ),
    );
    final pointer = await tester.createGesture();
    await pointer.down(const Offset(100, 200));
    await pointer.moveBy(
      const Offset(4, 0),
      timeStamp: const Duration(milliseconds: 10),
    );
    expect(moves, hasLength(1));
    expect(drags, isEmpty);
    await pointer.moveBy(
      const Offset(40, 0),
      timeStamp: const Duration(milliseconds: 20),
    );
    await pointer.moveBy(
      const Offset(10, 0),
      timeStamp: const Duration(milliseconds: 30),
    );
    expect(moves, hasLength(3));
    expect(drags, [const Offset(144, 200), const Offset(154, 200)]);
    await pointer.up();
    expect(ends, 1);
    expect(dragEnds, 1);
    expect(taps, 0);
  });

  testWidgets(
    'pinch ends sampling once and cannot restart in the same gesture',
    (tester) async {
      var starts = 0;
      var ends = 0;
      final moves = <CharacterTouchSample>[];
      await tester.pumpWidget(
        _scene(start: (_) => starts++, move: moves.add, end: () => ends++),
      );
      final first = await tester.createGesture(pointer: 1);
      final second = await tester.createGesture(pointer: 2);
      await first.down(const Offset(160, 300));
      await second.down(const Offset(240, 300));
      expect(starts, 1);
      expect(ends, 1);
      await first.moveBy(
        const Offset(-50, 0),
        timeStamp: const Duration(milliseconds: 20),
      );
      await second.moveBy(
        const Offset(50, 0),
        timeStamp: const Duration(milliseconds: 20),
      );
      await tester.pump();
      expect(moves, isEmpty);
      expect(
        tester
            .widget<Transform>(find.byKey(characterCameraTransformKey))
            .transform
            .getMaxScaleOnAxis(),
        greaterThan(1),
      );
      await second.up();
      await first.moveBy(
        const Offset(-10, 0),
        timeStamp: const Duration(milliseconds: 40),
      );
      expect(moves, isEmpty);
      await first.up();
      expect(ends, 1);
      await tester.pump(const Duration(milliseconds: 300));
      final next = await tester.createGesture(pointer: 3);
      await next.down(const Offset(100, 200));
      expect(starts, 2);
      await next.up();
      expect(ends, 2);
    },
  );

  testWidgets(
    'cancel disposal and disabling callbacks release each session once',
    (tester) async {
      var ends = 0;
      await tester.pumpWidget(
        _scene(start: (_) {}, move: (_) {}, end: () => ends++),
      );
      final first = await tester.createGesture();
      await first.down(const Offset(100, 200));
      await first.cancel();
      expect(ends, 1);
      final second = await tester.createGesture();
      await second.down(const Offset(100, 200));
      await tester.pumpWidget(_scene(start: (_) {}, end: () => ends++));
      expect(ends, 2);
      await second.up();
      expect(ends, 2);
      await tester.pumpWidget(
        _scene(start: (_) {}, move: (_) {}, end: () => ends++),
      );
      final third = await tester.createGesture();
      await third.down(const Offset(100, 200));
      await tester.pumpWidget(const SizedBox());
      expect(ends, 3);
      await third.cancel();
      expect(ends, 3);
    },
  );

  testWidgets('background and focus loss stop samples even before drag slop', (
    tester,
  ) async {
    var ends = 0;
    final moves = <CharacterTouchSample>[];
    await tester.pumpWidget(
      _scene(start: (_) {}, move: moves.add, end: () => ends++),
    );
    final first = await tester.createGesture();
    await first.down(const Offset(100, 200));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(ends, 1);
    await first.moveBy(
      const Offset(4, 0),
      timeStamp: const Duration(milliseconds: 20),
    );
    expect(moves, isEmpty);
    await first.up();
    expect(ends, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final second = await tester.createGesture();
    await second.down(const Offset(100, 200));
    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    expect(ends, 2);
    await second.moveBy(
      const Offset(4, 0),
      timeStamp: const Duration(milliseconds: 20),
    );
    await second.up();
    expect(moves, isEmpty);
    expect(ends, 2);
  });

  testWidgets('only primary touch and mouse presses start sampling', (
    tester,
  ) async {
    var starts = 0;
    var ends = 0;
    await tester.pumpWidget(
      _scene(start: (_) => starts++, move: (_) {}, end: () => ends++),
    );
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.stylus]) {
      final pointer = await tester.createGesture(
        kind: kind,
        buttons: kSecondaryButton,
      );
      await pointer.down(const Offset(100, 200));
      await pointer.moveBy(
        const Offset(40, 0),
        timeStamp: const Duration(milliseconds: 20),
      );
      await pointer.up();
    }
    expect(starts, 0);
    final primary = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await primary.down(const Offset(100, 200));
    await primary.up();
    expect(starts, 1);
    expect(ends, 1);
  });
}
