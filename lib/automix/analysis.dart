import 'dart:math';
import 'dart:typed_data';

/// What Automix knows about one song, worked out from its decoded audio:
/// tempo and beat grid, loudness, and where the music really starts and
/// ends (so silent or long faded outros are skipped). Byte © 2026 Apurba Laskar.
class TrackAnalysis {
  static const version = 4;

  final int durationMs;

  /// Beats per minute (0 = no steady beat found).
  final double bpm;

  /// 0..1: how clearly the beat stands out. Below [beatThreshold] the song is
  /// mixed without beat matching (ambient, classical, free-time intros…).
  final double beatConfidence;

  /// Every tracked beat, in ms from the start of the song.
  final List<int> beatsMs;

  /// Index into [beatsMs] of the first downbeat (start of a bar of 4).
  final int downbeat;

  /// Integrated loudness, roughly LUFS.
  final double loudnessDb;

  /// First sound / end of the quiet intro / start of the outro (fade) / last sound.
  final int audioStartMs, introEndMs, outroStartMs, audioEndMs;

  /// 0..1, how intense the song is (for ordering a smooth shuffle).
  final double energy;

  static const beatThreshold = 0.3;

  /// How clear the beat is in each stretch of 16 beats (stepping 8 beats),
  /// 0..100. Lets the mix skip beat matching over a beatless intro/outro.
  final List<int> localBeat;

  const TrackAnalysis({
    this.localBeat = const [],
    required this.durationMs,
    required this.bpm,
    required this.beatConfidence,
    required this.beatsMs,
    required this.downbeat,
    required this.loudnessDb,
    required this.audioStartMs,
    required this.introEndMs,
    required this.outroStartMs,
    required this.audioEndMs,
    required this.energy,
  });

  bool get hasBeat => bpm > 0 && beatConfidence >= beatThreshold && beatsMs.length >= 8;

  /// The song fades out (or has a long quiet outro) rather than stopping.
  bool get fadesOut => audioEndMs - outroStartMs >= 2000;

  double get beatMs => bpm > 0 ? 60000 / bpm : 0;

