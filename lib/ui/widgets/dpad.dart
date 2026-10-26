import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../j2me/key_codes.dart';
import '../../theme.dart';

/// Croix directionnelle : on peut glisser le doigt d'une direction à l'autre,
/// les diagonales activent deux touches, le centre fait « OK ».
class DPad extends StatefulWidget {
  const DPad({super.key, required this.onKey, this.size = 190});

  final void Function(J2meKey key, bool down) onKey;
  final double size;

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

    if (dist <= r * 1.3) {
      if (dist < r * 0.3) {
        next.add(J2meKey.fire);
      } else {
        final n = v / dist;
        if (n.dy < -0.38) next.add(J2meKey.up);
        if (n.dy > 0.38) next.add(J2meKey.down);
        if (n.dx < -0.38) next.add(J2meKey.left);
        if (n.dx > 0.38) next.add(J2meKey.right);
      }
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
    if (added.isNotEmpty) HapticFeedback.selectionClick();
    if (added.isNotEmpty || removed.isNotEmpty) {
      setState(() => _active = next);
    }
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
        if (e.pointer != _pointer) return;
        _pointer = null;
        _apply({});
      },
      onPointerCancel: (e) {
        if (e.pointer != _pointer) return;
        _pointer = null;
        _apply({});
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

    // Socle.
    canvas.drawCircle(
      c,
      r - 2,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          colors: [Color(0xFF2A2142), Color(0xFF110C20)],
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

    // Flèches.
    const arrows = <(J2meKey, double)>[
      (J2meKey.up, 0),
      (J2meKey.right, math.pi / 2),
      (J2meKey.down, math.pi),
      (J2meKey.left, -math.pi / 2),
    ];
    for (final (key, angle) in arrows) {
      final on = active.contains(key);
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(angle);

      final at = Offset(0, -r * 0.64);
      if (on) {
        canvas.drawCircle(
          at,
          r * 0.2,
          Paint()
            ..color = Palette.accent.withAlpha(150)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
        );
      }
      final w = r * 0.13;
      final h = r * 0.12;
      final path = Path()
        ..moveTo(at.dx - w, at.dy + h / 2)
        ..lineTo(at.dx, at.dy - h / 2)
        ..lineTo(at.dx + w, at.dy + h / 2);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = on ? Colors.white : Colors.white.withAlpha(140),
      );
      canvas.restore();
    }

    // Bouton central.
    final fire = active.contains(J2meKey.fire);
    if (fire) {
      canvas.drawCircle(
        c,
        r * 0.3,
        Paint()
          ..color = Palette.accent.withAlpha(170)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
      );
    }
    canvas.drawCircle(
      c,
      r * 0.26,
      Paint()..color = fire ? Palette.accent : Colors.white.withAlpha(20),
    );
    canvas.drawCircle(
      c,
      r * 0.26,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withAlpha(fire ? 120 : 40),
    );
  }

  @override
  bool shouldRepaint(_DPadPainter old) => old.active != active;
}
