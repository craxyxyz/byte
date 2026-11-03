import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/settings.dart';

/// What the phone allows for the lock-screen player (Android).
@immutable
class LockScreenStatus {
  final int sdk;
  final String manufacturer;
  final String brand;
  final bool miui;
  final bool canFullScreenIntent;
  final bool canDrawOverlays;
  final bool notificationsEnabled;
  const LockScreenStatus({
    this.sdk = 0,
    this.manufacturer = '',
    this.brand = '',
    this.miui = false,
    this.canFullScreenIntent = true,
    this.canDrawOverlays = false,
    this.notificationsEnabled = true,
  });

  factory LockScreenStatus.fromMap(Map<String, Object?> m) => LockScreenStatus(
    sdk: (m['sdk'] as num?)?.toInt() ?? 0,
    manufacturer: (m['manufacturer'] as String? ?? '').toLowerCase(),
    brand: (m['brand'] as String? ?? '').toLowerCase(),
    miui: m['miui'] == true,
    canFullScreenIntent: m['canFullScreenIntent'] != false,
    canDrawOverlays: m['canDrawOverlays'] == true,
    notificationsEnabled: m['notificationsEnabled'] != false,
  );

  bool _is(List<String> names) => names.any((n) => manufacturer.contains(n) || brand.contains(n));
  bool get xiaomi => miui || _is(['xiaomi', 'redmi', 'poco']);
  bool get samsung => _is(['samsung']);
  bool get vivo => _is(['vivo', 'iqoo']);
  bool get oppo => _is(['oppo', 'realme', 'oneplus']);
  bool get huawei => _is(['huawei', 'honor']);

  /// Android 14+ asks the user before an app may open over the lock screen.
  bool get needsFullScreenPermission => sdk >= 34 && !canFullScreenIntent;
}

typedef LockInvoker = Future<Object?> Function(String method, [Map<String, Object?>? args]);

Future<Object?> _defaultInvoke(String method, [Map<String, Object?>? args]) => LockScreenBridge.channel.invokeMethod<Object?>(method, args);

/// Main-app side of the lock-screen player: tells Android to listen for the
/// screen turning on while music plays (and to stop listening otherwise).
/// Setting off → nothing is registered and nothing opens.
class LockScreenBridge {
  static const channel = MethodChannel('byte/lockscreen');
  static LockInvoker invoke = _defaultInvoke;

  final Settings settings;
  final Stream<PlaybackState> playback;

  /// After a pause the player keeps showing on the lock screen this long.
  final Duration pausedGrace;
  StreamSubscription<PlaybackState>? _sub;
  bool _playing = false;
  bool _hasSong = false;
  bool? _armed;
  Timer? _grace;

  LockScreenBridge({required this.settings, required this.playback, this.pausedGrace = const Duration(minutes: 10)});

  bool? get armed => _armed;

  void start() {
    _sub = playback.listen(_onPlayback);
    settings.addListener(_apply);
    _apply();
  }

  void stop() {
    _sub?.cancel();
    settings.removeListener(_apply);
    _grace?.cancel();
    if (_armed == true) _send(false);
  }

  void _onPlayback(PlaybackState s) {
    _playing = s.playing;
    _hasSong = s.processingState != AudioProcessingState.idle;
    if (_playing) {
      _grace?.cancel();
      _grace = null;
    } else if (_hasSong && _armed == true && _grace == null) {
      _grace = Timer(pausedGrace, () {
        _grace = null;
        _apply();
      });
    }
    _apply();
  }

  bool get _wanted => settings.lockScreenPlayer && _hasSong && (_playing || _grace != null);

  void _apply() {
    final want = _wanted;
    if (want == _armed) return;
    _send(want);
  }

  void _send(bool on) {
    _armed = on;
    unawaited(invoke(on ? 'arm' : 'disarm').catchError((_) => null));
  }

  // ── Settings page helpers ──
  static Future<LockScreenStatus?> status() async {
    try {
      final m = await invoke('status');
      return m is Map ? LockScreenStatus.fromMap(m.cast<String, Object?>()) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _open(String m) async {
    try {
      return await invoke(m) == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openFullScreenSettings() => _open('openFullScreenSettings');
  static Future<bool> openOemSettings() => _open('openOemSettings');
  static Future<bool> openOverlaySettings() => _open('openOverlaySettings');
  static Future<bool> openNotificationSettings() => _open('openNotificationSettings');

  /// Opens the real lock-screen window now (false when not on Android).
  static Future<bool> preview() => _open('preview');
}
