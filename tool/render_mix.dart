// ignore_for_file: avoid_print
// Dev check: renders an Automix blend offline from two decoded songs (mono
// s16le 11025 Hz) with the real planner, and scores how well the beats line
// up in the overlap (vs. the same blend shifted half a beat).
// dart run tool/render_mix.dart a.raw b.raw out.wav
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:byte/automix/analysis.dart';
import 'package:byte/automix/planner.dart';

const rate = 11025;

Int16List load(String p) {
  final b = File(p).readAsBytesSync();
  return Int16List.view(Uint8List.fromList(b).buffer, 0, b.length ~/ 2);
}

/// Mixes the overlap: [shiftMs] moves the incoming song (to test misalignment).
Int16List render(Int16List a, Int16List b, TransitionPlan pl, {int shiftMs = 0, int padMs = 3000}) {
  final s0 = ((pl.startAtMs - padMs) * rate / 1000).round();
  final len = ((pl.fadeMs + 2 * padMs) * rate / 1000).round();
  final out = Int16List(len);
  final startS = pl.startAtMs * rate / 1000;
  final fromS = (pl.incomingFromMs + shiftMs) * rate / 1000;
  for (var i = 0; i < len; i++) {
    final ia = s0 + i;
    final tMs = (ia - startS) * 1000 / rate; // ms since the blend started
    final t = (tMs / pl.fadeMs).clamp(0.0, 1.0);
    final (vo, vi) = tMs < 0 ? (1.0, 0.0) : pl.volumes(t);
    var x = ia >= 0 && ia < a.length ? a[ia] * vo * pl.outGain : 0.0;
    if (tMs >= 0) {
      // incoming position, with the tempo nudge (resampled)
      final pos = fromS + (ia - startS) * pl.tempoRatio;
      final k = pos.floor();
      if (k >= 0 && k + 1 < b.length) {
        final fr = pos - k;
        x += (b[k] * (1 - fr) + b[k + 1] * fr) * vi * pl.inGain;
      }
    }
    out[i] = x.round().clamp(-32768, 32767);
  }
  return out;
}

void writeWav(String path, Int16List pcm) {
  final bytes = BytesBuilder();
  void u32(int v) => bytes.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  void u16(int v) => bytes.add([v & 255, (v >> 8) & 255]);
  bytes.add('RIFF'.codeUnits);
  u32(36 + pcm.length * 2);
  bytes.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(rate);
  u32(rate * 2);
  u16(2);
  u16(16);
  bytes.add('data'.codeUnits);
  u32(pcm.length * 2);
  bytes.add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.length * 2));
  File(path).writeAsBytesSync(bytes.toBytes());
}

void main(List<String> args) {
  final a = load(args[0]), b = load(args[1]);
  final aa = analyzePcm(a, rate), ab = analyzePcm(b, rate);
  final pl = planTransition(outDurationMs: aa.durationMs, out: aa, inn: ab, inDurationMs: ab.durationMs, seconds: 8, mode: AutomixMode.smart);
  final mix = render(a, b, pl);
  if (args.length > 2) writeWav(args[2], mix);
  final good = analyzePcm(mix, rate);
  final g = debugLastAnalysis();
  final half = ab.beatMs > 0 ? (ab.beatMs / 2).round() : 250;
  analyzePcm(render(a, b, pl, shiftMs: half), rate);
  final bad = debugLastAnalysis();
  analyzePcm(render(a, b, pl, shiftMs: (half / 2).round()), rate);
  final q = debugLastAnalysis();
  String cl(String d) => RegExp(r'clarity ([\d.]+)').firstMatch(d)?.group(1) ?? '-';
  print('${args[0].split('/').last} -> ${args[1].split('/').last}: $pl');
  print('  out ${aa.bpm.toStringAsFixed(1)} bpm (conf ${aa.beatConfidence.toStringAsFixed(2)}), in ${ab.bpm.toStringAsFixed(1)} (conf ${ab.beatConfidence.toStringAsFixed(2)})');
  print('  beat clarity in the overlap: aligned ${cl(g)}, quarter-beat off ${cl(q)}, half-beat off ${cl(bad)}; mix tempo ${good.bpm.toStringAsFixed(1)}');
  if (args.length > 3) {
    File(args[3]).writeAsStringSync(jsonEncode({'start': pl.startAtMs, 'from': pl.incomingFromMs, 'fade': pl.fadeMs, 'ratio': pl.tempoRatio, 'beat': pl.beatMatched, 'kind': pl.kind, 'bpmA': aa.bpm, 'bpmB': ab.bpm, 'endA': aa.audioEndMs, 'durA': aa.durationMs, 'strA': aa.beatStrengthAt(pl.startAtMs), 'strB': ab.beatStrengthAt(pl.incomingFromMs + 2000)}));
  }
}
