import 'package:flutter/material.dart';

import 'ui/screens/onboarding_screen.dart';
import 'ui/party_sound_banner.dart';
import 'ui/style.dart' show ByteScrollBehavior;

import 'brand.dart';
import 'services.dart';
import 'ui/art_colors.dart';
import 'ui/keyboard_shortcuts.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

class ByteApp extends StatefulWidget {
  /// Show the first-launch welcome (set by main on a fresh install).
  static bool welcome = false;
  const ByteApp({super.key});
  @override
  State<ByteApp> createState() => _ByteAppState();
}

class _ByteAppState extends State<ByteApp> {
  Color seed = byteViolet;
  String? _url;

  @override
  void initState() {
    super.initState();
    Services.i.player.current.addListener(_onSong);
    Services.i.settings.addListener(_onSong);
  }

  @override
  void dispose() {
    Services.i.player.current.removeListener(_onSong);
    Services.i.settings.removeListener(_onSong);
    super.dispose();
  }

  Future<void> _onSong() async {
    final st = Services.i.settings;
    if (!st.dynamicColor) {
      if (seed != byteViolet && mounted) setState(() => seed = byteViolet);
      _url = null;
      return;
    }
    final url = Services.i.player.current.value?.thumbAt(226);
    if (url == null || url == _url) return;
    _url = url;
    final p = await paletteFor(url);
    if (!mounted || url != _url) return;
    final h = HSVColor.fromColor(p.secondary);
    setState(() => seed = h.withSaturation(h.saturation.clamp(0.35, 0.9)).withValue(0.8).toColor());
  }

  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) => MaterialApp(
        title: Brand.appName,
        debugShowCheckedModeBanner: false,
        scrollBehavior: const ByteScrollBehavior(),
        shortcuts: byteShortcuts(WidgetsApp.defaultShortcuts),
        actions: byteActions(WidgetsApp.defaultActions),
        themeMode: st.themeMode,
        theme: ByteTheme.build(Brightness.light, seed: seed, font: st.font),
        darkTheme: ByteTheme.build(Brightness.dark, seed: seed, pureBlack: st.pureBlack, font: st.font),
        themeAnimationDuration: const Duration(milliseconds: 700),
        themeAnimationCurve: Curves.easeInOut,
        // 1.4.3: a host's "share my sound" offer shows on top of every screen
        builder: (context, child) => PartySoundBanner(child: child ?? const SizedBox.shrink()),
        home: ByteApp.welcome ? OnboardingScreen(onDone: () => setState(() => ByteApp.welcome = false)) : const Shell(),
      ),
    );
  }
}
