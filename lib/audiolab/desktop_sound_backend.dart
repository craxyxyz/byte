import 'dart:io' show Platform;

import 'package:byte_desktop_audio/byte_desktop_audio.dart';
import 'package:flutter/foundation.dart';

import 'audio_lab.dart';
import 'mpv_filters.dart';

// Byte © 2026 Apurba Laskar.
//
// 1.4.5: the Audio Lab on Windows and Linux. The computer player runs every
// song through the Audio Lab's filter chain (lib/audiolab/mpv_filters.dart):
// equalizer, preamp, balance, mono, loudness, a short room reverb and
// crossfeed. Speed and pitch are the player's own.
class DesktopSoundBackend extends SoundBackend {
  const DesktopSoundBackend();

  /// 1.4.5.1: the Windows player has no sound filters (any Audio Lab chain
  /// silenced the song there), so on Windows the Audio Lab shows as not
  /// available; speed and pitch still work (the player's own).
  @override
  SoundCaps get caps => !ByteDesktopAudio.available
      ? SoundCaps.desktopPlain
      : ByteDesktopAudio.filtersSupported
      ? SoundCaps.desktop
      : SoundCaps.desktopPlain.copyWith(pitch: true, keepPitch: true);

  @override
  Future<void> apply(AudioLab lab, Map<String, Object?> config) => ByteDesktopAudio.setEffects(caps.eq ? mpvFilterGraph(lab) : '');

  /// Windows / Linux use this backend (macOS keeps its own player).
  static void register() {
    if (kIsWeb) return;
    if (Platform.isWindows || Platform.isLinux) SoundBackend.override = () => const DesktopSoundBackend();
  }
}
