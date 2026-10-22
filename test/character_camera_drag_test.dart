import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';

Widget _scene({
  required bool Function(Offset) start,
  required ValueChanged<Offset> update,
  required VoidCallback end,
  ValueChanged<Offset>? tap,
  ValueChanged<Offset>? gaze,
  VoidCallback? gazeEnd,
  double scale = 1,
  double verticalOffsetFraction = 0,
}) => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 400,
      height: 600,
      child: CharacterCamera(
        initialScale: scale,
        initialVerticalOffsetFraction: verticalOffsetFraction,
        onTap: tap ?? (_) {},
        onGazeChanged: gaze,
        onGazeEnd: gazeEnd,
        onCharacterDragStart: start,
        onCharacterDragUpdate: update,
        onCharacterDragEnd: end,
        child: const ColoredBox(color: Colors.white),
      ),
    ),
  ),
);

void main() {
  testWidgets('movement below touch slop remains a normal interaction tap', (
    tester,
  ) async {
    var starts = 0;
    var ends = 0;
    final taps = <Offset>[];
    final updates = <Offset>[];
    await tester.pumpWidget(
      _scene(
        start: (_) {
          starts++;
          return true;
        },
        update: updates.add,
        end: () => ends++,
        tap: taps.add,
      ),
    );
    final pointer = await tester.startGesture(const Offset(100, 200));
    await pointer.moveBy(const Offset(5, 0));
    await pointer.up();
    expect(starts, 0);
    expect(updates, isEmpty);
    expect(ends, 0);
    expect(taps, [const Offset(105, 200)]);
  });

  testWidgets('captured pull uses camera coordinates and suppresses tap/gaze', (
    tester,
  ) async {
    final starts = <Offset>[];
    final updates = <Offset>[];
    final gaze = <Offset>[];
    var ends = 0;
    var taps = 0;
    await tester.pumpWidget(
      _scene(
        scale: 2,
        verticalOffsetFraction: 0.2,
        start: (position) {
          starts.add(position);
          return true;
        },
        update: updates.add,
        end: () => ends++,
        tap: (_) => taps++,
        gaze: gaze.add,
      ),
    );
    final pointer = await tester.startGesture(const Offset(100, 200));
    await pointer.moveTo(const Offset(200, 200));
    await pointer.moveTo(const Offset(240, 220));
    await pointer.up();
    expect(starts, [const Offset(150, 340)]);
    expect(updates, [const Offset(200, 340), const Offset(220, 350)]);
    expect(gaze, [const Offset(150, 340)]);
    expect(ends, 1);
    expect(taps, 0);
    expect(
      tester
          .widget<Transform>(find.byKey(characterCameraTransformKey))
          .transform
          .getMaxScaleOnAxis(),
      2,
    );
    // A fresh tap immediately after releasing the pull must remain usable.
    await tester.tapAt(const Offset(100, 200));
    expect(taps, 1);
    expect(starts.length, 1);
  });

  testWidgets('a rejected press keeps gaze and never starts at a later point', (
    tester,
  ) async {
    var starts = 0;
    var ends = 0;
    final updates = <Offset>[];
    final gaze = <Offset>[];
    await tester.pumpWidget(
      _scene(
        start: (position) {
          starts++;
          return position.dx > 150;
        },
        update: updates.add,
        end: () => ends++,
        gaze: gaze.add,
      ),
    );
    final pointer = await tester.startGesture(const Offset(100, 200));
    await pointer.moveTo(const Offset(200, 200));
    await pointer.moveTo(const Offset(250, 200));
    await pointer.up();
    expect(starts, 1);
    expect(ends, 0);
    expect(updates, isEmpty);
    expect(gaze.last, const Offset(250, 200));
  });

  testWidgets('second finger releases pull and retains camera pinch', (
    tester,
  ) async {
    var starts = 0;
    var ends = 0;
    final updates = <Offset>[];
    await tester.pumpWidget(
      _scene(
        start: (_) {
          starts++;
          return true;
        },
        update: updates.add,
        end: () => ends++,
      ),
    );
    final first = await tester.startGesture(const Offset(160, 300), pointer: 1);
    await first.moveTo(const Offset(130, 300));
    expect(starts, 1);
    final second = await tester.startGesture(
      const Offset(240, 300),
      pointer: 2,
    );
    expect(ends, 1);
    final pullUpdates = updates.length;
    await first.moveTo(const Offset(80, 300));
    await second.moveTo(const Offset(300, 300));
    await tester.pump();
    expect(updates.length, pullUpdates);
    expect(
      tester
          .widget<Transform>(find.byKey(characterCameraTransformKey))
          .transform
          .getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await second.up();
    await first.moveTo(const Offset(50, 300));
    await first.up();
    expect(starts, 1);
    expect(ends, 1);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('cancel and widget disposal each release a pull exactly once', (
    tester,
  ) async {
    var ends = 0;
    await tester.pumpWidget(
      _scene(start: (_) => true, update: (_) {}, end: () => ends++),
    );
    final first = await tester.startGesture(const Offset(100, 200));
    await first.moveBy(const Offset(40, 0));
    await first.cancel();
    expect(ends, 1);
    final second = await tester.startGesture(const Offset(100, 200));
    await second.moveBy(const Offset(40, 0));
    await tester.pumpWidget(const SizedBox());
    expect(ends, 2);
    await second.cancel();
    expect(ends, 2);
  });

  testWidgets('app background and window focus loss release active pull', (
    tester,
  ) async {
    var ends = 0;
    await tester.pumpWidget(
      _scene(start: (_) => true, update: (_) {}, end: () => ends++),
    );
    final first = await tester.startGesture(const Offset(100, 200));
    await first.moveBy(const Offset(40, 0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(ends, 1);
    await first.up();
    expect(ends, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final second = await tester.startGesture(const Offset(100, 200));
    await second.moveBy(const Offset(40, 0));
    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    expect(ends, 2);
    await second.up();
    expect(ends, 2);
  });

  testWidgets('mouse pull accepts only the primary mouse button', (
    tester,
  ) async {
    var starts = 0;
    var ends = 0;
    await tester.pumpWidget(
      _scene(
        start: (_) {
          starts++;
          return true;
        },
        update: (_) {},
        end: () => ends++,
      ),
    );
    final secondary = await tester.startGesture(
      const Offset(100, 200),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await secondary.moveBy(const Offset(40, 0));
    await secondary.up();
    expect(starts, 0);
    final primary = await tester.startGesture(
      const Offset(100, 200),
      kind: PointerDeviceKind.mouse,
    );
    await primary.moveBy(const Offset(40, 0));
    await primary.up();
    expect(starts, 1);
    expect(ends, 1);
  });

  for (final background in [false, true]) {
    testWidgets(
      'pinch followed by ${background ? 'background' : 'focus loss'} does not leave taps or pulls suppressed',
      (tester) async {
        var starts = 0;
        var ends = 0;
        var taps = 0;
        await tester.pumpWidget(
          _scene(
            start: (_) {
              starts++;
              return true;
            },
            update: (_) {},
            end: () => ends++,
            tap: (_) => taps++,
          ),
        );
        final first = await tester.startGesture(
          const Offset(160, 300),
          pointer: 1,
        );
        final second = await tester.startGesture(
          const Offset(240, 300),
          pointer: 2,
        );
        await first.moveTo(const Offset(80, 300));
        await second.moveTo(const Offset(300, 300));
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        } else {
          tester.binding.handleViewFocusChanged(
            ViewFocusEvent(
              viewId: tester.view.viewId,
              state: ViewFocusState.unfocused,
              direction: ViewFocusDirection.undefined,
            ),
          );
        }
        // ScaleEnd runs after reset, when its pinch flag has already gone.
        await first.up();
        await second.up();
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else {
          tester.binding.handleViewFocusChanged(
            ViewFocusEvent(
              viewId: tester.view.viewId,
              state: ViewFocusState.focused,
              direction: ViewFocusDirection.undefined,
            ),
          );
        }
        await tester.tapAt(const Offset(100, 200));
        expect(taps, 0, reason: 'The brief trailing-tap guard remains active.');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tapAt(const Offset(100, 200));
        expect(taps, 1);
        final drag = await tester.startGesture(const Offset(100, 200));
        await drag.moveBy(const Offset(40, 0));
        await drag.up();
        expect(starts, 1);
        expect(ends, 1);
        expect(taps, 1);
      },
    );
  }

  testWidgets('two-finger tap does not block the next tap or single pull', (
    tester,
  ) async {
    var starts = 0;
    var ends = 0;
    var taps = 0;
    await tester.pumpWidget(
      _scene(
        start: (_) {
          starts++;
          return true;
        },
        update: (_) {},
        end: () => ends++,
        tap: (_) => taps++,
      ),
    );
    final first = await tester.startGesture(const Offset(160, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(240, 300),
      pointer: 2,
    );
    await first.up();
    await second.up();
    expect(taps, 0);
    await tester.tapAt(const Offset(100, 200));
    expect(taps, 0);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(const Offset(100, 200));
    expect(taps, 1);
    final drag = await tester.startGesture(const Offset(100, 200));
    await drag.moveBy(const Offset(40, 0));
    await drag.up();
    expect(starts, 1);
    expect(ends, 1);
    expect(taps, 1);
  });
}
