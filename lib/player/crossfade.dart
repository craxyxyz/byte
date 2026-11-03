import 'dart:math';

/// When and how two tracks overlap. Pure maths, unit-tested.
class CrossfadePlan {
  /// Seconds of overlap requested by the user (0 = gapless hand-off).
  final double seconds;
  const CrossfadePlan(this.seconds);

  /// Overlap actually used for a track of [trackMs]: never more than a third
  /// of the track, so short songs still get heard.
  int effectiveMs(int trackMs) {
    if (seconds <= 0 || trackMs <= 0) return 0;
    return min((seconds * 1000).round(), trackMs ~/ 3);
  }

  /// Position (ms into the current track) at which the next one starts.
  int startNextAt(int trackMs) => trackMs - effectiveMs(trackMs);

  /// When to begin preparing (resolving + buffering) the next track.
  int prepareAt(int trackMs) => max(0, startNextAt(trackMs) - 20000);

  /// Equal-power volumes (outgoing, incoming) at [t] 0..1 through the fade.
  /// Audio Lab → Transition → Blend style "Straight": a linear fade.
  static bool linear = false;

  static (double, double) volumes(double t) {
    final x = t.clamp(0.0, 1.0);
    if (linear) return (1 - x, x);
    return (cos(x * pi / 2), sin(x * pi / 2));
  }
}

/// Sleep timer fade: full volume until the last [fadeMs], then down to zero.
double sleepFadeVolume(int remainingMs, {int fadeMs = 10000}) {
  if (remainingMs <= 0) return 0;
  if (remainingMs >= fadeMs) return 1;
  return remainingMs / fadeMs;
}

/// Loudness normalisation gain from YouTube's per-track loudness (dB above
/// its reference). Only turns loud tracks down; never boosts past 1.0.
double normalisationGain(double? loudnessDb) {
  if (loudnessDb == null || loudnessDb <= 0) return 1.0;
  return pow(10, -loudnessDb / 20).toDouble().clamp(0.25, 1.0);
}
