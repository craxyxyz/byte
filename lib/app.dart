import 'package:flutter/material.dart';

import 'ui/screens/onboarding_screen.dart';
import 'ui/party_sound_banner.dart';
import 'ui/style.dart' show ByteScrollBehavior;

import 'brand.dart';
import 'services.dart';
import 'ui/keyboard_shortcuts.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

/// The largest text size Byte follows from the phone's settings (1.4.6).
const maxTextScale = 1.3;

/// Byte 2.0 © 2026 Apurba Laskar.
///
/// The app's look: only these settings rebuild the whole app (1.4.6 rebuilt
/// and re-animated the whole app on ANY settings change and on every new
/// song, when the colours followed the cover). In 2.0 the song's colours
/// colour the player, the lyrics and the mini player only; the app keeps its
/// own red.
@immutable
class AppLook {
  final ThemeMode mode;
  final bool pureBlack;
  final String font;
  const AppLook(this.mode, this.pureBlack, this.font);
  @override
  bool operator ==(Object other) => other is AppLook && other.mode == mode && other.pureBlack == pureBlack && other.font == font;
  @override
  int get hashCode => Object.hash(mode, pureBlack, font);
}

class ByteApp extends StatefulWidget {
  /// Show the first-launch welcome (set by main on a fresh install).
  static bool welcome = false;
  const ByteApp({super.key});
  @override
  State<ByteApp> createState() => _ByteAppState();
}

class _ByteAppState extends State<ByteApp> {
  late AppLook _look = _read();
  ThemeData? _light, _dark;

  AppLook _read() {
    final st = Services.i.settings;
    return AppLook(st.themeMode, st.pureBlack, st.font);
  }

  @override
  void initState() {
    super.initState();
    Services.i.settings.addListener(_onSettings);
  }

  @override
  void dispose() {
    Services.i.settings.removeListener(_onSettings);
    super.dispose();
  }

  void _onSettings() {
    final l = _read();
    if (l == _look || !mounted) return;
    setState(() {
      _look = l;
      _light = _dark = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = _look;
    // themes are built once per look, not on every build
    final light = _light ??= ByteTheme.build(Brightness.light, seed: byteViolet, font: l.font);
    final dark = _dark ??= ByteTheme.build(Brightness.dark, seed: byteViolet, pureBlack: l.pureBlack, font: l.font);
    return MaterialApp(
      title: Brand.appName,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const ByteScrollBehavior(),
      shortcuts: byteShortcuts(WidgetsApp.defaultShortcuts),
      actions: byteActions(WidgetsApp.defaultActions),
      themeMode: l.mode,
      theme: light,
      darkTheme: dark,
      themeAnimationDuration: const Duration(milliseconds: 250),
      themeAnimationCurve: Curves.easeOut,
      // 1.4.3: a host's "share my sound" offer shows on top of every screen
      // 1.4.6: the phone's text size is followed up to 1.3×
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: maxTextScale,
        child: PartySoundBanner(child: child ?? const SizedBox.shrink()),
      ),
      home: ByteApp.welcome ? OnboardingScreen(onDone: () => setState(() => ByteApp.welcome = false)) : const Shell(),
    );
  }
}
