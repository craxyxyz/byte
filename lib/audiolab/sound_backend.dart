import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_lab.dart';

// Byte © 2026 Apurba Laskar.
//
// 1.4.5: where the Audio Lab's sound is made. One backend per platform takes
// the same settings (AudioLab.nativeConfig) and applies them to whatever
// player plays right now:
//   Android         the phone's band processor + room reverb on every player
//                   session (a new session per song/deck is followed), Byte's
//                   own balance / mono / crossfeed stage in the player
//   iPhone          Byte's own audio tap: the equalizer (10 points of the
//                   Audio Lab curve), balance and mono
//   Windows, Linux  the computer player's audio filters (desktop branch:
//                   lib/audiolab/mpv_filters.dart builds them)
//   Mac, web        speed only (the player there has no sound hook)
// What a platform can't do is greyed out on the Audio Lab with a short note.

/// Which Audio Lab controls this device's player really applies.
@immutable
class SoundCaps {
  final bool eq, preamp, reverb, loudness, crossfeed, mono, balance, pitch, keepPitch, surround;

  /// "on this phone", "in the browser", … (for "Not available …").
  final String place;
  const SoundCaps({
    this.eq = false,
    this.preamp = false,
    this.reverb = false,
    this.loudness = false,
    this.crossfeed = false,
    this.mono = false,
    this.balance = false,
    this.pitch = false,
    this.keepPitch = false,
    this.surround = false,
    this.place = 'on this device',
  });

  static const android = SoundCaps(eq: true, preamp: true, reverb: true, loudness: true, crossfeed: true, mono: true, balance: true, pitch: true, keepPitch: true, surround: true, place: 'on this phone');
  static const ios = SoundCaps(eq: true, mono: true, balance: true, place: 'on iPhone');
  static const web = SoundCaps(place: 'in the browser');
  static const mac = SoundCaps(place: 'on this Mac');

  /// Windows / Linux with the desktop player's audio filters.
  static const desktop = SoundCaps(eq: true, preamp: true, reverb: true, loudness: true, crossfeed: true, mono: true, balance: true, pitch: true, keepPitch: true, place: 'on this computer');

  /// A computer whose player has no sound hook.
  static const desktopPlain = SoundCaps(place: 'on this computer');

  SoundCaps copyWith({bool? eq, bool? preamp, bool? reverb, bool? loudness, bool? crossfeed, bool? mono, bool? balance, bool? pitch, bool? keepPitch, bool? surround}) => SoundCaps(
    eq: eq ?? this.eq,
    preamp: preamp ?? this.preamp,
    reverb: reverb ?? this.reverb,
    loudness: loudness ?? this.loudness,
    crossfeed: crossfeed ?? this.crossfeed,
    mono: mono ?? this.mono,
    balance: balance ?? this.balance,
    pitch: pitch ?? this.pitch,
    keepPitch: keepPitch ?? this.keepPitch,
    surround: surround ?? this.surround,
    place: place,
  );

  /// "Not available on this computer".
  String get note => 'Not available $place';

