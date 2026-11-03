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

  @override
  SoundCaps get caps => ByteDesktopAudio.available ? SoundCaps.desktop : SoundCaps.desktopPlain;

  @override
  Future<void> apply(AudioLab lab, Map<String, Object?> config) => ByteDesktopAudio.setEffects(caps.eq ? mpvFilterGraph(lab) : '');

  /// Windows / Linux use this backend (macOS keeps its own player).
  static void register() {
    if (kIsWeb) return;
    if (Platform.isWindows || Platform.isLinux) SoundBackend.override = () => const DesktopSoundBackend();
  }
}
