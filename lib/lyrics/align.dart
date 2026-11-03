import 'lrc.dart';
import 'romanize.dart';

// Byte © 2026 Apurba Laskar.
//
// Lining lyrics up with the recording that is actually playing.
//
// Lyrics sites time a song to ONE cut of it (usually the album audio). The
// same song on YouTube is often another cut: a music video with a longer
// intro, a "full song" upload, a re-master. Those timings then run early or
// late by the difference, for the whole song (measured on Apurba's phone
// recording, "Mann Ki Lagan": the lyrics ran ~6 s ahead of the singing on the
// 5:08 video because every 5:08 entry on the lyrics site carries the 4:52
// album timings). YouTube's own captions for THAT upload (often generated
// from its audio) are timed to the audio that plays, so they tell us where
// the words really are: we find the one shift that lines most lyric words up
// with caption words, and move the lyrics by it.

final _indic = RegExp(r'[\u0900-\u0DFF]');

/// A loose spelling key so the same word written two ways still matches:
/// Indian scripts are spelled out in Latin, then vowels, h and doubled letters
/// are dropped ("लागी", "लगी", "laagi" → "lg"; "Lagan" → "lgn").
String wordKey(String w) {
  var s = w.toLowerCase();
  if (_indic.hasMatch(s)) s = romanizeLyric(s, capitalize: false).toLowerCase();
  s = s.replaceAll(RegExp(r'[^a-z0-9]'), '').replaceAll(RegExp(r'[aeiouyh]'), '');
  return s.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);
}

/// One timed caption word.
class TimedWord {
  final int ms;
  final String text;
  const TimedWord(this.ms, this.text);
}

/// The shift (ms) to ADD to every lyric time so it lines up with [caps], or
/// null when the captions don't agree with the lyrics well enough to say.
/// Returns 0 when the lyrics already line up.
int? lyricsShiftFromCaptions(List<LyricLine> lines, List<TimedWord> caps, {int maxShiftMs = 40000}) {
  if (lines.length < 4 || caps.length < 8) return null;
  // Estimated time of each lyric word (spread across its line).
  final byKey = <String, List<int>>{};
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.words != null && l.words!.isNotEmpty) {
      for (final w in l.words!) {
        final k = wordKey(w.text);
        if (k.length >= 2) (byKey[k] ??= []).add(w.startMs);
      }
      continue;
    }
    final toks = l.text.split(RegExp(r'[\s\-,.!?।]+')).where((x) => x.isNotEmpty).toList();
    if (toks.isEmpty) continue;
    final next = i + 1 < lines.length ? lines[i + 1].startMs : l.startMs + toks.length * 450;
    final span = (next - l.startMs).clamp(0, toks.length * 450);
    for (var m = 0; m < toks.length; m++) {
      final k = wordKey(toks[m]);
      if (k.length >= 2) (byKey[k] ??= []).add(l.startMs + span * m ~/ toks.length);
    }
  }
  const bin = 100, tol = 700;
  final nBins = maxShiftMs * 2 ~/ bin + 1;
  final votes = List<int>.filled(nBins, 0);
  var usable = 0;
  for (final c in caps) {
    final ts = byKey[wordKey(c.text)];
    if (ts == null) continue;
    usable++;
    final hit = <int>{};
    for (final t in ts) {
      final lo = ((c.ms - t - tol + maxShiftMs) / bin).ceil();
      final hi = ((c.ms - t + tol + maxShiftMs) / bin).floor();
      for (var b = lo; b <= hi; b++) {
        if (b >= 0 && b < nBins) hit.add(b);
      }
    }
    for (final b in hit) {
      votes[b]++;
    }
  }
  if (usable < 8) return null;
  var best = 0;
  for (var b = 1; b < nBins; b++) {
    if (votes[b] > votes[best]) best = b;
  }
  final top = votes[best];
  if (top < 8 || top < usable * 0.3) return null;
  // The best shift must clearly beat "no shift".
  final zero = maxShiftMs ~/ bin;
  var atZero = 0;
  for (var b = zero - 3; b <= zero + 3; b++) {
    if (b >= 0 && b < nBins && votes[b] > atZero) atZero = votes[b];
  }
  final shiftGuess = best * bin - maxShiftMs;
  // Under 1.5 s the captions' own timing slop is too close to call: leave it
  // (the person's −/+ nudge is there for that).
  if (shiftGuess.abs() < 1500 || top < atZero * 1.25 + 2) return atZero >= top * 0.8 ? 0 : null;
  // Refine: the median gap of the word pairs that agree with the guess.
  final gaps = <int>[];
  for (final c in caps) {
    final ts = byKey[wordKey(c.text)];
    if (ts == null) continue;
    int? g;
    for (final t in ts) {
      final d = c.ms - t - shiftGuess;
      if (d.abs() <= tol && (g == null || d.abs() < (g - shiftGuess).abs())) g = c.ms - t;
    }
    if (g != null) gaps.add(g);
  }
  gaps.sort();
  final shift = gaps.isEmpty ? shiftGuess : gaps[gaps.length ~/ 2];
  return shift.abs() < 1500 ? 0 : shift;
}

