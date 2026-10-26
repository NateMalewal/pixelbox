import 'package:flutter/material.dart';

/// Palette inspirée de Miami de nuit : violet très sombre, rose néon, turquoise.
class Palette {
  static const bg = Color(0xFF0A0715);
  static const surface = Color(0xFF161026);
  static const accent = Color(0xFFFF4F9A);
  static const accent2 = Color(0xFF2DE2C8);
  static const sunset = Color(0xFFFFA24A);
  static const text = Color(0xFFF1EEF8);
  static const muted = Color(0xFF9A93B3);
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Palette.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: Palette.accent,
      secondary: Palette.accent2,
      surface: Palette.surface,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Palette.text,
      displayColor: Palette.text,
    ),
  );
}
