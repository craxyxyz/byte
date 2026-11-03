// Byte © 2026 Apurba Laskar.
// Dual lyrics: a song whose lyrics are in another script (Urdu, Hindi,
// Bengali, Punjabi, Tamil, Telugu…) shows the original and, beside it, the
// SAME words in Roman letters ("مجھ سے مل پائے گا نہیں" ↔ "Mujh se mil paaye
// ga nahin"), line by line, word by word, on one clock.
//
// Where the Roman words come from, best first:
//  1. a Roman-letter version of the same song from the lyric sources
//     (people type these by hand: the spelling everyone knows);
//  2. a Devanagari version of the song, read by Byte's Indic rules (or the
//     lyrics themselves when they are in an Indian script);
//  3. Byte's own Urdu reader (a dictionary of song words plus letter rules).
// Versions are matched to the original by their WORDS, not their timings
// (another upload's timings can be 25 s off), so every Roman word sits under
// the original word it says, and the word fill runs on both together.
// Pure Dart, unit tested.

import 'dart:math' as math;
import 'dart:typed_data';

import 'lrc.dart';
import 'romanize.dart';
import 'script.dart' show hasDevanagari;
import 'urdu_roman.dart';

/// How a Roman line was made (the numbers are the order of preference).
enum DualRoute {
  romanVersion(1, 'Roman-letter version of the song'),
  devanagariVersion(2, 'Hindi-letter version of the song'),
  scriptRules(2, 'Indian-script reading'),
  urduReader(3, 'Urdu reading');

  final int rank;
  final String label;
  const DualRoute(this.rank, this.label);
}

/// True when [s] is mostly in a script people may not read: Arabic script
/// (Urdu) or an Indian script (Devanagari, Bengali, Gurmukhi, Tamil…).
/// English, and Hindi already typed in Roman letters, are not.
bool needsDualText(String s) {
  var other = 0, latin = 0;
  for (final r in s.runes) {
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) || (r >= 0xC0 && r <= 0x24F)) {
      latin++;
    } else if ((r >= 0x0900 && r <= 0x0D7F) || (r >= 0x0620 && r <= 0x06FF) || (r >= 0x0750 && r <= 0x077F)) {
      other++;
    }
  }
  return other > 0 && other * 2 >= latin; // Punjabi lines with a few English words count
}

/// True when [l]'s words are mostly in a non-Latin script we can spell in Roman.
bool lyricsNeedDual(Lyrics l) {
  if (l.kind == LyricsKind.none) return false;
  final sample = l.kind == LyricsKind.synced ? l.lines.take(40).map((x) => x.text).join(' ') : (l.plain ?? '').split('\n').take(40).join(' ');
  return needsDualText(sample);
}

/// Right-to-left text (Urdu, Arabic): laid out from the right.
bool isRtlText(String s) => hasArabicLetters(s);

/// One original word in Roman letters by Byte's own rules (route 2 / 3).
String localRomanWord(String w) {
  if (hasArabicLetters(w)) return romanizeUrduWord(w);
  if (hasIndicLetters(w)) {
    final m = RegExp(r'^(.*?)(\s*)$', dotAll: true).firstMatch(w)!;
    return romanizeLyric(m.group(1)!, capitalize: false) + m.group(2)!;
  }
  return w;
}

/// A line's words in Roman letters by Byte's own rules, one per word
/// (Urdu reads a few words by their place in the line).
List<String> localRomanWords(List<String> words) {
  if (words.any(hasArabicLetters)) return romanizeUrduWords(words);
  return [for (final w in words) localRomanWord(w)];
}

DualRoute _localRoute(String w) => hasArabicLetters(w) ? DualRoute.urduReader : DualRoute.scriptRules;

// ── matching words by their sound ───────────────────────────────────────