/// [lines] moved later by [shiftMs] (earlier when negative).
List<LyricLine> shiftLyricLines(List<LyricLine> lines, int shiftMs) => [
  for (final l in lines)
    LyricLine(
      (l.startMs + shiftMs).clamp(0, 1 << 30),
      l.text,
      l.words == null ? null : [for (final w in l.words!) LyricWord(w.text, (w.startMs + shiftMs).clamp(0, 1 << 30), (w.endMs + shiftMs).clamp(0, 1 << 30))],
    ),
];

/// Caption words from YouTube's json3 timed text (word-level when the track
/// has it, else one entry per caption at its start).
List<TimedWord> json3Words(dynamic j) {
  final out = <TimedWord>[];
  final events = (j is Map ? j['events'] as List? : null) ?? const [];
  for (final e in events.whereType<Map>()) {
    final t0 = (e['tStartMs'] as num?)?.toInt();
    if (t0 == null) continue;
    for (final s in (e['segs'] as List? ?? const []).whereType<Map>()) {
      final text = '${s['utf8'] ?? ''}'.trim();
      if (text.isEmpty || text.startsWith('[')) continue;
      final off = (s['tOffsetMs'] as num?)?.toInt() ?? 0;
      final parts = text.split(RegExp(r'\s+'));
      for (var i = 0; i < parts.length; i++) {
        out.add(TimedWord(t0 + off + i * 300, parts[i]));
      }
    }
  }
  return out;
}

/// YouTube Music's own timed lyrics (the mobile app's lyrics page), or null
/// when that page only has plain lines.
List<LyricLine>? parseYtmTimedLyrics(dynamic browse) {
  List? data;
  void walk(dynamic o) {
    if (data != null) return;
    if (o is Map) {
      if (o['timedLyricsData'] is List) {
        data = o['timedLyricsData'] as List;
        return;
      }
      o.values.forEach(walk);
    } else if (o is List) {
      o.forEach(walk);
    }
  }

  walk(browse);
  if (data == null) return null;
  final out = <LyricLine>[];
  for (final x in data!.whereType<Map>()) {
    final cue = x['cueRange'];
    final start = cue is Map ? int.tryParse('${cue['startTimeMilliseconds']}') : null;
    if (start == null) return null; // untimed lines
    final text = '${x['lyricLine'] ?? ''}'.trim();
    out.add(LyricLine(start, text == '♪' ? '' : text));
  }
  while (out.isNotEmpty && out.first.isBreak && out.first.startMs == 0) {
    out.removeAt(0);
  }
  return out.where((l) => !l.isBreak).length >= 3 ? out : null;
}
