// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba): "Laptop / MacBook / desktop / Linux version mein upar niche
// kuch nahi dikhna chahiye, full screen lyrics hoga". Full-screen lyrics put
// the whole window in real full screen: on a computer the title bar and the
// taskbar / dock / menu bar go; on the web the browser's own full screen; on
// a phone the player's existing immersive mode stays as it was.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_fullscreen_stub.dart' if (dart.library.js_interop) 'app_fullscreen_web.dart' as web;

/// What can put the window in full screen. The real one picks the platform's
/// way; tests hand in a fake.
abstract class WindowFullscreen {
  Future<void> set(bool on);
}

class _PlatformFullscreen implements WindowFullscreen {
  @override
  Future<void> set(bool on) async {
    if (kIsWeb) return web.setBrowserFullscreen(on);
    final desktop = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (desktop) {
      final hook = AppFullscreen.desktopHook;
      if (hook != null) await hook(on);
    }
    // Phones and tablets keep the player's own immersive mode.
  }
}

class AppFullscreen {
  AppFullscreen._();

  /// Set by the desktop app at start (the window plugin lives in the desktop
  /// build only): true = real full screen, false = back to how it was.
  static Future<void> Function(bool on)? desktopHook;

  /// The window's full-screen switch (a fake in tests).
  static WindowFullscreen window = _PlatformFullscreen();

  /// Is the window in full screen because of Byte right now?
  static final ValueNotifier<bool> active = ValueNotifier(false);

  /// Hide the mouse pointer after this long without a move (full screen only).
  static Duration cursorIdle = const Duration(seconds: 3);

  static Future<void> enter() => _set(true);
  static Future<void> exit() => _set(false);
  static Future<void> toggle() => _set(!active.value);

  static Future<void> _set(bool on) async {
    // (The browser can leave full screen by itself on Esc: ask it again.)
    if (active.value == on && !kIsWeb) return;
    active.value = on;
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
