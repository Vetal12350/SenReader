import 'package:flutter/material.dart';

/// Warm SenReader palette for both brightness modes.
/// The reader canvas stays black so original manga artwork is unaffected.
abstract final class SenReaderTheme {
  static const accent = Color(0xFFFF893F);

  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF100F14) : const Color(0xFFFFFAF7);
    final card = dark ? const Color(0xFF20191D) : const Color(0xFFFFF1E8);
    final nav = dark ? const Color(0xFF171419) : const Color(0xFFFFF5EE);
    final indicator = dark ? const Color(0xFF41281F) : const Color(0xFFFFDFCB);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent, brightness: brightness,
    ).copyWith(surface: surface);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: surface,
      cardColor: card,
      appBarTheme: AppBarTheme(backgroundColor: surface),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: nav, indicatorColor: indicator,
      ),
    );
  }
}
