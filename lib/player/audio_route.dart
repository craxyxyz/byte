import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the sound is going right now (phone speaker, headphones, Bluetooth,
/// USB DAC), the phone's own name, its mixer rate, media volume, and whether
/// it can play Dolby Atmos or spatial audio. Android answers through Byte's
/// own `byte/audio` channel; elsewhere sensible defaults are used.
class AudioRouteInfo {
  final String deviceName;
  final String outputType; // speaker | wired | bluetooth | usb | hdmi
  final String? outputName;
  final int? sampleRate;
  final int? framesPerBuffer;
  final double volume; // 0..1
  final bool atmos;
  final bool spatialAvailable;
  final bool spatialEnabled;
  final bool native;
  final String? model;
  /// How many volume steps the phone's media volume has (15 on most phones).
  final int steps;

  /// The listener's first name, for "Apurba's Phone" (set by the app).
  static String Function() ownerName = () => '';

  const AudioRouteInfo({
    this.model,
    this.deviceName = 'This phone',
    this.outputType = 'speaker',
    this.outputName,
    this.sampleRate,
    this.framesPerBuffer,
    this.volume = 1,
    this.atmos = false,
    this.spatialAvailable = false,
    this.spatialEnabled = false,
    this.native = false,
    this.steps = 15,
  });

  AudioRouteInfo withVolume(double v) => AudioRouteInfo(
    model: model,
    deviceName: deviceName,
    outputType: outputType,
    outputName: outputName,
    sampleRate: sampleRate,
    framesPerBuffer: framesPerBuffer,
    volume: v,
    atmos: atmos,
    spatialAvailable: spatialAvailable,
    spatialEnabled: spatialEnabled,
    native: native,
    steps: steps,
  );

  bool get onPhoneSpeaker => outputType == 'speaker';

  /// The line under the output button: "Apurba's Phone", "AirDopes 141"…
  String get label => outputType == 'speaker' || outputName == null || outputName!.isEmpty ? phoneName : outputName!;

  /// The phone's own name. When the phone only knows its model number
  /// ("SM-S911B") or nothing, it's "Apurba's Phone" (the listener's name).
  String get phoneName {
    if (kIsWeb) return 'This browser';
    final generic = deviceName.trim().isEmpty || deviceName == 'This phone' || deviceName == 'iPhone' || (model != null && deviceName.trim() == model!.trim());
    if (!generic) return deviceName;
    final n = ownerName().trim();
    return n.isEmpty ? deviceName : "${n.split(' ').first}'s Phone";
  }

  String get outputKind => switch (outputType) {
    'usb' => 'USB DAC',
    'bluetooth' => 'Bluetooth',
    'wired' => 'Headphones',
    'hdmi' => 'HDMI',
    _ => 'Phone speaker',
  };

  factory AudioRouteInfo.fromMap(Map m) {
    final vol = (m['volume'] as num?)?.toDouble() ?? 0;
    final max = (m['maxVolume'] as num?)?.toDouble() ?? 0;
    return AudioRouteInfo(
      deviceName: (m['deviceName'] as String?)?.trim().isNotEmpty == true ? m['deviceName'] as String : 'This phone',
      outputType: m['outputType'] as String? ?? 'speaker',
      outputName: m['outputName'] as String?,
      sampleRate: (m['sampleRate'] as num?)?.toInt(),
      framesPerBuffer: (m['framesPerBuffer'] as num?)?.toInt(),
      volume: max > 0 ? (vol / max).clamp(0.0, 1.0) : 1,
      atmos: m['atmos'] == true,
      spatialAvailable: m['spatialAvailable'] == true,
      spatialEnabled: m['spatialEnabled'] == true,
      native: true,
      model: m['model'] as String?,
      steps: max > 0 ? max.round() : 15,
    );
  }
}

class AudioRoute extends ChangeNotifier {
  static const _ch = MethodChannel('byte/audio');
  AudioRouteInfo info = const AudioRouteInfo();
  Timer? _poll;
  int _listeners = 0;

  /// The player's own volume (used where the phone's media volume can't be set: iPhone, web, tests).
  final ValueNotifier<double> appVolume = ValueNotifier(1);

  /// What the in-app volume slider shows. Only the slider listens to this,
  /// so dragging never rebuilds the rest of the player.
  final ValueNotifier<double> volumeShown = ValueNotifier(1);

  /// What the in-app slider shows.
  double get volume => volumeShown.value;

  /// The phone step Byte last set or last heard (-1 = not known yet).
  int _lastIndex = -1;
  bool _dragging = false;
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription? _events;
  static const _volumeEvents = EventChannel('byte/audio/volume');

  /// Follow the phone's volume buttons live (turned on by the app at start;
  /// off in tests, which have no phone behind the channel).
  static bool listenToHardware = false;

  /// Kept for older callers: Byte no longer adds its own gain on top of the
  /// phone's volume (that made a saw-tooth in loudness while dragging).
  double get fineGain => 1;

  @visibleForTesting
  int get lastIndex => _lastIndex;

  @visibleForTesting
  static Future<void> Function(String method, Map<String, Object?> args)? invokeForTest;

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    final f = invokeForTest;
    if (f != null) {
      await f(method, args ?? const {});
      return null;
    }
    return _ch.invokeMethod<T>(method, args);
  }

  Future<AudioRouteInfo> refresh() async {
    try {
      final m = await _ch.invokeMethod<Map>('info');
      if (m != null) {
        final fresh = AudioRouteInfo.fromMap(m);
        final steps = fresh.steps > 0 ? fresh.steps : 15;
        info = fresh;
        if (fresh.native) systemVolumeChanged((fresh.volume * steps).round(), steps);
        notifyListeners();
      }
    } on MissingPluginException {
      // not Android: keep defaults
    } on PlatformException {
      // ignore
    }
    return info;
  }

  /// The phone's media volume changed (its buttons, another app, or the echo
  /// of Byte's own change). The slider only moves when the phone's step is
  /// really different from what the slider already shows, so it never snaps
  /// back after a drag, and it follows the phone's buttons at once.
  void systemVolumeChanged(int index, int steps) {
    if (steps <= 0) return;
    if (_dragging || DateTime.now().isBefore(_quietUntil)) {
      // The person is dragging: their finger wins; echoes of our own sends are ignored.
      return;
    }
    if (index == _lastIndex) return;
    final shownIndex = (volumeShown.value * steps).round();
    _lastIndex = index;
    if (index != shownIndex) volumeShown.value = (index / steps).clamp(0.0, 1.0);
  }

  /// Start listening to the phone's volume buttons (Android). Safe to call often.
  void _listenToButtons() {
    if (_events != null || invokeForTest != null || kIsWeb || !listenToHardware) return;
    try {
      _events = _volumeEvents.receiveBroadcastStream().listen(
        (e) {
          if (e is Map) {
            final idx = (e['index'] as num?)?.toInt();
            final max = (e['max'] as num?)?.toInt();
            if (idx != null && max != null) systemVolumeChanged(idx, max);
          }
        },
        onError: (_) {},
      );
    } catch (_) {
      // not Android
    }
  }

  /// The slider is being dragged ([on] true) or was let go.
  void dragging(bool on) {
    _dragging = on;
    if (!on) _quietUntil = DateTime.now().add(const Duration(milliseconds: 600));
  }

  bool _sending = false;
  int? _queued;

  /// Sets the volume at once: the slider moves on the same frame, the phone's
  /// media volume follows on a background thread (only one call in flight,
  /// the newest value wins), and only when the phone's step really changes.
  /// No extra player gain is mixed in, so loudness rises evenly, matching the
  /// phone's own volume buttons.
  Future<void> setVolume(double v, {void Function(double)? playerVolume}) async {
    v = v.clamp(0.0, 1.0);
    volumeShown.value = v;
    if (info.native) {
      if (playerVolume != null) playerVolume(1);
      _quietUntil = DateTime.now().add(const Duration(milliseconds: 600));
      final steps = info.steps > 0 ? info.steps : 15;
      final idx = (v * steps).round().clamp(0, steps);
      if (idx != _lastIndex) {
        _lastIndex = idx;
        await _send(idx, steps);
      }
    } else {
      appVolume.value = v;
      playerVolume?.call(v);
    }
  }

  Future<void> _send(int idx, int steps) async {
    if (_sending) {
      _queued = idx;
      return;
    }
    _sending = true;
    try {
      int? next = idx;
      while (next != null) {
        _queued = null;
        try {
          await _invoke('setVolume', {'v': next / steps, 'index': next});
        } catch (_) {}
        next = _queued;
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> multicast(bool on) async {
    try {
      await _ch.invokeMethod('multicast', {'on': on});
    } catch (_) {}
  }

  /// USB DAC mixer: "off", "best" (the DAC's highest rate) or "bitperfect".
  /// Returns what the phone accepted ("unsupported" on Android 13 and older,
  /// or with no USB DAC plugged in).
  Future<String> usbMixer(String mode) async {
    try {
      return await _ch.invokeMethod<String>('usbMixer', {'mode': mode}) ?? 'unsupported';
    } catch (_) {
      return 'unsupported';
    }
  }

  Future<void> openSoundSettings() async {
    try {
      await _ch.invokeMethod('soundSettings');
    } catch (_) {}
  }

  /// Screens that show the route (player, output sheet) keep it fresh while open.
  void watch() {
    _listeners++;
    _listenToButtons();
    unawaited(refresh());
    _poll ??= Timer.periodic(const Duration(seconds: 2), (_) => refresh());
  }

  void unwatch() {
    _listeners = (_listeners - 1).clamp(0, 999);
    if (_listeners == 0) {
      _poll?.cancel();
      _poll = null;
    }
  }

  @visibleForTesting
  void setForTest(AudioRouteInfo i) {
    info = i;
    volumeShown.value = i.volume;
    _lastIndex = i.native ? (i.volume * (i.steps > 0 ? i.steps : 15)).round() : -1;
    notifyListeners();
  }
}
