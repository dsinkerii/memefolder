import 'dart:math';

import 'package:flutter/material.dart';

Color userAccentColor = Color(0xFF6A79D7);

class ThemeModel extends ChangeNotifier {
  bool _dark = true;
  Color _accent = userAccentColor;

  bool get dark => _dark;
  Color get accent => _accent;

  set dark(bool v) {
    if (_dark == v) return;
    _dark = v;
    notifyListeners();
  }

  set accent(Color c) {
    if (_accent == c) return;
    _accent = c;
    notifyListeners();
  }
}

Color primaryContainerConverterDark(Color accent) {
  HSVColor hsvColor = HSVColor.fromColor(accent);
  hsvColor = hsvColor.withValue(hsvColor.value * 0.38);
  hsvColor = hsvColor.withSaturation(min(hsvColor.saturation * 0.83, 0.43));
  return hsvColor.toColor();
}

Color primaryContainerConverterLight(Color accent) {
  HSVColor hsvColor = HSVColor.fromColor(accent);
  hsvColor = hsvColor.withValue(hsvColor.value * 0.88);
  hsvColor = hsvColor.withSaturation(min(hsvColor.saturation * 0.63, 0.33));
  return hsvColor.toColor();
}

Color onTertiaryContainerConverter(Color accent, Brightness brightness) {
  HSLColor hslColor = HSLColor.fromColor(accent);
  hslColor = hslColor.withSaturation(0);
  hslColor = hslColor.withLightness(
    brightness == Brightness.dark ? 0.90 : 0.10,
  );
  return hslColor.toColor();
}

Color readableOn(Color background) => background.computeLuminance() > 0.3
    ? const Color(0xFF111111)
    : Colors.white;
Color secondary(HSVColor primary) => primary
    .withValue(primary.value * 0.8)
    .withSaturation(primary.value * 0.6)
    .toColor();

ThemeData buildTheme(Brightness brightness, Color accent) {
  final primaryContainer = brightness == Brightness.light
      ? primaryContainerConverterLight(accent)
      : primaryContainerConverterDark(accent);

  return ThemeData(
    useMaterial3: true,
    colorScheme: brightness == Brightness.light
        ? ColorScheme(
            brightness: Brightness.light,
            onPrimary: readableOn(accent),
            secondary: secondary(HSVColor.fromColor(accent)),
            onSecondary: Color(0xFF1B1B24),
            error: Color(0xFFB3261E),
            onError: Color(0xFFB3261E),
            surface: Color(0xFFFCFCFF),
            onSurface: Color(0xFF1F1F21),
            onSurfaceVariant: Color(0xFF4B4B57),
            primaryContainer: primaryContainer,
            onPrimaryContainer: readableOn(primaryContainer),
            tertiaryContainer: primaryContainer,
            onTertiaryContainer: readableOn(primaryContainer),
            surfaceContainerHigh: Color(0xFFF1F2F8),
            surfaceContainerHighest: Color(0xFFE9EAF2),
            surfaceContainerLowest: Color(0xFFFFFFFF),
            surfaceBright: Color(0xFFFCFCFF),
            primary: accent,
          )
        : ColorScheme(
            brightness: Brightness.dark,
            onPrimary: readableOn(accent),
            secondary: Color(0xFF262626),
            onSecondary: Color(0xFF161616),
            error: Color(0xFFB3261E),
            onError: Color(0xFFC84D42),
            surface: Color(0xFF161616),
            onSurface: Color(0xFFD1D2DF),
            onSurfaceVariant: Color(0xFF989898),
            primaryContainer: primaryContainer,
            onPrimaryContainer: readableOn(primaryContainer),
            tertiaryContainer: primaryContainer,
            onTertiaryContainer: readableOn(primaryContainer),
            surfaceContainerHigh: Color(0xFF2C2C2C),
            surfaceContainerHighest: Color(0xFF262626),
            surfaceContainerLowest: Color(0xFF111111),
            surfaceBright: Color(0xFF989898),
            primary: accent,
          ),

    fontFamily: "AlbertSans",
    fontFamilyFallback: ["AlbertSans", 'TwemojiMozilla'],
  );
}
