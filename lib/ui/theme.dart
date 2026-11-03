import 'dart:ui';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'style.dart';

/// Seed for the generated scheme (the logo's red); brand colours live in ByteColors.
const byteViolet = Color(0xFFF01848);
const byteCoral = Color(0xFFFF6B6B);
const byteAmber = Color(0xFFFFB547);

class ByteTheme {
  /// The player is always dark: a full dark theme (so its sheets, chips and
  /// dialogs are dark too, with readable text), white as the accent.
  static ThemeData player(ThemeData app) {
    final d = build(Brightness.dark);
    return d.copyWith(
      colorScheme: d.colorScheme.copyWith(onSurface: Colors.white, onSurfaceVariant: Colors.white70, primary: Colors.white, onPrimary: Colors.black),
      iconTheme: const IconThemeData(color: Colors.white),
      textTheme: d.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
    );
  }

  /// Settings → Appearance → Font: the phone's own font families (nothing bundled).
  static const fonts = {'default': 'Default', 'serif': 'Serif', 'monospace': 'Monospace', 'sans-serif-condensed': 'Condensed', 'casual': 'Casual'};

  static ThemeData build(Brightness b, {Color seed = byteViolet, bool pureBlack = false, String font = 'default'}) {
    final pal = b == Brightness.dark ? BytePalette.dark : BytePalette.light;
    var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.neutral);
    // Clean chrome (black on white / white on black) with Byte's red from the
    // logo as the one brand colour: buttons, sliders, switches, selection.
    scheme = scheme.copyWith(
      primary: ByteColors.brand,
      onPrimary: Colors.white,
      primaryContainer: ByteColors.brand.withValues(alpha: b == Brightness.dark ? 0.22 : 0.10),
      onPrimaryContainer: pal.accent,
      secondary: pal.accent,
      onSecondary: Colors.white,
      tertiary: pal.accent,
      surface: pal.bg,
      onSurface: pal.label,
      onSurfaceVariant: pal.secondary,
      surfaceContainerLowest: pal.bg,
      surfaceContainerLow: pal.grouped,
      surfaceContainer: pal.grouped,
      surfaceContainerHigh: pal.fill,
      surfaceContainerHighest: pal.fill,
      outlineVariant: pal.separator,
      outline: pal.tertiary,
    );
    if (b == Brightness.dark && !pureBlack) {
      scheme = scheme.copyWith(surface: const Color(0xFF0B0B0D), surfaceContainerLowest: const Color(0xFF0B0B0D));
    }
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b);
    final text = base.textTheme.apply(
      fontFamily: font == 'default' ? null : font,
      fontFamilyFallback: const ['Roboto', 'Noto Sans', 'Noto Sans Devanagari', 'Noto Sans Bengali'],
    );
    return base.copyWith(
      extensions: [if (b == Brightness.dark && !pureBlack) BytePalette.dark.copyWithBg(const Color(0xFF0B0B0D)) else pal],
      scaffoldBackgroundColor: scheme.surface,
      dividerColor: pal.separator,
      appBarTheme: AppBarTheme(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent, foregroundColor: pal.label, elevation: 0, scrolledUnderElevation: 0),
      dialogTheme: DialogThemeData(backgroundColor: b == Brightness.dark ? const Color(0xFF1C1C1E) : Colors.white, surfaceTintColor: Colors.transparent),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: b == Brightness.dark ? const Color(0xFF1C1C1E) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      ),
      // ⋯ menus: frosted-looking glass with a bright edge
      popupMenuTheme: PopupMenuThemeData(
        color: b == Brightness.dark ? const Color(0xEB2A2A2E) : const Color(0xF2FFFFFF),
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: b == Brightness.dark ? Colors.white.withValues(alpha: 0.16) : Colors.white, width: 1),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: ByteColors.brand,
        linearTrackColor: ByteColors.brand.withValues(alpha: 0.14),
        strokeWidth: 3,
        strokeCap: StrokeCap.round,
        borderRadius: BorderRadius.circular(3),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: pal.accent,
        selectionColor: ByteColors.brand.withValues(alpha: 0.25),
        selectionHandleColor: ByteColors.brand,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ByteColors.brand,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.1),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: pal.accent, shape: const StadiumBorder())),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: pal.label, shape: const StadiumBorder(), side: BorderSide(color: pal.separator, width: 1.4)),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? ByteColors.brand : null),
      ),
      textTheme: text.copyWith(
        headlineLarge: text.headlineLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8),
        headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          // A clean side slide everywhere (the fade-through on Android showed
          // both pages at once, which looked like a glitch on real phones).
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        },
      ),
      splashFactory: InkSparkle.splashFactory,
      // thick, round-ended tracks like the strokes of the logo
      sliderTheme: SliderThemeData(
        trackHeight: 6,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 2, pressedElevation: 4),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        activeTrackColor: ByteColors.brand,
        inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.12),
        thumbColor: ByteColors.brand,
        overlayColor: ByteColors.brand.withValues(alpha: 0.14),
        valueIndicatorColor: ByteColors.brand,
        valueIndicatorTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        activeTickMarkColor: Colors.white.withValues(alpha: 0.6),
        inactiveTickMarkColor: Colors.transparent,
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}

/// Frosted glass panel (bars, mini player).
class Glass extends StatelessWidget {
  final Widget child;
  final double blur;
  final Color? tint;
  final BorderRadius? radius;
  final Border? border;
  const Glass({super.key, required this.child, this.blur = 28, this.tint, this.radius, this.border});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint ?? cs.surface.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.62 : 0.72),
          borderRadius: radius,
          border: border,
        ),
        child: child,
      ),
    );
    return radius == null ? ClipRect(child: content) : ClipRRect(borderRadius: radius!, child: content);
  }
}
