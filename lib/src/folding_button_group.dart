import 'package:flutter/material.dart';

/// Buttons drift in from the nearest screen edge, retaining their final rows.
class FoldingButtonGroup extends StatelessWidget {
  const FoldingButtonGroup({
    super.key,
    required this.expanded,
    required this.fromRight,
    required this.children,
  });

  final bool expanded;
  final bool fromRight;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    // These 48px buttons sit 12–16px from the edge. Include safe-area padding
    // so the starting position remains off-screen in landscape as well.
    final travel = 96.0 + (fromRight ? padding.right : padding.left);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: expanded ? 1 : 0),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Duration(milliseconds: expanded ? 420 : 280),
      builder: (context, progress, _) {
        return IgnorePointer(
          ignoring: !expanded,
          child: ExcludeSemantics(
            excluding: !expanded,
            child: Align(
              alignment: Alignment.topCenter,
              widthFactor: 1,
              heightFactor: progress == 0 ? 0 : 1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < children.length; index++)
                    _buildItem(index, progress, travel),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildItem(int index, double progress, double travel) {
    final delay = children.length < 2
        ? 0.0
        : .3 * index / (children.length - 1);
    final value = Curves.easeOutCubic.transform(
      ((progress - delay) / (1 - delay)).clamp(0.0, 1.0),
    );
    return IgnorePointer(
      ignoring: value < 1,
      child: ExcludeSemantics(
        excluding: value < 1,
        child: Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset((fromRight ? travel : -travel) * (1 - value), 0),
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: children[index],
            ),
          ),
        ),
      ),
    );
  }
}
