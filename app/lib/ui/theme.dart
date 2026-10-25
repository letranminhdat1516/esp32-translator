import 'package:flutter/material.dart';

/// "Phụ đề" style: black, text first, one blue accent (the board's) that
/// lights only while listening. Values copied from ContentView.swift.
abstract final class Palette {
  static const ground = Color(0xFF000000);
  static const surface = Color(0xFF16171A);
  static const text = Color(0xFFE3EAF0);
  static const muted = Color(0xFF8A919C);
  static const faint = Color(0xFF5E646D);
  static const accent = Color(0xFF1E6FD9);
  static const accentLight = Color(0xFF4C8FE8);
}

/// Dark theme with the palette above. [fontFamily] is null in the app (the
/// platform font); tests pass the bundled Be Vietnam Pro so Vietnamese renders.
ThemeData buildTheme({String? fontFamily}) {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: Palette.ground,
    colorScheme: const ColorScheme.dark(
      primary: Palette.accent,
      secondary: Palette.accentLight,
      surface: Palette.surface,
      onSurface: Palette.text,
      error: Color(0xFFE5645A),
    ),
    splashFactory: NoSplash.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Palette.text,
      displayColor: Palette.text,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Palette.surface,
      textStyle: TextStyle(color: Palette.text, fontSize: 15),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: Palette.surface),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Palette.surface,
      modalBackgroundColor: Palette.surface,
    ),
  );
}
