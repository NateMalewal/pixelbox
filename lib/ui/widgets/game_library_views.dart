import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef LibraryCoverBuilder = Widget Function(
  BuildContext context,
  int index,
  double width,
  VoidCallback onTap,
);

/// A single animated game shelf, with one selected game kept in the center.
class GameShelf extends StatefulWidget {
  const GameShelf({
    super.key,
    required this.itemCount,
    required this.selectedIndex,
    required this.onSelected,
    required this.itemBuilder,
  });

  final int itemCount;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final LibraryCoverBuilder itemBuilder;

  @override
  State<GameShelf> createState() => _GameShelfState();
}

class _GameShelfState extends State<GameShelf> {
  late final PageController _controller = PageController(
    initialPage: widget.selectedIndex,
    viewportFraction: 0.34,
  );

  @override
  void didUpdateWidget(covariant GameShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex &&
        _controller.hasClients) {
      _controller.animateToPage(
        widget.selectedIndex,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _move(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta) {
    final next = (widget.selectedIndex + delta).clamp(0, widget.itemCount - 1);
    if (next == widget.selectedIndex) return;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.itemCount,
        onPageChanged: widget.onSelected,
        physics: const BouncingScrollPhysics(),
        clipBehavior: Clip.none,
        itemBuilder: (context, index) => LayoutBuilder(
          builder: (context, constraints) {
            final coverWidth = math.min(
              constraints.maxWidth * 0.96,
              constraints.maxHeight * 0.62,
            );
            return AnimatedBuilder(
              animation: _controller,
              child: widget.itemBuilder(
                context,
                index,
                coverWidth,
                () => widget.onSelected(index),
              ),
              builder: (context, child) {
                final page = _controller.hasClients
                    ? (_controller.page ?? widget.selectedIndex.toDouble())
                    : widget.selectedIndex.toDouble();
                final offset = index - page;
                final distance = offset.abs().clamp(0.0, 2.0);
                final scale = 1.2 - distance * 0.19;
                return Center(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 100),
                    opacity: (1 - distance * 0.14).clamp(0.62, 1.0),
                    child: Transform.translate(
                      offset: Offset(0, distance * 15),
                      child: Transform.rotate(
                        angle: offset * 0.025,
                        child: Transform.scale(
                          scale: scale,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
