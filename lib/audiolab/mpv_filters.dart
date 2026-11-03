import 'dart:math' as math;

import 'audio_lab.dart';

// Byte © 2026 Apurba Laskar.
//
// 1.4.5: the Audio Lab on a computer (Windows / Linux). The desktop player
// runs every song through a chain of standard audio filters; this builds that
// chain from the Audio Lab settings, so the computer hears the same curve as
// the phone: preamp → equalizer (each point as its own shelf / peak, exactly
// as drawn) → reverb (a short room) → crossfeed → mono / balance →
// loudness (compressor) → limiter. Empty = nothing to do.

String _n(double v) => v.toStringAsFixed(2);

/// The filter graph (inside lavfi=[…]) for [lab], or '' when the sound is
/// untouched.
String mpvFilterGraph(AudioLab lab) {
  final c = lab.nativeConfig();
  final f = <String>[];
  final gain = (c['inputGain'] as num).toDouble();
  if (gain.abs() > 0.01) f.add('volume=${_n(gain)}dB');
  if (lab.anyEq) {
    for (final n in lab.activeNodes) {
      if (n.g.abs() < 0.05) continue;
      final kind = switch (n.type) {
        EqNodeType.lowShelf => 'lowshelf',
        EqNodeType.peak => 'equalizer',
        EqNodeType.highShelf => 'highshelf',
      };
      f.add('$kind=f=${n.f.round()}:t=q:w=${_n(n.q.clamp(0.1, 10.0))}:g=${_n(n.g)}');
    }
  }
  if (lab.reverbOn) {
    final size = lab.rv('size'), damp = lab.rv('damping');
    final wet = (lab.rv('mix') * lab.rv('wet')).clamp(0.0, 1.0);
    final dry = lab.rv('dry').clamp(0.05, 1.0);
    final pre = lab.rv('preDelay').clamp(0.0, 100.0);
    final delays = [for (final k in [1.0, 1.7, 2.6, 3.9]) (pre + 18 + size * 70 * k).round()];
    final decays = [for (var i = 0; i < 4; i++) (wet * (0.55 - damp * 0.25) * math.pow(0.72, i)).clamp(0.01, 0.9)];
    f.add('aecho=${_n(dry)}:0.95:${delays.join('|')}:${decays.map(_n).join('|')}');
  }
  if (c['crossfeed'] == true && lab.crossfeedAmount > 0) {
    final strength = (lab.crossfeedAmount * (0.15 + (lab.crossfeedDb + 15) / 14 * 0.6)).clamp(0.05, 1.0);
    final range = ((lab.crossfeedHz - 300) / 1700 * 0.6 + 0.2).clamp(0.0, 1.0);
    f.add('crossfeed=strength=${_n(strength)}:range=${_n(range)}');
  }
  final bal = lab.balance;
  final gl = bal > 0 ? 1 - bal : 1.0, gr = bal < 0 ? 1 + bal : 1.0;
  final needsStereo = c['crossfeed'] == true && lab.crossfeedAmount > 0 || lab.mono || bal.abs() > 0.009;
  // A mono song is made two-channel first, so these always find a right side.
  if (needsStereo) f.insert(0, 'aformat=channel_layouts=stereo');
  if (lab.mono) {
    f.add('pan=stereo|c0=${_n(gl * 0.5)}*c0+${_n(gl * 0.5)}*c1|c1=${_n(gr * 0.5)}*c0+${_n(gr * 0.5)}*c1');
  } else if (bal.abs() > 0.009) {
    f.add('pan=stereo|c0=${_n(gl)}*c0|c1=${_n(gr)}*c1');
  }
  if (c['mbcOn'] == true) {
    final th = math.pow(10, (c['threshold'] as num).toDouble() / 20).toDouble().clamp(0.001, 1.0);
    final ratio = (c['ratio'] as num).toDouble().clamp(1.0, 20.0);
    f.add('acompressor=threshold=${th.toStringAsFixed(4)}:ratio=${_n(ratio)}:attack=10:release=200');
  }
  if (c['limiterOn'] == true) f.add('alimiter=limit=0.89');
  return f.join(',');
}

/// The whole `af` value for one player: [tempo] is the player's own
/// scaletempo filter (speed / pitch), kept first.
String mpvAf(AudioLab lab, {String tempo = ''}) {
  final g = mpvFilterGraph(lab);
  return [if (tempo.isNotEmpty) tempo, if (g.isNotEmpty) 'lavfi=[$g]'].join(',');
}
