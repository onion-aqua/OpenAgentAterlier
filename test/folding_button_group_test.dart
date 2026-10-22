import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/folding_button_group.dart';

void main() {
  testWidgets('fold animates both ways without moving its horizontal anchor', (
    tester,
  ) async {
    var expanded = false;
    var taps = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Stack(
              children: [
                Positioned(
                  left: 16,
                  top: 64,
                  child: FoldingButtonGroup(
                    fromRight: false,
                    expanded: expanded,
                    children: List.generate(
                      3,
                      (index) => SizedBox.square(
                        dimension: 48,
                        child: IconButton(
                          tooltip: 'item $index',
                          onPressed: () => taps++,
                          icon: const Icon(Icons.star),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    final group = find.byType(FoldingButtonGroup);
    expect(tester.getSize(group), const Size(48, 0));
    expect(tester.getTopRight(find.byTooltip('item 0')).dx, lessThan(0));
    update(() => expanded = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getSize(group).height, 168);
    expect(tester.getTopLeft(find.byTooltip('item 0')).dx, lessThan(16));
    expect(tester.getTopLeft(find.byTooltip('item 0')).dy, 72);
    final fades = tester
        .widgetList<Opacity>(
          find.descendant(of: group, matching: find.byType(Opacity)),
        )
        .toList();
    expect(fades.first.opacity, greaterThan(fades.last.opacity));
    await tester.pumpAndSettle();
    expect(tester.getSize(group), const Size(48, 168));
    expect(tester.getTopLeft(group).dx, 16);
    await tester.tap(find.byTooltip('item 0'));
    expect(taps, 1);
    update(() => expanded = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getSize(group).height, 168);
    await tester.tapAt(const Offset(40, 85));
    expect(taps, 1);
    // Reverse an unfinished close without jumping to a fully closed menu.
    final before = tester.getSize(group).height;
    update(() => expanded = true);
    await tester.pump();
    expect(tester.getSize(group).height, before);
    await tester.pumpAndSettle();
    expect(tester.getSize(group).height, 168);
    update(() => expanded = false);
    await tester.pumpAndSettle();
    expect(tester.getSize(group).height, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right tools enter from beyond the right screen edge', (
    tester,
  ) async {
    var expanded = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Stack(
              children: [
                Positioned(
                  right: 12,
                  top: 126,
                  child: FoldingButtonGroup(
                    expanded: expanded,
                    fromRight: true,
                    children: const [
                      SizedBox(key: ValueKey('tool'), width: 48, height: 48),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    final tool = find.byKey(const ValueKey('tool'));
    expect(tester.getTopLeft(tool).dx, greaterThan(800));
    update(() => expanded = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getTopLeft(tool).dx, greaterThan(740));
    expect(tester.getTopLeft(tool).dy, 134);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(tool), const Offset(740, 134));
    expect(tester.takeException(), isNull);
  });
}
