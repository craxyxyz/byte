import 'dart:math';

import 'analysis.dart';

/// Automix style. Smart = beat-matched, tempo-nudged, loudness-matched blend
/// with a bass swap; simple = a loudness-matched crossfade that still skips
/// silent intros and outros.
enum AutomixMode { smart, simple }

/// How one song hands over to the next. Pure maths, unit-tested.
class TransitionPlan {
  /// Position in the outgoing song (ms) where the incoming one starts.
  final int startAtMs;

  /// Where the incoming song starts playing from (ms; skips silence, lands on a beat).
  final int incomingFromMs;

  /// Length of the overlap (ms).
  final int fadeMs;

  /// Speed of the incoming song during the overlap (1 = untouched). Eases
  /// back to normal over [tempoEaseMs] after the overlap.
  final double tempoRatio;
  static const tempoEaseMs = 4000;

  /// Loudness-matching volume for each song (never above 1).
  final double outGain, inGain;

  final bool beatMatched;

  /// Low end of the incoming song held back, then swapped with the outgoing one.
  final bool bassSwap;

  /// The outgoing song fades out by itself: keep it up and let it.
  final bool outFadesItself;

  /// 'smart', 'simple' or 'fallback' (analysis missing).
  final String kind;

  const TransitionPlan({
    required this.startAtMs,
    required this.incomingFromMs,
    required this.fadeMs,
    this.tempoRatio = 1,
    this.outGain = 1,
    this.inGain = 1,
    this.beatMatched = false,
    this.bassSwap = false,
    this.outFadesItself = false,
    required this.kind,
  });

  bool get isSmart => kind == 'smart';

  /// Volumes (outgoing, incoming) at [t] 0..1 through the overlap, before gains.
  (double, double) volumes(double t) {
    final x = t.clamp(0.0, 1.0);
    if (!isSmart) return (cos(x * pi / 2), sin(x * pi / 2));
    final inV = sin(min(1.0, x / 0.75) * pi / 2);
    final double outV;
    if (outFadesItself) {
      outV = x < 0.7 ? 1.0 : cos((x - 0.7) / 0.3 * pi / 2);
    } else {
      outV = x < 0.25 ? 1.0 : cos((x - 0.25) / 0.75 * pi / 2);
    }
    return (outV, inV);
  }

  /// How much bass is cut (outgoing, incoming), 0 = none, 1 = full cut.
  (double, double) lowCut(double t) {
    if (!bassSwap) return (0, 0);
    final x = t.clamp(0.0, 1.0);
    final swap = x < 0.45 ? 0.0 : (x < 0.6 ? (x - 0.45) / 0.15 : 1.0);
    return (swap, 1 - swap);
  }

  /// Incoming song's speed multiplier [ms] after it started.
  double speedAt(int ms) {
    if (tempoRatio == 1) return 1;
    if (ms <= fadeMs) return tempoRatio;
    final k = ((ms - fadeMs) / tempoEaseMs).clamp(0.0, 1.0);
    return tempoRatio + (1 - tempoRatio) * k;
  }

  /// A plan started late (the listener seeked into the outro): shorten it to
  /// what's left, at least [minMs].
  TransitionPlan startingLate(int positionMs, int outEndMs, {int minMs = 1500}) {
    final left = max(minMs, outEndMs - positionMs);
    return TransitionPlan(
      startAtMs: positionMs,
      incomingFromMs: incomingFromMs,
      fadeMs: min(fadeMs, left),
      tempoRatio: 1,
      outGain: outGain,
      inGain: inGain,
      beatMatched: false,
      bassSwap: bassSwap && left >= 3000,
      outFadesItself: false,
      kind: kind,
    );
  }

  @override
  String toString() =>
      'TransitionPlan($kind: at ${startAtMs}ms, in from ${incomingFromMs}ms, fade ${fadeMs}ms, tempo ${tempoRatio.toStringAsFixed(3)}, '
      'gains ${outGain.toStringAsFixed(2)}/${inGain.toStringAsFixed(2)}${beatMatched ? ', beat-matched' : ''}${bassSwap ? ', bass swap' : ''}${outFadesItself ? ', out fades itself' : ''})';
}

/// Volume that brings a song to about -14 LUFS; only turns loud songs down.
double loudnessGain(double loudnessDb, {double target = -14}) => pow(10, (target - loudnessDb) / 20).toDouble().clamp(0.3, 1.0);

/// [b] moved by an octave if that brings it closer to [a] (98 vs 196 bpm).
double nearestOctave(double a, double b) {
  var best = b;
  for (final c in [b / 2, b * 2]) {
    if ((log(c / a)).abs() < (log(best / a)).abs()) best = c;
  }
  return best;
}