/// The consonants of a Roman word, in sound classes, vowels and h/w/y left
/// out: "paaye" → "p", "raahein" → "rn", "mohabbat" → "mbt". Spellings of
/// one word ("dekhun" / "dekhoon" / "dekhu") give the same skeleton.
String soundSkeleton(String roman) {
  var s = roman.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  const di = {'ph': 'f', 'kh': 'k', 'gh': 'g', 'chh': 'c', 'ch': 'c', 'sh': 's', 'zh': 'j', 'th': 't', 'dh': 'd', 'bh': 'b', 'jh': 'j', 'ck': 'k'};
  for (final e in di.entries) {
    s = s.replaceAll(e.key, e.value);
  }
  final out = StringBuffer();
  String? last;
  for (final ch in s.split('')) {
    var c = switch (ch) {
      'q' || 'x' => 'k',
      'z' => 'j',
      'w' => 'v',
      'a' || 'e' || 'i' || 'o' || 'u' || 'y' || 'h' || 'v' => '',
      _ => ch,
    };
    if (c.isEmpty) continue;
    if (c == last) continue; // "acchha" = "achha"
    out.write(c);
    last = c;
  }
  return out.toString();
}

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}

/// 0..1: how alike two skeletons sound.
double skeletonSimilarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 0.75; // "o" / "ae" / "hai": no consonants to compare
  if (a.isEmpty || b.isEmpty) return 0;
  return 1 - _lev(a, b) / math.max(a.length, b.length);
}

/// 0..1 likeness of two Roman spellings, vowels included ("aaye ga" / "aayega").
double _looseSim(String a, String b) {
  final x = a.toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''), y = b.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (x.isEmpty || y.isEmpty) return 0;
  return 1 - _lev(x, y) / math.max(x.length, y.length);
}

String _letters(String w) => w.replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}\x27]', unicode: true), '');

// ── the result ───────────────────────────────────────────────────────────

/// One line's Roman words, one per original word (same order, same count:
/// word k says what original word k says; '' when the Roman spelling joined
/// two original words into one).
class DualLine {
  final List<String> words;
  final DualRoute? route;
  const DualLine(this.words, this.route);
  String get text => words.join().trimRight();
}

class DualLyrics {
  final Lyrics original;

  /// One per original line (synced) or per text line (plain).
  final List<DualLine> lines;
  const DualLyrics(this.original, this.lines);

