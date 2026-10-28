import 'package:flutter/cupertino.dart' show CupertinoThemeData;
import 'package:flutter/material.dart';

/// Palette console sombre PixelBox.
class Palette {
  static const bg = Color(0xFF070B14);
  static const surface = Color(0xFF111A2A);
  static const surfaceRaised = Color(0xFF17243A);
  static const accent = Color(0xFF62D8FF);
  static const accent2 = Color(0xFF8EA3FF);
  static const sunset = Color(0xFFFFB86B);
  static const blood = Color(0xFFFF657A);
  static const text = Color(0xFFF5F8FF);
  static const muted = Color(0xFF94A2BA);
  static const outline = Color(0xFF26364F);
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Palette.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: Palette.accent,
      secondary: Palette.accent2,
      surface: Palette.surface,
      error: Palette.blood,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: Palette.text,
      elevation: 0,
      centerTitle: false,
    ),
    dividerColor: Palette.outline,
    iconTheme: const IconThemeData(color: Palette.text),
    sliderTheme: SliderThemeData(
      activeTrackColor: Palette.accent,
      inactiveTrackColor: Palette.outline,
      thumbColor: Palette.text,
      overlayColor: Palette.accent.withAlpha(35),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Palette.bg
            : Palette.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Palette.accent
            : Palette.outline,
      ),
    ),
    cupertinoOverrideTheme: const CupertinoThemeData(
      brightness: Brightness.dark,
      primaryColor: Palette.accent,
      scaffoldBackgroundColor: Palette.bg,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Palette.text,
      displayColor: Palette.text,
    ),
  );
}
