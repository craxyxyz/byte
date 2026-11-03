// Byte © 2026 Apurba Laskar
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'screen_awake_stub.dart' if (dart.library.js_interop) 'screen_awake_web.dart' as web;

/// Keeps the phone's screen from turning off while someone needs to see it
/// (the lyrics screen). Android: FLAG_KEEP_SCREEN_ON on the app's window (no
/// permission needed). iPhone: the idle timer is switched off. Web: the
/// browser's Screen Wake Lock, where the browser has one; elsewhere nothing.
class ScreenAwake {
  ScreenAwake._();

  static const channel = MethodChannel('byte/display');
  static final Set<Object> _holders = {};
  static bool _on = false;

  /// True while Byte is asking for the screen to stay on.
  static bool get isOn => _on;

  /// [who] wants the screen kept on (several holders may overlap).
  static void hold(Object who) {
    if (_holders.add(who)) _apply();
  }

  /// [who] no longer needs it; the screen may sleep once nobody holds it.
  static void release(Object who) {
    if (_holders.remove(who)) _apply();
  }

  static void _apply() {
    final want = _holders.isNotEmpty;
    if (want == _on) return;
    _on = want;
    unawaited(_send(want));
  }

  static Future<void> _send(bool on) async {
    try {
      if (kIsWeb) {
        await web.setScreenWakeLock(on);
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
        await channel.invokeMethod('keepScreenOn', on);
      }
    } catch (_) {
      // An old phone or browser without it: the screen simply sleeps as usual.
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _holders.clear();
    _on = false;
  }
}

/// While this widget is on screen, the app is in front, and its page is the
/// top one, the screen stays on — playing or paused. It lets go when the
/// widget leaves the screen, the app goes to the background, or another page
/// covers it.
class KeepScreenOn extends StatefulWidget {
  final Widget child;
  const KeepScreenOn({super.key, required this.child});

  @override
  State<KeepScreenOn> createState() => _KeepScreenOnState();
}

class _KeepScreenOnState extends State<KeepScreenOn> with WidgetsBindingObserver {
  final Object _token = Object();
  bool _foreground = true;
  bool _topPage = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final s = WidgetsBinding.instance.lifecycleState;
    _foreground = s == null || _isFront(s);
  }

  // inactive = a call banner, the notification shade: still in front.
  static bool _isFront(AppLifecycleState s) => s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Another page (settings, a sheet) on top of the lyrics: let it sleep.
    _topPage = ModalRoute.isCurrentOf(context) ?? true;
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _isFront(state);
    _update();
  }

  void _update() {
    if (!mounted) return;
    if (_foreground && _topPage) {
      ScreenAwake.hold(_token);
    } else {
      ScreenAwake.release(_token);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ScreenAwake.release(_token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
