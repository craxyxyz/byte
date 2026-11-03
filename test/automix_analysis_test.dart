import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:byte/automix/analysis.dart';
import 'package:byte/automix/order.dart';
import 'package:byte/automix/planner.dart';
import 'package:flutter_test/flutter_test.dart';

const rate = 11025;

/// A drum-machine style track made in code: kick on every beat, hi-hat on
/// the off-beats, a soft chord, with optional silence and a fade-out.
Int16List synth({
  required double bpm,
  required double musicSec,
  double leadSilence = 0,
  double tailSilence = 0,
  double fadeSec = 0,
  double gain = 1,
  int seed = 1,
}) {
  final rnd = Random(seed);
  final n = ((leadSilence + musicSec + tailSilence) * rate).round();
  final out = Int16List(n);
  final p = 60 / bpm;
  for (var i = 0; i < n; i++) {
    final t = i / rate - leadSilence;
    if (t < 0 || t >= musicSec) continue;
    final m = t % p;
    final h = (t + p / 2) % p;
    var v = 0.7 * sin(2 * pi * (50 + 90 * exp(-m * 30)) * m) * exp(-m * 10) +
        0.12 * (rnd.nextDouble() * 2 - 1) * exp(-h * 50) +
        0.06 * sin(2 * pi * 220 * t) +
        0.05 * sin(2 * pi * 329.6 * t);
    if (fadeSec > 0 && t > musicSec - fadeSec) v *= (musicSec - t) / fadeSec;
    out[i] = (v * gain * 32767 * 0.8).round().clamp(-32768, 32767);
  }
  return out;
}

Int16List noise(double sec, {int seed = 3}) {
  final rnd = Random(seed);
  final out = Int16List((sec * rate).round());
  // slowly swelling filtered noise, no beat
  var y = 0.0;
  for (var i = 0; i < out.length; i++) {
    y = 0.97 * y + 0.03 * (rnd.nextDouble() * 2 - 1);
    final swell = 0.5 + 0.5 * sin(2 * pi * i / rate / 15);
    out[i] = (y * 9000 * swell).round();
  }
  return out;
}

