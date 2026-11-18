import 'package:flutter/material.dart';

/// Warna Don't Move. Netral dengan sedikit rona biru; satu-satunya warna kuat adalah avatar alias.
class C {
  static const ink = Color(0xFF15181C);
  static const ink2 = Color(0xFF474D56);
  static const ink3 = Color(0xFF7F8691);
  static const rule = Color(0xFFD7DBE0);
  static const fill = Color(0xFFECEFF2);
  static const paper = Color(0xFFFFFFFF);
  static const stop = Color(0xFF9A2B2B);
  static const warnBg = Color(0xFFF5EAD6);
  static const warn = Color(0xFF80540F);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.light(
    primary: C.ink,
    onPrimary: C.paper,
    secondary: C.ink2,
    onSecondary: C.paper,
    surface: C.paper,
    onSurface: C.ink,
    error: C.stop,
    onError: C.paper,
    outline: C.rule,
    outlineVariant: C.rule,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: C.paper);
  return base.copyWith(
    dividerColor: C.rule,
    dividerTheme: const DividerThemeData(color: C.rule, thickness: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: C.paper,
      foregroundColor: C.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: C.ink, fontSize: 18, fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.ink,
        foregroundColor: C.paper,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.ink,
        minimumSize: const Size.fromHeight(48),
        side: const BorderSide(color: C.ink3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: C.ink2)),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: C.ink3)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: C.ink3)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: C.ink, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: const TextStyle(color: C.ink3),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: C.ink,
      contentTextStyle: TextStyle(color: C.paper, fontSize: 14),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
