import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';

/// Bouton de jeu : signale l'appui ET le relâchement (indispensable pour les
/// jeux, qui lisent les touches maintenues).
///
/// Volontairement en Flutter pur : un CNButton natif ne fournit qu'un « tap »
/// (onPressed), sans appui/relâchement séparés, et une vue native peut
/// absorber les touches avant Flutter.
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onKey,
    this.width,
    this.height = 48,
    this.circle = false,
    this.fontSize = 16,
    this.hapticsEnabled = true,
  });

  final String label;
  final ValueChanged<bool> onKey;
  final double? width;
  final double height;
  final bool circle;
  final double fontSize;
  final bool hapticsEnabled;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
    if (v && widget.hapticsEnabled) HapticFeedback.lightImpact();
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
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _down
                  ? [Palette.accent, Palette.accent2]
                  : [Palette.surfaceRaised, Palette.surface],
            ),
            border: Border.all(
              color: _down ? Palette.accent : Palette.outline,
            ),
            boxShadow: _down
                ? [
                    BoxShadow(
                      color: Palette.accent.withAlpha(65),
                      blurRadius: 18,
                    ),
                  ]
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
