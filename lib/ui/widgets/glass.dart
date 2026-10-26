import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';

/// Fond sombre avec deux lueurs de couleur.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key});

  Widget _blob(Color c, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [c.withAlpha(70), c.withAlpha(0)]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Palette.bg),
        Positioned(top: -140, left: -100, child: _blob(Palette.accent, 420)),
        Positioned(bottom: -160, right: -120, child: _blob(Palette.accent2, 400)),
        Positioned(bottom: 120, left: -160, child: _blob(Palette.sunset, 300)),
      ],
    );
  }
}

/// Carte translucide.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(16),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withAlpha(28)),
      ),
      child: child,
    );
  }
}

/// Bouton qui signale l'appui ET le relâchement (indispensable pour les jeux).
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onKey,
    this.width,
    this.height = 48,
    this.circle = false,
    this.fontSize = 16,
  });

  final String label;
  final ValueChanged<bool> onKey;
  final double? width;
  final double height;
  final bool circle;
  final double fontSize;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
    if (v) HapticFeedback.lightImpact();
    widget.onKey(v);
  }

  @override
  void dispose() {
    if (_down) widget.onKey(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.circle ? widget.height : widget.width;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.94 : 1,
        duration: const Duration(milliseconds: 70),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 70),
          width: w,
          height: widget.height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: widget.circle ? null : BorderRadius.circular(widget.height / 2),
            color: _down ? Palette.accent.withAlpha(200) : Colors.white.withAlpha(18),
            border: Border.all(
              color: _down ? Palette.accent : Colors.white.withAlpha(34),
            ),
            boxShadow: _down
                ? [BoxShadow(color: Palette.accent.withAlpha(120), blurRadius: 18)]
                : const [],
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w600,
              color: Palette.text,
            ),
          ),
        ),
      ),
    );
  }
}