  /// The effects switched on in a party [sound] (AudioLab.partySound) that
  /// this device can't play, in plain words ("reverb", "pitch").
  List<String> skippedIn(Map sound) {
    bool on(String k) => sound[k] == true;
    final semis = (sound['semis'] as num?)?.toDouble() ?? 0;
    final bal = (sound['bal'] as num?)?.toDouble() ?? 0;
    return [
      if (on('eqOn') && !eq) 'equalizer',
      if (on('rvOn') && !reverb) 'reverb',
      if (on('ldOn') && !loudness) 'loudness',
      if (on('xfOn') && !crossfeed) 'crossfeed',
      if (on('mono') && !mono) 'mono',
      if (bal.abs() > 0.009 && !balance) 'balance',
      if (semis != 0 && !pitch) 'pitch',
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is SoundCaps && other.eq == eq && other.preamp == preamp && other.reverb == reverb && other.loudness == loudness && other.crossfeed == crossfeed && other.mono == mono && other.balance == balance && other.pitch == pitch && other.keepPitch == keepPitch && other.surround == surround && other.place == place;
  @override
  int get hashCode => Object.hash(eq, preamp, reverb, loudness, crossfeed, mono, balance, pitch, keepPitch, surround, place);
}

/// One platform's sound processor.
abstract class SoundBackend {
  const SoundBackend();
  SoundCaps get caps;

  /// Read what the device can do (may change [caps]).
  Future<void> start() async {}

  /// A player (Android audio session) started / is gone.
  Future<void> attach(int session) async {}
  Future<void> detach(int session) async {}

  /// Apply [config] (AudioLab.nativeConfig) to every player.
  Future<void> apply(AudioLab lab, Map<String, Object?> config);

  /// Set by a platform build (the desktop branch) or a test: replaces the
  /// built-in choice below.
  static SoundBackend Function()? override;

  static SoundBackend forPlatform() {
    final o = override;
    if (o != null) return o();
    if (kIsWeb) return const PlainSoundBackend(SoundCaps.web);
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidSoundBackend(),
      TargetPlatform.iOS => IosSoundBackend(),
      TargetPlatform.macOS => const PlainSoundBackend(SoundCaps.mac),
      _ => const PlainSoundBackend(SoundCaps.desktopPlain),
    };
  }
}

/// A player with no sound hook: only speed (the player's own).
class PlainSoundBackend extends SoundBackend {
  @override
  final SoundCaps caps;
  const PlainSoundBackend(this.caps);
  @override
  Future<void> apply(AudioLab lab, Map<String, Object?> config) async {}
}

/// Android: android/app/src/main/kotlin/.../ByteAudioLab.kt.
class AndroidSoundBackend extends SoundBackend {
  static const _ch = MethodChannel('byte/audiolab');
  @override
  SoundCaps caps = SoundCaps.android;

  @override
  Future<void> start() async {
    try {
      final c = await _ch.invokeMethod<Map>('caps');
      if (c != null) {
        final band = c['bandProcessor'] != false;
        final stage = c['channelStage'] != false;
        caps = SoundCaps.android.copyWith(eq: band, preamp: band, loudness: band, reverb: c['reverb'] != false, mono: stage, balance: stage, crossfeed: stage);
      }
    } catch (_) {}
  }

  @override
  Future<void> attach(int session) async {
    try {
      await _ch.invokeMethod('attach', {'session': session});
    } catch (_) {}
  }

  @override
  Future<void> detach(int session) async {
    try {
      await _ch.invokeMethod('detach', {'session': session});
    } catch (_) {}
  }

  @override
  Future<void> apply(AudioLab lab, Map<String, Object?> config) async {
    try {
      await _ch.invokeMethod('config', {...config, 'reverb': AudioLab.reverbNative(config)});
    } catch (_) {}
  }
}

/// iPhone: ios/Runner/ByteEQ.m (the tap every song gets). The Audio Lab
/// curve is sent as 10 points; while it's on, the classic equalizer (which
/// shares the tap) is off — the Audio Lab switches it off.
class IosSoundBackend extends SoundBackend {
  static const _ch = MethodChannel('byte/eq');
  static const bands = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
  @override
  SoundCaps get caps => SoundCaps.ios;

  /// True while the Audio Lab equalizer owns the tap (the classic one then
  /// leaves it alone, see ByteEqualizer.apply).
  static bool labOwnsEq = false;

  /// The classic equalizer puts its own setting back (main.dart wires it).
  static VoidCallback? restoreClassic;

  /// What was last sent (tests).
  Map<String, Object?>? lastEq, lastChannels;

  static List<double> gainsFor(AudioLab lab) => [for (final f in bands) EqMath.curveDb(lab.activeNodes, f).clamp(-15.0, 15.0)];

  @override
  Future<void> apply(AudioLab lab, Map<String, Object?> config) async {
    final on = lab.anyEq;
    final was = labOwnsEq;
    labOwnsEq = on;
    if (on) {
      lastEq = {'enabled': true, 'freqs': bands, 'gains': gainsFor(lab)};
      try {
        await _ch.invokeMethod('set', lastEq);
      } catch (_) {}
    } else if (was) {
      lastEq = {'enabled': false, 'freqs': bands, 'gains': List<double>.filled(bands.length, 0)};
      try {
        await _ch.invokeMethod('set', lastEq);
      } catch (_) {}
      restoreClassic?.call();
    }
    lastChannels = {'mono': lab.mono, 'balance': lab.balance};
    try {
      await _ch.invokeMethod('channels', lastChannels);
    } catch (_) {}
  }
}
