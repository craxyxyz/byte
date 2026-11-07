// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba): "Laptop / MacBook / desktop / Linux version mein upar niche
// kuch nahi dikhna chahiye, full screen lyrics hoga". Full-screen lyrics put
// the whole window in real full screen: on a computer the title bar and the
// taskbar / dock / menu bar go; on the web the browser's own full screen; on
// a phone or tablet the status and navigation bars are hidden (immersive).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'app_fullscreen_stub.dart' if (dart.library.js_interop) 'app_fullscreen_web.dart' as web;
import 'win_fullscreen_stub.dart' if (dart.library.io) 'win_fullscreen.dart' as winfs;

/// What can put the window in full screen. The real one picks the platform's
/// way; tests hand in a fake.
abstract class WindowFullscreen {
  Future<void> set(bool on);
}

class _PlatformFullscreen implements WindowFullscreen {
  @override
  Future<void> set(bool on) async {
    if (kIsWeb) return web.setBrowserFullscreen(on);
    if (AppFullscreen.isDesktop) {
      final hook = AppFullscreen.desktopHook;
      if (hook != null) await hook(on);
      return;
    }
    // Phones and tablets (1.4.5, Apurba on his tablet: "niche jo safad baar
    // dikha raha woh hat jayeh"): the status bar and the navigation bar at the
    // bottom go too; a swipe from the edge shows them for a moment.
    final keep = on || AppFullscreen.keepImmersive;
    await SystemChrome.setEnabledSystemUIMode(keep ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }
}

class AppFullscreen {
  AppFullscreen._();

  /// A computer build (Windows, macOS, Linux) — not the web, a phone or a tablet.
  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// Set by the desktop app at start (the window plugin lives in the desktop
  /// build only): true = real full screen, false = back to how it was.
  static Future<void> Function(bool on)? desktopHook;

  /// Windows: the window's own full screen (no caption, no frame, the whole
  /// monitor; exit puts back the exact window). Throws where Windows refuses.
  static Future<void> setWindowsFullScreen(bool on) => winfs.setFullScreen(on);

  /// Windows diagnostics for the runner check: style bits, window and monitor rectangles.
  static int windowsStyle() => winfs.currentStyle();
  static List<int> windowsRect() => winfs.windowRect();
  static List<int> windowsMonitorRect() => winfs.monitorRect();

  /// Phone/tablet: the player itself wants the bars hidden ("Hide status bar
  /// in player"), so leaving full-screen lyrics keeps them hidden.
  static bool keepImmersive = false;

  /// The window's full-screen switch (a fake in tests).
  static WindowFullscreen window = platform;

  /// The real platform switch.
  static final WindowFullscreen platform = _PlatformFullscreen();

  /// Is the window in full screen because of Byte right now?
  static final ValueNotifier<bool> active = ValueNotifier(false);

  /// Hide the mouse pointer after this long without a move (full screen only).
  static Duration cursorIdle = const Duration(seconds: 3);

  static Future<void> enter() => _set(true);
  static Future<void> exit() => _set(false);
  static Future<void> toggle() => _set(!active.value);

  static AppLifecycleListener? _life;

  /// Back from the background (or the bars swiped in) while still in
  /// full-screen lyrics: hide the bars again.
  static Future<void> reapply() async {
    if (!active.value) return;
    try {
      await window.set(true);
    } catch (_) {}
  }

  static Future<void> _set(bool on) async {
    // (The browser can leave full screen by itself on Esc: ask it again.)
    if (active.value == on && !kIsWeb) return;
    active.value = on;
    if (on) {
      _life ??= AppLifecycleListener(onResume: () => unawaited(reapply()));
    } else {
      _life?.dispose();
      _life = null;
    }
    try {
      await window.set(on);
    } catch (_) {
      // The platform refused (a browser without a tap behind it, no window
      // plugin): the app carries on in its window.
    }
  }

  /// Keys on a computer / the web: F11 toggles, Esc leaves.
  static bool handleKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.f11) {
      unawaited(toggle());
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && active.value) {
      unawaited(exit());
      return true;
    }
    return false;
  }
}
