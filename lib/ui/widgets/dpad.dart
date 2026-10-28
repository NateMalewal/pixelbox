import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../j2me/key_codes.dart';
import '../../theme.dart';

class DPad extends StatefulWidget {
  const DPad({
    super.key,
    required this.onKey,
    this.size = 190,
    this.hapticsEnabled = true,
  });

  final void Function(J2meKey key, bool down) onKey;
  final double size;
  final bool hapticsEnabled;

  @override
  State<DPad> createState() => _DPadState();
}

class _DPadState extends State<DPad> {
  Set<J2meKey> _active = {};
  int? _pointer;

  void _update(Offset p) {
    final r = widget.size / 2;
    final v = p - Offset(r, r);
    final dist = v.distance;
    final next = <J2meKey>{};

    if (dist > r * 0.95 || dist < r * 0.12) {
      _apply(next);
      return;
    }

    final angle = math.atan2(v.dy, v.dx);
    final sector = ((angle / (math.pi / 4)).round() + 8) % 8;

    switch (sector) {
      case 0:
        next.add(J2meKey.right);
      case 1:
        next.add(J2meKey.num9);
      case 2:
        next.add(J2meKey.down);
      case 3:
        next.add(J2meKey.num7);
      case 4:
        next.add(J2meKey.left);
      case 5:
        next.add(J2meKey.num1);
      case 6:
        next.add(J2meKey.up);
      case 7:
        next.add(J2meKey.num3);
    }

    _apply(next);
  }

  void _apply(Set<J2meKey> next) {
    final added = next.difference(_active);
    final removed = _active.difference(next);

    for (final k in removed) {
      widget.onKey(k, false);
    }
    for (final k in added) {
      widget.onKey(k, true);
    }

    if (added.isNotEmpty && widget.hapticsEnabled) {
      HapticFeedback.selectionClick();
    }

    if (added.isNotEmpty || removed.isNotEmpty) {
      setState(() => _active = next);
    }
  }

  void _release() {
    _pointer = null;
    _apply({});
  }

  @override
  void dispose() {
    for (final k in _active) {
      widget.onKey(k, false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        if (_pointer != null) return;
        _pointer = e.pointer;
        _update(e.localPosition);
      },
      onPointerMove: (e) {
        if (e.pointer == _pointer) _update(e.localPosition);
      },
      onPointerUp: (e) {
        if (e.pointer == _pointer) _release();
      },
      onPointerCancel: (e) {
        if (e.pointer == _pointer) _release();
      },
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _DPadPainter(_active),
      ),
    );
  }
}

class _DPadPainter extends CustomPainter {
  _DPadPainter(this.active);

  final Set<J2meKey> active;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    canvas.drawCircle(
      c,
      r - 2,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          colors: [Palette.surfaceRaised, Palette.bg],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    canvas.drawCircle(
      c,
      r - 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withAlpha(36),
    );

    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final key = switch (i) {
        0 => J2meKey.right,
        1 => J2meKey.num9,
        2 => J2meKey.down,
        3 => J2meKey.num7,
        4 => J2meKey.left,
        5 => J2meKey.num1,
        6 => J2meKey.up,
        _ => J2meKey.num3,
      };
      final on = active.contains(key);

      final center = c + direction * (r * 0.58);
      if (on) {
        canvas.drawCircle(
          center,
          r * 0.15,
          Paint()
            ..color = Palette.accent.withAlpha(150)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
        );
      }

      if (i.isOdd) {
        final number = switch (i) { 1 => '9', 3 => '7', 5 => '1', _ => '3' };
        final label = TextPainter(
          text: TextSpan(
            text: number,
            style: TextStyle(
              color: on ? Colors.white : Colors.white.withAlpha(150),
              fontSize: r * 0.18,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, center - Offset(label.width / 2, label.height / 2));
      } else {
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(angle + math.pi / 2);

        final path = Path()
          ..moveTo(0, -r * 0.12)
          ..lineTo(-r * 0.10, r * 0.08)
          ..lineTo(r * 0.10, r * 0.08)
          ..close();

        canvas.drawPath(
          path,
          Paint()..color = on ? Colors.white : Colors.white.withAlpha(135),
        );
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_DPadPainter old) => old.active != active;
}