String? _ffmpeg() {
  for (final p in ['/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/opt/homebrew/bin/ffmpeg']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  group('analysis on synthetic audio', () {
    test('tempo, beat grid, silence and fade are found', () {
      final a = analyzePcm(synth(bpm: 124, musicSec: 30, leadSilence: 1.5, tailSilence: 8, fadeSec: 6), rate);
      expect(a.bpm, closeTo(124, 1.0));
      expect(a.hasBeat, isTrue);
      expect(a.audioStartMs, closeTo(1500, 200));
      // the fade ends at 31.5 s; the last ~0.5 s of it is below the silence line
      expect(a.audioEndMs, inInclusiveRange(30300, 31600));
      expect(a.fadesOut, isTrue);
      expect(a.outroStartMs, inInclusiveRange(25000, a.audioEndMs - 1500));
      // beats are ~484 ms apart and sit inside the music
      final gaps = [for (var i = 1; i < a.beatsMs.length; i++) a.beatsMs[i] - a.beatsMs[i - 1]];
      gaps.sort();
      expect(gaps[gaps.length ~/ 2], closeTo(60000 / 124, 15));
      expect(a.beatsMs.first, greaterThanOrEqualTo(1400));
      expect(a.beatsMs.last, lessThanOrEqualTo(a.audioEndMs + 60));
      // beats line up with the kicks (every 60/124 s from 1.5 s)
      final p = 60000 / 124;
      for (final b in a.beatsMs.take(20)) {
        final off = ((b - 1500) % p);
        expect(min(off, p - off), lessThan(40), reason: 'beat at $b ms');
      }
    });

    test('a song with no beat is not beat-matched', () {
      final a = analyzePcm(noise(40), rate);
      expect(a.hasBeat, isFalse);
    });

    test('slow and fast tempos', () {
      expect(analyzePcm(synth(bpm: 82, musicSec: 30), rate).bpm, closeTo(82, 1));
      expect(analyzePcm(synth(bpm: 140, musicSec: 30), rate).bpm, closeTo(140, 1.2));
    });

    test('loudness follows the level (10 dB quieter reads ~10 dB lower)', () {
      final loud = analyzePcm(synth(bpm: 120, musicSec: 20), rate);
      final quiet = analyzePcm(synth(bpm: 120, musicSec: 20, gain: 0.316), rate);
      expect(loud.loudnessDb - quiet.loudnessDb, closeTo(10, 0.8));
    });

    test('hidden track after a long silence: the music before the gap is the end', () {
      final first = synth(bpm: 100, musicSec: 40, tailSilence: 20);
      final hidden = synth(bpm: 120, musicSec: 10, seed: 9);
      final all = Int16List(first.length + hidden.length)
        ..setAll(0, first)
        ..setAll(first.length, hidden);
      final a = analyzePcm(all, rate);
      expect(a.audioEndMs, closeTo(40000, 400));
    });

    test('silence, tiny files and very short songs don\'t break it', () {
      expect(analyzePcm(Int16List(rate * 10), rate).hasBeat, isFalse);
      expect(analyzePcm(Int16List(100), rate).durationMs, 9);
      final s = analyzePcm(synth(bpm: 120, musicSec: 12), rate);
      expect(s.durationMs, 12000);
      expect(s.audioEndMs, lessThanOrEqualTo(12000));
    });

    test('saved and read back the same (analysis cache)', () {
      final a = analyzePcm(synth(bpm: 124, musicSec: 20, leadSilence: 1), rate);
      final b = TrackAnalysis.fromJson(a.toJson())!;
      expect(b.beatsMs, a.beatsMs);
      expect(b.bpm, closeTo(a.bpm, 0.001));
      expect(b.audioStartMs, a.audioStartMs);
      expect(b.downbeat, a.downbeat);
      expect(TrackAnalysis.fromJson({...a.toJson(), 'v': 1}), isNull); // old format is redone
    });
  });

  group('analysis on real decoded audio files (ffmpeg-made, Opus + AAC)', () {
    final ff = _ffmpeg();
    late Directory dir;
    setUpAll(() {
      if (ff == null) return;
      dir = Directory.systemTemp.createTempSync('byte_automix_');
    });
    tearDownAll(() {
      if (ff != null && dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<Int16List> make(String name, String lavfi, String af, String codec) async {
      final wav = '${dir.path}/$name.wav';
      final enc = '${dir.path}/$name.${codec == 'libopus' ? 'webm' : 'm4a'}';
      final raw = '$enc.raw';
      Future<void> run(List<String> a) async {
        final r = await Process.run(ff!, ['-v', 'error', '-y', ...a]);
        if (r.exitCode != 0) fail('ffmpeg: ${r.stderr}');
      }

      if (!File(wav).existsSync()) await run(['-f', 'lavfi', '-i', lavfi, '-af', af, '-ac', '2', wav]);
      await run(['-i', wav, '-c:a', codec, '-b:a', '128k', enc]);
      // the same thing the phone's decoder delivers: mono 16-bit at 11025 Hz
      await run(['-i', enc, '-ac', '1', '-ar', '$rate', '-f', 's16le', raw]);
      final b = File(raw).readAsBytesSync();
      return Int16List.view(Uint8List.fromList(b).buffer, 0, b.length ~/ 2);
    }

    String drums(double bpm, double sec) {
      final p = 60 / bpm;
      return "aevalsrc='0.7*sin(2*PI*(50+90*exp(-mod(t,$p)*30))*mod(t,$p))*exp(-mod(t,$p)*10)"
          "+0.12*(random(0)*2-1)*exp(-mod(t+${p / 2},$p)*50)+0.06*sin(2*PI*220*t)+0.05*sin(2*PI*329.6*t)':s=44100:d=$sec";
    }

    for (final codec in ['libopus', 'aac']) {
      test('128 bpm, 2 s silent intro, 8 s fade, 10 s silent outro ($codec)', () async {
        final a = analyzePcm(await make('t128', drums(128, 40), 'afade=t=out:st=32:d=8,adelay=2000|2000,apad=pad_dur=10', codec), rate);
        expect(a.bpm, closeTo(128, 0.6));
        expect(a.hasBeat, isTrue);
        expect(a.audioStartMs, closeTo(2000, 200));
        expect(a.audioEndMs, inInclusiveRange(40500, 42200));
        expect(a.fadesOut, isTrue);
        expect(a.durationMs, closeTo(52000, 200));
      }, skip: ff == null ? 'ffmpeg not installed' : false);

      test('95 bpm abrupt ending ($codec)', () async {
        final a = analyzePcm(await make('t95', drums(95, 60), 'anull', codec), rate);
        expect(a.bpm, closeTo(95, 0.5));
        expect(a.fadesOut, isFalse);
        expect(a.audioEndMs, closeTo(60000, 300));
      }, skip: ff == null ? 'ffmpeg not installed' : false);

      test('beatless ambient noise ($codec)', () async {
        final a = analyzePcm(
          await make('amb', 'anoisesrc=c=pink:a=0.1:d=45', "lowpass=600,volume='0.5+0.5*sin(2*PI*t/15)':eval=frame", codec),
          rate,
        );
        expect(a.hasBeat, isFalse);
      }, skip: ff == null ? 'ffmpeg not installed' : false);

      test('short 20 s song ($codec)', () async {
        final a = analyzePcm(await make('s20', drums(120, 20), 'anull', codec), rate);
        expect(a.bpm, closeTo(120, 0.6));
        final plan = planTransition(outDurationMs: a.durationMs, out: a, inn: a, inDurationMs: a.durationMs, seconds: 12, mode: AutomixMode.smart);
        expect(plan.fadeMs, lessThanOrEqualTo(a.durationMs ~/ 3));
        expect(plan.startAtMs, greaterThan(a.durationMs ~/ 2));
      }, skip: ff == null ? 'ffmpeg not installed' : false);
    }
  });

  group('transition plans', () {
    TrackAnalysis track({double bpm = 120, int dur = 200000, int start = 0, int end = 200000, int outro = 200000, double loud = -12, double conf = 0.9, int downbeat = 0, double energy = 0.6, int firstBeat = 0}) {
      final p = 60000 / bpm;
      final beats = <int>[];
      for (var t = firstBeat.toDouble(); t <= end; t += p) {
        if (t >= start) beats.add(t.round());
      }
      return TrackAnalysis(
        durationMs: dur,
        bpm: bpm,
        beatConfidence: conf,
        beatsMs: beats,
        downbeat: downbeat,
        loudnessDb: loud,
        audioStartMs: start,
        introEndMs: start,
        outroStartMs: outro,
        audioEndMs: end,
        energy: energy,
      );
    }

    test('smart: beat-matched, lands on downbeats, gentle tempo nudge, loudness matched', () {
      final a = track(bpm: 124, end: 196000, outro: 196000, loud: -8);
      final b = track(bpm: 120, start: 1200, firstBeat: 1200, loud: -15);
      final pl = planTransition(outDurationMs: 200000, out: a, inn: b, inDurationMs: 200000, seconds: 8, mode: AutomixMode.smart);
      expect(pl.kind, 'smart');
      expect(pl.beatMatched, isTrue);
      expect(pl.tempoRatio, closeTo(124 / 120, 0.001));
      expect(pl.fadeMs, 8000);
      expect(a.beatsMs, contains(pl.startAtMs));
      expect(a.isDownbeat(a.beatsMs.indexOf(pl.startAtMs)), isTrue);
      expect(b.beatsMs, contains(pl.incomingFromMs));
      expect(pl.startAtMs, inInclusiveRange(196000 - 8000 - 2000, 196000 - 8000));
      expect(pl.outGain, closeTo(pow(10, -6 / 20), 0.01)); // -8 → -14
      expect(pl.inGain, 1.0); // quieter than the target: never boosted
      expect(pl.bassSwap, isTrue);
    });

    test('octave tempos match (90 ↔ 180 bpm)', () {
      final pl = planTransition(outDurationMs: 200000, out: track(bpm: 90), inn: track(bpm: 178), inDurationMs: 200000, seconds: 8, mode: AutomixMode.smart);
      expect(pl.beatMatched, isTrue);
      expect(pl.tempoRatio, closeTo(90 / 89, 0.002));
    });

    test('tempos too far apart: no stretching, a shorter clean blend', () {
      final pl = planTransition(outDurationMs: 200000, out: track(bpm: 128), inn: track(bpm: 100), inDurationMs: 200000, seconds: 12, mode: AutomixMode.smart);
      expect(pl.beatMatched, isFalse);
      expect(pl.tempoRatio, 1);
      expect(pl.fadeMs, lessThanOrEqualTo(6000));
    });

    test('long silent outro is skipped: the blend starts before the silence', () {
      final a = track(dur: 240000, end: 200000, outro: 200000);
      final pl = planTransition(outDurationMs: 240000, out: a, inn: track(), inDurationMs: 200000, seconds: 8, mode: AutomixMode.smart);
      expect(pl.startAtMs + pl.fadeMs, lessThanOrEqualTo(200000 + 500));
      expect(pl.startAtMs, lessThan(200000 - 6000));
    });

    test('a song that fades out by itself keeps its own fade', () {
      final a = track(end: 196000, outro: 184000);
      final pl = planTransition(outDurationMs: 200000, out: a, inn: track(), inDurationMs: 200000, seconds: 8, mode: AutomixMode.smart);
      expect(pl.outFadesItself, isTrue);
      expect(pl.fadeMs, inInclusiveRange(8000, 12000));
      final (outMid, _) = pl.volumes(0.5);
      expect(outMid, 1.0);
    });

    test('short songs (< 30 s) get short blends', () {
      final a = track(dur: 20000, end: 20000, outro: 20000);
      final b = track(dur: 25000, end: 25000, outro: 25000);
      final pl = planTransition(outDurationMs: 20000, out: a, inn: b, inDurationMs: 25000, seconds: 12, mode: AutomixMode.smart);
      expect(pl.fadeMs, lessThanOrEqualTo(20000 ~/ 3));
      expect(pl.startAtMs, greaterThanOrEqualTo(10000));
    });

    test('incoming song with a long beatless intro: blended over, not beat-matched', () {
      final b = track(start: 500, firstBeat: 15000);
      final pl = planTransition(outDurationMs: 200000, out: track(), inn: b, inDurationMs: 200000, seconds: 8, mode: AutomixMode.smart);
      expect(pl.beatMatched, isFalse);
      expect(pl.incomingFromMs, 500);
    });

    test('simple mode and missing analysis fall back to a crossfade', () {
      final simple = planTransition(outDurationMs: 200000, out: track(end: 190000), inn: track(start: 800), inDurationMs: 200000, seconds: 6, mode: AutomixMode.simple);
      expect(simple.kind, 'simple');
      expect(simple.beatMatched, isFalse);
      expect(simple.startAtMs, 184000);
      expect(simple.incomingFromMs, 800);
      final none = planTransition(outDurationMs: 200000, seconds: 6, mode: AutomixMode.smart, outFallbackGain: 0.7);
      expect(none.kind, 'fallback');
      expect(none.startAtMs, 194000);
      expect(none.outGain, 0.7);
      final half = planTransition(outDurationMs: 200000, inn: track(start: 900), inDurationMs: 200000, seconds: 6, mode: AutomixMode.smart);
      expect(half.kind, 'fallback');
      expect(half.incomingFromMs, 900);
    });

    test('volume curves, bass swap and tempo ease', () {
      const pl = TransitionPlan(startAtMs: 0, incomingFromMs: 0, fadeMs: 8000, tempoRatio: 1.03, bassSwap: true, kind: 'smart');
      expect(pl.volumes(0), (1.0, 0.0));
      final (o1, i1) = pl.volumes(1);
      expect(o1, closeTo(0, 1e-9));
      expect(i1, 1.0);
      var lastIn = -1.0, lastOut = 2.0;
      for (var t = 0.0; t <= 1.0; t += 0.05) {
        final (o, i) = pl.volumes(t);
        expect(i, greaterThanOrEqualTo(lastIn));
        expect(o, lessThanOrEqualTo(lastOut));
        lastIn = i;
        lastOut = o;
      }
      expect(pl.lowCut(0.1), (0.0, 1.0));
      expect(pl.lowCut(0.9), (1.0, 0.0));
      expect(pl.speedAt(4000), 1.03);
      expect(pl.speedAt(8000 + 2000), closeTo(1.015, 1e-9));
      expect(pl.speedAt(30000), 1.0);
      final late = pl.startingLate(195000, 196000);
      expect(late.fadeMs, 1500);
      expect(late.tempoRatio, 1);
      expect(late.bassSwap, isFalse);
    });

    test('smart shuffle picks the smoothest next song', () {
      final cur = track(bpm: 124, energy: 0.7);
      final i = pickSmoothestNext(cur, [track(bpm: 90, energy: 0.2), null, track(bpm: 123, energy: 0.68), track(bpm: 140, energy: 0.9)]);
      expect(i, 2);
      expect(pickSmoothestNext(cur, [track(bpm: 124, energy: 0.7), track(bpm: 124, energy: 0.7)]), 0); // keeps the order on a tie
      expect(pickSmoothestNext(null, [track(), track()]), 0);
    });
  });
}