/// Largest tempo nudge Automix makes (±6 %, too small to notice).
const maxTempoNudge = 0.06;

TransitionPlan planTransition({
  required int outDurationMs,
  TrackAnalysis? out,
  int? inDurationMs,
  TrackAnalysis? inn,
  required double seconds,
  required AutomixMode mode,
  double outFallbackGain = 1,
  double inFallbackGain = 1,
}) {
  final want = (seconds.clamp(1.0, 20.0) * 1000).round();
  final durA = outDurationMs > 0 ? outDurationMs : (out?.durationMs ?? 0);
  final durB = inDurationMs ?? inn?.durationMs;
  // the music's real end (silent / hidden-track tails skipped)
  var endA = durA;
  if (out != null && out.audioEndMs > 0) endA = min(durA, out.audioEndMs);
  if (endA < 1000) endA = durA;
  var fromB = inn?.audioStartMs ?? 0;
  if (durB != null && fromB > durB - 5000) fromB = 0;

  // short songs get short blends: at most a third of either song
  var cap = endA ~/ 3;
  if (durB != null && durB > 0) cap = min(cap, (durB - fromB) ~/ 3);
  cap = max(cap, 500);

  final outG = out != null ? loudnessGain(out.loudnessDb) : outFallbackGain;
  final inG = inn != null ? loudnessGain(inn.loudnessDb) : inFallbackGain;

  if (out == null && inn == null) {
    final t = min(want, cap);
    return TransitionPlan(startAtMs: max(0, endA - t), incomingFromMs: 0, fadeMs: t, outGain: outG, inGain: inG, kind: 'fallback');
  }
  if (mode == AutomixMode.simple || out == null || inn == null) {
    final t = min(want, cap);
    return TransitionPlan(
      startAtMs: max(0, endA - t),
      incomingFromMs: fromB,
      fadeMs: t,
      outGain: outG,
      inGain: inG,
      kind: out == null || inn == null ? 'fallback' : 'simple',
    );
  }

  // ── smart ──
  var t = want;
  var outFades = false;
  if (out.fadesOut) {
    final f = endA - out.outroStartMs;
    t = min(max(want, f), (want * 1.5).round());
    outFades = true;
  }
  var beat = out.hasBeat && inn.hasBeat;
  // the beat has to be clear right where the songs meet (not a beatless outro/intro)
  if (beat && (out.beatStrengthAt(max(0, endA - t)) < 0.25 || inn.beatStrengthAt(fromB + 2000) < 0.25)) beat = false;
  var ratio = 1.0;
  if (beat) {
    final bB = nearestOctave(out.bpm, inn.bpm);
    final r = out.bpm / bB;
    if ((r - 1).abs() > maxTempoNudge) {
      beat = false; // too far apart to match: a shorter clean blend instead
      t = min(t, 6000);
    } else if ((r - 1).abs() > 0.003) {
      ratio = r;
    }
  }
  t = min(t, cap);
  var start = max(0, endA - t);
  var inFrom = fromB;
  if (beat) {
    // land the incoming song's first downbeat on a downbeat of the outgoing one
    var j = inn.beatAtOrAfter(fromB);
    if (j >= 0) {
      for (var k = 0; k < 4 && j + k < inn.beatsMs.length; k++) {
        if (inn.isDownbeat(j + k)) {
          j += k;
          break;
        }
      }
    }
    final beatB = inn.beatMs / ratio;
    if (j < 0 || inn.beatsMs[j] - fromB > max(4000, 4 * beatB)) {
      beat = false; // long beatless intro: blend over it instead
      ratio = 1;
    } else {
      inFrom = inn.beatsMs[j];
      var i = out.beatAtOrBefore(start);
      if (i >= 0) {
        for (var k = 0; k < 4 && i - k >= 0; k++) {
          if (out.isDownbeat(i - k)) {
            i -= k;
            break;
          }
        }
        // don't move earlier than 4 beats from the planned start
        if (start - out.beatsMs[i] <= out.beatMs * 4.5) start = out.beatsMs[i];
      } else {
        beat = false;
        ratio = 1;
      }
    }
  }
  if (outFades && start < out.outroStartMs - 1000) outFades = false;
  return TransitionPlan(
    startAtMs: start,
    incomingFromMs: inFrom,
    fadeMs: t,
    tempoRatio: beat ? ratio : 1,
    outGain: outG,
    inGain: inG,
    beatMatched: beat,
    bassSwap: t >= 3000,
    outFadesItself: outFades,
    kind: 'smart',
  );
}