  /// The beat nearest to [ms] that is at or before it (index), or -1.
  int beatAtOrBefore(int ms) {
    var lo = 0, hi = beatsMs.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (beatsMs[mid] <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// First beat at or after [ms] (index), or -1.
  int beatAtOrAfter(int ms) {
    final i = beatAtOrBefore(ms);
    if (i >= 0 && beatsMs[i] == ms) return i;
    final j = i + 1;
    return j < beatsMs.length ? j : -1;
  }

  /// 0..1: how clear the beat is around [ms] (whole-song value when unknown).
  double beatStrengthAt(int ms) {
    if (!hasBeat) return 0;
    if (localBeat.isEmpty) return beatConfidence;
    final i = max(0, beatAtOrBefore(ms));
    // windows start every 8 beats; use the one centred nearest to this beat
    final w = ((i - 8) / 8).round().clamp(0, localBeat.length - 1);
    return localBeat[w] / 100;
  }

  bool isDownbeat(int index) => index >= 0 && (index - downbeat) % 4 == 0;

  Map<String, dynamic> toJson() => {
    'v': version,
    'd': durationMs,
    'bpm': double.parse(bpm.toStringAsFixed(3)),
    'bc': double.parse(beatConfidence.toStringAsFixed(3)),
    'b': _deltaEncode(beatsMs),
    'db': downbeat,
    'l': double.parse(loudnessDb.toStringAsFixed(2)),
    'as': audioStartMs,
    'ie': introEndMs,
    'os': outroStartMs,
    'ae': audioEndMs,
    'e': double.parse(energy.toStringAsFixed(3)),
    'lb': localBeat,
  };

  static TrackAnalysis? fromJson(Map m) {
    if (m['v'] != version) return null;
    return TrackAnalysis(
      durationMs: m['d'] as int,
      bpm: (m['bpm'] as num).toDouble(),
      beatConfidence: (m['bc'] as num).toDouble(),
      beatsMs: _deltaDecode((m['b'] as List).cast<int>()),
      downbeat: m['db'] as int,
      loudnessDb: (m['l'] as num).toDouble(),
      audioStartMs: m['as'] as int,
      introEndMs: m['ie'] as int,
      outroStartMs: m['os'] as int,
      audioEndMs: m['ae'] as int,
      energy: (m['e'] as num).toDouble(),
      localBeat: ((m['lb'] as List?) ?? const []).cast<int>(),
    );
  }

  static List<int> _deltaEncode(List<int> v) => [for (var i = 0; i < v.length; i++) i == 0 ? v[0] : v[i] - v[i - 1]];
  static List<int> _deltaDecode(List<int> d) {
    final out = <int>[];
    var acc = 0;
    for (final x in d) {
      acc += x;
      out.add(acc);
    }
    return out;
  }

  @override
  String toString() =>
      'TrackAnalysis(${(durationMs / 1000).toStringAsFixed(1)}s, ${bpm.toStringAsFixed(1)} bpm conf ${beatConfidence.toStringAsFixed(2)}, '
      '${beatsMs.length} beats, ${loudnessDb.toStringAsFixed(1)} dB, start ${audioStartMs}ms intro ${introEndMs}ms outro ${outroStartMs}ms end ${audioEndMs}ms, energy ${energy.toStringAsFixed(2)})';
}

/// Second-order IIR section (RBJ cookbook forms).
class _Biquad {
  double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;
  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory _Biquad.lowpass(double f, double rate, {double q = 0.7071}) {
    final w = 2 * pi * f / rate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al;
    return _Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - al) / a0);
  }
  factory _Biquad.highpass(double f, double rate, {double q = 0.7071}) {
    final w = 2 * pi * f / rate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al;
    return _Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0);
  }
  factory _Biquad.highShelf(double f, double rate, double gainDb) {
    final a = pow(10, gainDb / 40).toDouble(), w = 2 * pi * f / rate, c = cos(w), s = sin(w);
    final al = s / 2 * sqrt(2.0), sa = 2 * sqrt(a) * al;
    final a0 = (a + 1) - (a - 1) * c + sa;
    return _Biquad(
      a * ((a + 1) + (a - 1) * c + sa) / a0,
      -2 * a * ((a - 1) + (a + 1) * c) / a0,
      a * ((a + 1) + (a - 1) * c - sa) / a0,
      2 * ((a - 1) - (a + 1) * c) / a0,
      ((a + 1) - (a - 1) * c - sa) / a0,
    );
  }
  double run(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

/// Last analysis' internal numbers (dev tool only).
String debugLastAnalysis() => _debug;
String _debug = '';

double _db(double power) => 10 * log(power + 1e-12) / ln10;

/// Works out a [TrackAnalysis] from mono 16-bit PCM at [rate] Hz (Byte's
/// decoders deliver 11025 Hz mono). Pure Dart; runs in a background isolate.
TrackAnalysis analyzePcm(Int16List pcm, int sampleRate) {
  final rate = sampleRate.toDouble();
  final n = pcm.length;
  final durationMs = (n * 1000 / rate).round();
  if (n < rate) {
    return TrackAnalysis(
      durationMs: durationMs,
      bpm: 0,
      beatConfidence: 0,
      beatsMs: const [],
      downbeat: 0,
      loudnessDb: -70,
      audioStartMs: 0,
      introEndMs: 0,
      outroStartMs: durationMs,
      audioEndMs: durationMs,
      energy: 0,
    );
  }

  // ── 1. loudness frames (100 ms), K-weighting-like filter ──
  final frame = sampleRate ~/ 10;
  final nf = n ~/ frame;
  final pow100 = Float64List(nf);
  {
    final hp = _Biquad.highpass(38, rate, q: 0.5);
    final shelf = _Biquad.highShelf(1500, rate, 4);
    for (var f = 0; f < nf; f++) {
      var acc = 0.0;
      final base = f * frame;
      for (var i = 0; i < frame; i++) {
        final y = shelf.run(hp.run(pcm[base + i] / 32768.0));
        acc += y * y;
      }
      pow100[f] = acc / frame;
    }
  }
  // integrated loudness: 400 ms blocks (step 100 ms), absolute + relative gate
  final blocks = <double>[];
  for (var f = 0; f + 4 <= nf; f++) {
    blocks.add((pow100[f] + pow100[f + 1] + pow100[f + 2] + pow100[f + 3]) / 4);
  }
  double gatedMean(double gateDb) {
    var s = 0.0, c = 0;
    for (final b in blocks) {
      if (_db(b) > gateDb) {
        s += b;
        c++;
      }
    }
    return c == 0 ? 1e-12 : s / c;
  }

  final l1 = _db(gatedMean(-70));
  final loudness = (_db(gatedMean(max(-70, l1 - 10))) - 0.691).clamp(-70.0, 6.0);

  // smoothed level (1 s centred window) and frame levels
  final lev = Float64List(nf);
  for (var f = 0; f < nf; f++) {
    lev[f] = _db(pow100[f]);
  }
  final smooth = Float64List(nf);
  {
    var s = 0.0;
    const half = 5;
    final pre = Float64List(nf + 1);
    for (var f = 0; f < nf; f++) {
      s += pow100[f];
      pre[f + 1] = s;
    }
    for (var f = 0; f < nf; f++) {
      final a = max(0, f - half), b = min(nf, f + half + 1);
      smooth[f] = _db((pre[b] - pre[a]) / (b - a));
    }
  }
  final silent = max(-60.0, loudness - 32);
  var first = 0;
  while (first < nf && lev[first] <= silent) {
    first++;
  }
  var last = nf - 1;
  while (last > first && lev[last] <= silent) {
    last--;
  }
  if (first >= nf) {
    // all silence
    return TrackAnalysis(
      durationMs: durationMs,
      bpm: 0,
      beatConfidence: 0,
      beatsMs: const [],
      downbeat: 0,
      loudnessDb: loudness,
      audioStartMs: 0,
      introEndMs: 0,
      outroStartMs: durationMs,
      audioEndMs: durationMs,
      energy: 0,
    );
  }
  // A long silent gap late in the song (a "hidden track" after minutes of
  // nothing): the mix treats the music before the gap as the real end.
  {
    final minGap = 60; // 6 s
    var run = 0;
    var start = (nf * 0.6).floor();
    while (start > first && lev[start] <= silent) {
      start--;
    }
    for (var f = start; f <= last; f++) {
      if (lev[f] <= silent) {
        run++;
      } else {
        if (run >= minGap) {
          last = f - run - 1;
          break;
        }
        run = 0;
      }
    }
  }
  // body level: median of the louder frames
  final body = [for (var f = first; f <= last; f++) smooth[f]]..sort();
  final ref = body.isEmpty ? loudness : body[(body.length * 0.6).floor().clamp(0, body.length - 1)];
  var introEnd = first;
  final introCap = min(last, first + 450);
  while (introEnd < introCap && smooth[introEnd] < ref - 6) {
    introEnd++;
  }
  var outro = last;
  final outroCap = max(first, last - 450);
  while (outro > outroCap && smooth[outro] < ref - 4) {
    outro--;
  }
  final audioStartMs = first * 100;
  final audioEndMs = min(durationMs, (last + 1) * 100);
  var outroStartMs = min(audioEndMs, (outro + 1) * 100);
  if (audioEndMs - outroStartMs < 1500) outroStartMs = audioEndMs;
  final introEndMs = max(audioStartMs, introEnd * 100);

  // ── 2. onset strength (11.6 ms hops at 11025 Hz), low + high band flux ──
  const hop = 128;
  final nh = n ~/ hop;
  final fps = rate / hop;
  final onset = Float64List(nh);
  final lowOnset = Float64List(nh);
  {
    final lp = _Biquad.lowpass(150, rate);
    final hpOn = _Biquad.highpass(150, rate);
    var prevL = 0.0, prevH = 0.0;
    for (var h = 0; h < nh; h++) {
      var el = 0.0, eh = 0.0;
      final base = h * hop;
      for (var i = 0; i < hop; i++) {
        final x = pcm[base + i] / 32768.0;
        final l = lp.run(x), hh = hpOn.run(x);
        el += l * l;
        eh += hh * hh;
      }
      final cl = log(1 + 1000 * sqrt(el / hop)), ch = log(1 + 1000 * sqrt(eh / hop));
      final fl = max(0.0, cl - prevL), fh = max(0.0, ch - prevH);
      prevL = cl;
      prevH = ch;
      lowOnset[h] = fl;
      onset[h] = fl + fh;
    }
    // remove the local average, keep the peaks
    const w = 22; // ~0.25 s each side
    final pre = Float64List(nh + 1);
    for (var h = 0; h < nh; h++) {
      pre[h + 1] = pre[h] + onset[h];
    }
    final tmp = Float64List(nh);
    for (var h = 0; h < nh; h++) {
      final a = max(0, h - w), b = min(nh, h + w + 1);
      tmp[h] = max(0.0, onset[h] - (pre[b] - pre[a]) / (b - a));
    }
    var sd = 0.0;
    for (final v in tmp) {
      sd += v * v;
    }
    sd = sqrt(sd / nh) + 1e-9;
    for (var h = 0; h < nh; h++) {
      onset[h] = tmp[h] / sd;
    }
  }

  // ── 3. tempo: autocorrelation of the onset curve over the music ──
  final h0 = (audioStartMs / 1000 * fps).floor().clamp(0, nh - 1);
  final h1 = (audioEndMs / 1000 * fps).floor().clamp(h0, nh);
  final segLen = h1 - h0;
  var bpm = 0.0, conf = 0.0;
  var beatsMs = <int>[];
  var downbeat = 0;
  var localBeat = <int>[];
  final maxLag = (fps * 60 / 40 * 2).ceil(); // up to 4 × the slowest beat we look for
  if (segLen > maxLag * 2 && segLen > fps * 8) {
    final ac = Float64List(maxLag + 2);
    for (var l = 0; l <= maxLag + 1; l++) {
      var s = 0.0;
      for (var h = h0; h + l < h1; h++) {
        s += onset[h] * onset[h + l];
      }
      ac[l] = s / (segLen - l);
    }
    double acAt(double lag) {
      if (lag < 1 || lag >= maxLag) return 0;
      final i = lag.floor();
      final fr = lag - i;
      return ac[i] * (1 - fr) + ac[i + 1] * fr;
    }

    var best = 0.0;
    var bestBpm = 0.0;
    for (var b = 60.0; b <= 190.0; b += 0.1) {
      final lag = 60 * fps / b;
      final prior = exp(-0.5 * pow(log(b / 115) / ln2 / 0.9, 2));
      final s = prior * (acAt(lag) + 0.5 * acAt(2 * lag) + 0.25 * acAt(4 * lag) + 0.2 * acAt(lag / 2));
      if (s > best) {
        best = s;
        bestBpm = b;
      }
    }
    // How much the beat lag stands out from the other lags (noise ≈ 1).
    var base = 0.0, bc = 0;
    for (var l = (60 * fps / 190).floor(); l <= (60 * fps / 60).ceil() && l < maxLag; l++) {
      base += ac[l];
      bc++;
    }
    base = bc == 0 ? 0 : base / bc;
    final peakRatio = base <= 0 ? 0.0 : acAt(60 * fps / bestBpm) / base;
    final periodicity = ((peakRatio - 1.25) / 1.25).clamp(0.0, 1.0);

    // ── 4. beat tracking (dynamic programming), following small tempo drift ──
    if (bestBpm > 0) {
      final p = 60 * fps / bestBpm;
      const tight = 300.0;
      final score = Float64List(segLen);
      final back = Int32List(segLen);
      final lo = (p / 2).round(), hi = (p * 2).round();
      // penalty table by distance
      final pen = Float64List(hi + 1);
      for (var d = 1; d <= hi; d++) {
        pen[d] = -tight * pow(log(d / p), 2);
      }
      for (var t = 0; t < segLen; t++) {
        var bestPrev = -1;
        var bestVal = 0.0;
        for (var d = lo; d <= hi; d++) {
          final tau = t - d;
          if (tau < 0) break;
          final v = score[tau] + pen[d];
          if (bestPrev < 0 || v > bestVal) {
            bestVal = v;
            bestPrev = tau;
          }
        }
        final o = onset[h0 + t];
        if (bestPrev >= 0 && bestVal > 0) {
          score[t] = o + bestVal;
          back[t] = bestPrev;
        } else {
          score[t] = o;
          back[t] = -1;
        }
      }
      // end on the best-scoring frame within the last period
      var end = segLen - 1;
      var endVal = -1e300;
      for (var t = max(0, segLen - p.ceil()); t < segLen; t++) {
        if (score[t] > endVal) {
          endVal = score[t];
          end = t;
        }
      }
      final frames = <int>[];
      var t = end;
      while (t >= 0) {
        frames.add(t);
        t = back[t];
      }
      final beats = frames.reversed.map((f) => f + h0).where((f) {
        final ms = f * hop * 1000 / rate;
        return ms >= audioStartMs - 50 && ms <= audioEndMs + 50;
      }).toList();
      beatsMs = [for (final f in beats) (f * hop * 1000 / rate).round()];
      if (beatsMs.length >= 8) {
        // overall tempo from a straight-line fit through the beats
        final m = beatsMs.length;
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
        for (var i = 0; i < m; i++) {
          sx += i;
          sy += beatsMs[i];
          sxx += i * i.toDouble();
          sxy += i * beatsMs[i].toDouble();
        }
        final slope = (m * sxy - sx * sy) / (m * sxx - sx * sx);
        bpm = slope > 0 ? 60000 / slope : bestBpm;
        // steadiness: spread of beat gaps around the period
        var dev = 0.0;
        for (var i = 1; i < m; i++) {
          final g = (beatsMs[i] - beatsMs[i - 1]) - slope;
          dev += g * g;
        }
        final cv = sqrt(dev / (m - 1)) / slope;
        // contrast: onset strength on the beats vs. half-way between them
        var on = 0.0, off = 0.0;
        for (var i = 0; i < beats.length - 1; i++) {
          on += onset[beats[i]];
          off += onset[((beats[i] + beats[i + 1]) / 2).round()];
        }
        final contrast = on <= 0 ? 0.0 : ((on - off) / on).clamp(0.0, 1.0);
        final steady = (1 - cv * 5).clamp(0.0, 1.0);
        // grid clarity: in windows of 16 beats, fit a straight grid and see
        // how much stronger the onsets are on it than between its lines
        final clar = <double>[];
        for (var w0 = 0; w0 + 16 <= beats.length; w0 += 8) {
          var sx2 = 0.0, sy2 = 0.0, sxx2 = 0.0, sxy2 = 0.0;
          for (var k = 0; k < 16; k++) {
            final y = beats[w0 + k].toDouble();
            sx2 += k;
            sy2 += y;
            sxx2 += k * k.toDouble();
            sxy2 += k * y;
          }
          final b = (16 * sxy2 - sx2 * sy2) / (16 * sxx2 - sx2 * sx2);
          final a0 = (sy2 - b * sx2) / 16;
          final prof = List<double>.filled(8, 0);
          for (var k = 0; k < 16; k++) {
            for (var j = 0; j < 8; j++) {
              final c = (a0 + b * (k + j / 8)).round();
              var m = 0.0;
              for (var d = -1; d <= 1; d++) {
                final i = c + d;
                if (i >= 0 && i < nh) m = max(m, onset[i]);
              }
              prof[j] += m;
            }
          }
          final rest = (prof.sublist(1).reduce((x, y) => x + y)) / 7;
          clar.add(rest <= 0 ? 0 : prof[0] / rest);
        }
        localBeat = [for (final v in clar) (((v - 1.8) / 1.4).clamp(0.0, 1.0) * 100).round()];
        final sortedClar = List.of(clar)..sort();
        final clarity = sortedClar.isEmpty ? 0.0 : sortedClar[sortedClar.length ~/ 2];
        // Calibrated on real songs: clear pop/film beats score > 2.4, ambient ~1.5.
        final clarityScore = ((clarity - 1.8) / 1.4).clamp(0.0, 1.0);
        conf = (0.75 * clarityScore + 0.25 * periodicity).clamp(0.0, 1.0) * (0.6 + 0.4 * steady);
        _debug = 'clarity ${clarity.toStringAsFixed(2)} peak ${peakRatio.toStringAsFixed(2)} contrast ${contrast.toStringAsFixed(2)} steady ${steady.toStringAsFixed(2)}';
        // downbeat: the beat phase (of 4) with the strongest low-end hits
        final sums = List<double>.filled(4, 0);
        for (var i = 0; i < beats.length; i++) {
          final f = beats[i];
          var s = 0.0;
          for (var k = max(0, f - 2); k <= min(nh - 1, f + 2); k++) {
            s = max(s, lowOnset[k]);
          }
          sums[i % 4] += s;
        }
        var bi = 0;
        for (var k = 1; k < 4; k++) {
          if (sums[k] > sums[bi]) bi = k;
        }
        downbeat = bi;
      } else {
        bpm = 0;
        beatsMs = [];
      }
    }
  }

  // ── 5. energy: loud + busy = high ──
  var onsetMean = 0.0;
  for (var h = h0; h < h1; h++) {
    onsetMean += onset[h];
  }
  onsetMean = segLen > 0 ? onsetMean / segLen : 0;
  final energy = (0.6 * ((ref + 30) / 24).clamp(0.0, 1.0) + 0.4 * (onsetMean / 0.8).clamp(0.0, 1.0)).clamp(0.0, 1.0);

  return TrackAnalysis(
    durationMs: durationMs,
    bpm: bpm,
    beatConfidence: conf,
    beatsMs: beatsMs,
    downbeat: downbeat,
    loudnessDb: loudness,
    audioStartMs: audioStartMs,
    introEndMs: introEndMs,
    outroStartMs: outroStartMs,
    audioEndMs: audioEndMs,
    energy: energy,
    localBeat: localBeat,
  );
}