  /// The best route used, for the caption ("Roman letters · from a Roman-letter version").
  DualRoute? get mainRoute {
    final counts = <DualRoute, int>{};
    for (final l in lines) {
      if (l.route != null) counts[l.route!] = (counts[l.route!] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  /// The Roman lines as lyrics of their own, timed so that word k fills
  /// exactly when original word k does (also for lines without word
  /// timings: their estimated fill is turned into timings). Used by the
  /// mini line and the left column.
  Lyrics get roman {
    if (original.kind == LyricsKind.plain) return Lyrics.plain(lines.map((l) => l.text).join('\n'), original.source);
    if (original.kind != LyricsKind.synced) return original;
    final clock = LyricsClock(original.lines, trackDurationMs: original.durationMs);
    final out = <LyricLine>[];
    for (var i = 0; i < original.lines.length; i++) {
      final o = original.lines[i];
      final d = i < lines.length ? lines[i] : null;
      if (d == null || o.isBreak || d.words.isEmpty) {
        out.add(o);
        continue;
      }
      final words = <LyricWord>[];
      if (o.words != null && o.words!.length == d.words.length) {
        for (var k = 0; k < d.words.length; k++) {
          words.add(LyricWord(d.words[k], o.words![k].startMs, o.words![k].endMs));
        }
      } else {
        // the same windows LyricsClock.wordFill gives the original words
        final parts = splitWords(o.text);
        final total = parts.fold<int>(0, (a, w) => a + w.trim().length + 1);
        final dur = clock.singDuration(i);
        var acc = 0;
        for (var k = 0; k < d.words.length; k++) {
          final len = k < parts.length ? parts[k].trim().length + 1 : 1;
          final s = o.startMs + (acc * dur / total).round();
          acc += len;
          words.add(LyricWord(d.words[k], s, o.startMs + (math.min(acc, total) * dur / total).round()));
        }
      }
      out.add(LyricLine(o.startMs, d.text, words));
    }
    return Lyrics.synced(out, original.source, durationMs: original.durationMs, shiftedMs: original.shiftedMs);
  }
}

/// The words of each original line, as the lyrics screen splits them.
List<List<String>> originalWords(Lyrics l) {
  if (l.kind == LyricsKind.synced) return [for (final x in l.lines) x.words?.map((w) => w.text).toList() ?? splitWords(x.text)];
  if (l.kind == LyricsKind.plain) return [for (final t in (l.plain ?? '').split('\n')) splitWords(t)];
  return const [];
}

/// The lines of another version of the song, as plain text lines.
List<String> versionLines(Lyrics l) => l.kind == LyricsKind.synced ? [for (final x in l.lines) x.text] : (l.plain ?? '').split('\n');

/// Builds the Roman side of [original] from the other versions of the song
/// the sources had ([versions]: Roman or Devanagari ones; others ignored).
DualLyrics buildDual(Lyrics original, {List<Lyrics> versions = const []}) {
  final ow = originalWords(original);
  // local reading first (route 2 for Indian scripts, 3 for Urdu)
  final local = [for (final words in ow) localRomanWords(words)];
  final skeletons = [
    for (final words in local)
      [for (final w in words) soundSkeleton(w)],
  ];
  final chosen = List<DualLine?>.filled(ow.length, null);

  // try versions: Roman ones first (route 1), then Devanagari (route 2)
  final roman = <List<String>>[];
  final deva = <List<String>>[];
  for (final v in versions) {
    final lines = versionLines(v).where((t) => t.trim().isNotEmpty).toList();
    if (lines.isEmpty || lyricsNeedDual(v) && !hasDevanagari(lines.join())) continue;
    if (!lyricsNeedDual(v)) {
      roman.add(lines);
    } else if (hasDevanagari(lines.join()) && !hasArabicLetters(lines.join())) {
      deva.add(lines);
    }
  }
  for (final (route, list) in [(DualRoute.romanVersion, roman), (DualRoute.devanagariVersion, deva)]) {
    // the version that matches most words wins; each line still checks itself
    _Match? best;
    for (final lines in list) {
      final m = _matchVersion(ow, local, skeletons, lines, devanagari: route == DualRoute.devanagariVersion);
      if (m != null && (best == null || m.coverage > best.coverage)) best = m;
    }
    if (best == null || best.coverage < 0.45) continue;
    for (var i = 0; i < ow.length; i++) {
      if (chosen[i] != null) continue;
      final w = best.lineWords[i];
      if (w != null) chosen[i] = DualLine(w, route);
    }
  }
  final out = <DualLine>[];
  for (var i = 0; i < ow.length; i++) {
    if (chosen[i] != null) {
      out.add(_tidy(chosen[i]!, ow[i]));
      continue;
    }
    final words = local[i];
    final route = ow[i].any((w) => hasArabicLetters(w) || hasIndicLetters(w)) ? _localRoute(ow[i].firstWhere((w) => hasArabicLetters(w) || hasIndicLetters(w))) : null;
    out.add(_tidy(DualLine(words, route), ow[i]));
  }
  return DualLyrics(original, out);
}

/// Capital letter at the start of the line and after ? ! .
DualLine _tidy(DualLine l, List<String> orig) {
  if (l.words.isEmpty) return l;
  final w = [...l.words];
  var cap = true;
  for (var i = 0; i < w.length; i++) {
    if (w[i].trim().isEmpty) continue;
    if (cap) w[i] = capitalizeFirst(w[i]);
    cap = RegExp(r'[?!.]["\u201d)]?\s*$').hasMatch(w[i]);
  }
  return DualLine(w, l.route);
}

class _Match {
  final List<List<String>?> lineWords;
  final double coverage;
  _Match(this.lineWords, this.coverage);
}

/// Word-level alignment (Needleman–Wunsch, with 2↔1 joins) of the original
/// words against another version's words, by sound skeleton.
_Match? _matchVersion(List<List<String>> ow, List<List<String>> local, List<List<String>> oSkel, List<String> versionLines, {required bool devanagari}) {
  // version words: (text to show, skeleton)
  final cText = <String>[];
  final cSkel = <String>[];
  for (final line in versionLines) {
    for (final raw in splitWords(line)) {
      final core = _letters(raw);
      if (core.isEmpty) continue;
      final shown = devanagari ? romanizeLyric(core, capitalize: false) : core;
      cText.add(shown);
      cSkel.add(soundSkeleton(shown));
    }
  }
  // original words flattened
  final oLine = <int>[];
  final oIdx = <int>[];
  final oSk = <String>[];
  final oLoc = <String>[];
  for (var i = 0; i < ow.length; i++) {
    for (var k = 0; k < ow[i].length; k++) {
      if (_letters(ow[i][k]).isEmpty) continue;
      oLine.add(i);
      oIdx.add(k);
      oSk.add(oSkel[i][k]);
      oLoc.add(local[i][k]);
    }
  }
  final n = oSk.length, m = cSkel.length;
  if (n == 0 || m == 0 || n * m > 4000000) return null;
  // how alike two words are: mostly their consonants, the vowels break ties
  // ("to aaye ga" → "to aayega", not "to" + "aaye" + "aayega")
  String lo(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  final oLo = [for (final s in oLoc) lo(s)];
  final cLo = [for (final s in cText) lo(s)];
  double like(String sa, String la, String sb, String lb) {
    final loose = la.isEmpty || lb.isEmpty ? 0.0 : 1 - _lev(la, lb) / math.max(la.length, lb.length);
    return 0.75 * skeletonSimilarity(sa, sb) + 0.25 * loose;
  }

  const gapO = -0.35, gapC = -0.25, joinCost = 0.15;
  final w = m + 1;
  final dp = Float64List((n + 1) * w);
  final bt = Uint8List((n + 1) * w); // 1 match, 2 gapO (skip original), 3 gapC (skip version), 4 join O2→C1, 5 split O1→C2
  for (var i = 1; i <= n; i++) {
    dp[i * w] = dp[(i - 1) * w] + gapO;
    bt[i * w] = 2;
  }
  for (var j = 1; j <= m; j++) {
    dp[j] = dp[j - 1] + gapC;
    bt[j] = 3;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      var best = dp[(i - 1) * w + j - 1] + 2 * like(oSk[i - 1], oLo[i - 1], cSkel[j - 1], cLo[j - 1]) - 1;
      var b = 1;
      final g1 = dp[(i - 1) * w + j] + gapO;
      if (g1 > best) {
        best = g1;
        b = 2;
      }
      final g2 = dp[i * w + j - 1] + gapC;
      if (g2 > best) {
        best = g2;
        b = 3;
      }
      if (i >= 2 && oLine[i - 2] == oLine[i - 1]) {
        final s = dp[(i - 2) * w + j - 1] + 2 * like(oSk[i - 2] + oSk[i - 1], oLo[i - 2] + oLo[i - 1], cSkel[j - 1], cLo[j - 1]) - 1 - joinCost;
        if (s > best) {
          best = s;
          b = 4;
        }
      }
      if (j >= 2) {
        final s = dp[(i - 1) * w + j - 2] + 2 * like(oSk[i - 1], oLo[i - 1], cSkel[j - 2] + cSkel[j - 1], cLo[j - 2] + cLo[j - 1]) - 1 - joinCost;
        if (s > best) {
          best = s;
          b = 5;
        }
      }
      dp[i * w + j] = best;
      bt[i * w + j] = b;
    }
  }
  // walk back: for each original word, the version text and how alike
  final got = List<String?>.filled(n, null);
  final sim = List<double>.filled(n, 0);
  var i = n, j = m;
  while (i > 0 || j > 0) {
    final b = bt[i * w + j];
    if (i > 0 && j > 0 && b == 1) {
      got[i - 1] = cText[j - 1];
      sim[i - 1] = skeletonSimilarity(oSk[i - 1], cSkel[j - 1]);
      i--;
      j--;
    } else if (b == 4) {
      final s = skeletonSimilarity(oSk[i - 2] + oSk[i - 1], cSkel[j - 1]);
      final a = skeletonSimilarity(oSk[i - 2], cSkel[j - 1]), b2 = skeletonSimilarity(oSk[i - 1], cSkel[j - 1]);
      // the version left out a word, or spelled two as one ("paaye ga" → "paayega")?
      // consonants can't tell when one word has none ("ho", "aaye"): the vowels decide
      final joined = _looseSim('${oLoc[i - 2]}${oLoc[i - 1]}', cText[j - 1]);
      final alone = _looseSim(oLoc[i - 1], cText[j - 1]);
      if (b2 >= 0.8 && (b2 > s || (b2 == s && alone > joined))) {
        // the version left out a word ("ho, jinhan" → "jinhan"): read it ourselves
        got[i - 1] = cText[j - 1];
        sim[i - 1] = b2;
        got[i - 2] = null;
        sim[i - 2] = 1;
      } else if (a >= 0.8 && (a > s || (a == s && _looseSim(oLoc[i - 2], cText[j - 1]) > joined))) {
        got[i - 2] = cText[j - 1];
        sim[i - 2] = a;
        got[i - 1] = null;
        sim[i - 1] = 1;
      } else {
        got[i - 2] = cText[j - 1];
        got[i - 1] = '';
        sim[i - 2] = s;
        sim[i - 1] = s;
      }
      i -= 2;
      j--;
    } else if (b == 5) {
      final s = skeletonSimilarity(oSk[i - 1], cSkel[j - 2] + cSkel[j - 1]);
      final a = skeletonSimilarity(oSk[i - 1], cSkel[j - 2]), b2 = skeletonSimilarity(oSk[i - 1], cSkel[j - 1]);
      if (math.max(a, b2) >= s) {
        got[i - 1] = a >= b2 ? cText[j - 2] : cText[j - 1]; // an extra word in the version
        sim[i - 1] = math.max(a, b2);
      } else {
        got[i - 1] = '${cText[j - 2]} ${cText[j - 1]}';
        sim[i - 1] = s;
      }
      i--;
      j -= 2;
    } else if (i > 0 && (b == 2 || j == 0)) {
      i--;
    } else {
      j--;
    }
  }
  // per line: take the version's words when most of them clearly match
  final lineWords = List<List<String>?>.filled(ow.length, null);
  var matchedWords = 0;
  var p = 0;
  for (var li = 0; li < ow.length; li++) {
    final start = p;
    while (p < n && oLine[p] == li) {
      p++;
    }
    final count = p - start;
    if (count == 0) continue;
    var strong = 0;
    for (var q = start; q < p; q++) {
      if ((got[q] != null || sim[q] == 1) && sim[q] >= 0.67) strong++;
    }
    if (strong / count < 0.6) continue;
    matchedWords += count;
    final words = <String>[];
    var q = start;
    for (var k = 0; k < ow[li].length; k++) {
      final orig = ow[li][k];
      if (q < p && oIdx[q] == k) {
        final g = got[q];
        final ok = g != null && sim[q] >= 0.5;
        if (!needsDualText(orig)) {
          words.add(orig); // an English word in the original stays as it is
        } else {
          words.add(!ok ? local[li][k] : (g.isEmpty ? '' : _withPunct(orig, g.toLowerCase())));
        }
        q++;
      } else {
        words.add(local[li][k]); // punctuation-only word
      }
    }
    lineWords[li] = words;
  }
  return _Match(lineWords, n == 0 ? 0 : matchedWords / n);
}

/// [text] with [orig]'s punctuation and trailing space ("مجھے، " → "mujhe, ").
String _withPunct(String orig, String text) {
  final m = RegExp(r'^([^\p{L}\p{M}\p{N}]*)(.*?)([^\p{L}\p{M}\p{N}\s]*)(\s*)$', unicode: true, dotAll: true).firstMatch(orig)!;
  String p(String s) => s.replaceAll('،', ',').replaceAll('؟', '?').replaceAll('۔', '.').replaceAll('।', '.').replaceAll('॥', '.');
  return '${p(m.group(1)!)}$text${p(m.group(3)!)}${m.group(4)!}';
}
