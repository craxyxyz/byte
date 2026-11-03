// Lyrics model + LRC parser + timing maths (pure Dart, unit tested).

class LyricWord {
  final String text; // includes its trailing space if any
  final int startMs;
  final int endMs;
  const LyricWord(this.text, this.startMs, this.endMs);
}

class LyricLine {
  final int startMs;
  final String text;

  /// Real per-word timings (enhanced LRC). Null when the source only has line timings.
  final List<LyricWord>? words;
  const LyricLine(this.startMs, this.text, [this.words]);
  /// An empty line, or one that is only music notes / dots ("♪", "…"): an instrumental gap.
  bool get isBreak => _breakRe.hasMatch(text);
}

enum LyricsKind { synced, plain, none }

class Lyrics {
  final LyricsKind kind;
  final List<LyricLine> lines; // synced
  final String? plain;
  final String source; // shown small under the lyrics, e.g. "LRCLIB"

  /// Length of the recording these timings were made for, when the source
  /// says (used to refuse timings made for another version of the song).
  final int? durationMs;

  /// How far Byte moved these timings to line them up with the upload that
  /// plays (ms, + = later); null when they were used as they came.
  final int? shiftedMs;
  const Lyrics._(this.kind, this.lines, this.plain, this.source, [this.durationMs, this.shiftedMs]);
  const Lyrics.none() : this._(LyricsKind.none, const [], null, '');
  factory Lyrics.synced(List<LyricLine> lines, String source, {int? durationMs, int? shiftedMs}) =>
      Lyrics._(LyricsKind.synced, lines, null, source, durationMs, shiftedMs);
  factory Lyrics.plain(String text, String source) => Lyrics._(LyricsKind.plain, const [], text, source);

  /// The words of synced lyrics, without their timings.
  String get text => kind == LyricsKind.plain ? (plain ?? '') : lines.map((l) => l.text).join('\n');
  bool get hasWordTimings => lines.any((l) => l.words != null);
}

final _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _wordTag = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');
final _metaTag = RegExp(r'^\[([a-zA-Z#]+):([^\]]*)\]\s*$');

int _ms(String m, String s, String? frac) {
  var f = 0;
  if (frac != null && frac.isNotEmpty) {
    f = switch (frac.length) {
      1 => int.parse(frac) * 100,
      2 => int.parse(frac) * 10,
      _ => int.parse(frac.substring(0, 3)),
    };
  }
  return int.parse(m) * 60000 + int.parse(s) * 1000 + f;
}

/// Parses LRC (line-synced) and enhanced LRC (`<mm:ss.xx>` word timings).
/// Returns lines sorted by time; empty list if [lrc] has no time tags.
List<LyricLine> parseLrc(String lrc) {
  var offset = 0;
  final raw = <(int, String)>[];
  for (var line in lrc.replaceAll('\r', '').split('\n')) {
    line = line.trimRight();
    if (line.isEmpty) continue;
    final meta = _metaTag.firstMatch(line);
    if (meta != null && !_timeTag.hasMatch(line)) {
      if (meta.group(1)!.toLowerCase() == 'offset') offset = int.tryParse(meta.group(2)!.trim()) ?? 0;
      continue;
    }
    final stamps = <int>[];
    var rest = line;
    while (true) {
      final m = _timeTag.matchAsPrefix(rest);
      if (m == null) break;
      stamps.add(_ms(m.group(1)!, m.group(2)!, m.group(3)));
      rest = rest.substring(m.end);
    }
    if (stamps.isEmpty) continue;
    for (final t in stamps) {
      raw.add((t, rest));
    }
  }
  raw.sort((a, b) => a.$1.compareTo(b.$1));
  final out = <LyricLine>[];
  for (var i = 0; i < raw.length; i++) {
    final start = (raw[i].$1 - offset).clamp(0, 1 << 30);
    final nextStart = i + 1 < raw.length ? (raw[i + 1].$1 - offset) : null;
    final body = raw[i].$2;
    if (_wordTag.hasMatch(body)) {
      final words = _parseWords(body, start, nextStart, offset);
      out.add(LyricLine(start, words.map((w) => w.text).join().trim(), words.isEmpty ? null : words));
    } else {
      out.add(LyricLine(start, body.trim()));
    }
  }
  return out;
}

List<LyricWord> _parseWords(String body, int lineStart, int? nextLineStart, int offset) {
  final marks = _wordTag.allMatches(body).toList();
  final words = <LyricWord>[];
  // text before the first tag belongs to the line start
  final lead = body.substring(0, marks.first.start);
  if (lead.trim().isNotEmpty) {
    words.add(LyricWord(lead, lineStart, _ms(marks.first.group(1)!, marks.first.group(2)!, marks.first.group(3)) - offset));
  }
  for (var i = 0; i < marks.length; i++) {
    final m = marks[i];
    final start = _ms(m.group(1)!, m.group(2)!, m.group(3)) - offset;
    final textEnd = i + 1 < marks.length ? marks[i + 1].start : body.length;
    final text = body.substring(m.end, textEnd);
    if (text.isEmpty) continue; // a closing tag
    int end;
    if (i + 1 < marks.length) {
      final n = marks[i + 1];
      end = _ms(n.group(1)!, n.group(2)!, n.group(3)) - offset;
    } else {
      end = nextLineStart ?? start + 800;
    }
    if (text.trim().isEmpty && words.isNotEmpty) {
      // pure whitespace between tags: attach to previous word
      final p = words.removeLast();
      words.add(LyricWord(p.text + text, p.startMs, p.endMs));
      continue;
    }
    words.add(LyricWord(text, start, end < start ? start : end));
  }
  return words;
}

/// Timing helper used by the lyrics view. [leadMs] lights a line a beat
/// before it is sung so the eye gets there with the voice. 1.4.1: 150 ms
/// (was 300). Apurba's phone recording showed the "late" feeling in 1.3/1.4
/// came from timings made for another cut of the song (6 s off, see
/// align.dart), not from the lead; the player's position already includes
/// the phone's own output delay (Bluetooth too), so a long lead only shows
/// lines early.
class LyricsClock {
  final List<LyricLine> lines;
  final int leadMs;
  final int? trackDurationMs;
  LyricsClock(this.lines, {this.leadMs = 150, this.trackDurationMs});

  /// Index of the active line at [posMs] (-1 before the first line).
  int indexAt(int posMs) {
    final p = posMs + leadMs;
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].startMs <= p) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  int lineEnd(int i) {
    if (i + 1 < lines.length) return lines[i + 1].startMs;
    final w = lines[i].words;
    if (w != null && w.isNotEmpty) return w.last.endMs;
    return trackDurationMs ?? lines[i].startMs + 5000;
  }

  /// How long the singer is actually on line [i] (for estimated word fill):
  /// the gap to the next line, but never longer than the words need.
  int singDuration(int i) {
    final gap = lineEnd(i) - lines[i].startMs;
    final chars = lines[i].text.length;
    final need = 700 + chars * 95;
    return gap.clamp(0, need < 1000 ? 1000 : need).toInt();
  }

  /// 0..1 progress through line [i] at [posMs].
  double lineProgress(int i, int posMs) {
    if (i < 0 || i >= lines.length) return 0;
    final words = lines[i].words;
    final start = lines[i].startMs;
    final end = words != null && words.isNotEmpty ? words.last.endMs : start + singDuration(i);
    if (end <= start) return posMs >= start ? 1 : 0;
    return ((posMs - start) / (end - start)).clamp(0.0, 1.0);
  }

  /// Fill fraction 0..1 for each word of line [i]. Real timings when
  /// present; otherwise spread across the line by letter count.
  List<double> wordFill(int i, int posMs) {
    final l = lines[i];
    if (l.words != null) {
      return [
        for (final w in l.words!) w.endMs <= w.startMs ? (posMs >= w.startMs ? 1.0 : 0.0) : ((posMs - w.startMs) / (w.endMs - w.startMs)).clamp(0.0, 1.0),
      ];
    }
    final parts = splitWords(l.text);
    final total = parts.fold<int>(0, (a, w) => a + w.trim().length + 1);
    final p = lineProgress(i, posMs) * total;
    var acc = 0.0;
    final out = <double>[];
    for (final w in parts) {
      final len = (w.trim().length + 1).toDouble();
      out.add(((p - acc) / len).clamp(0.0, 1.0));
      acc += len;
    }
    return out;
  }

  /// True when [posMs] sits in a long instrumental gap before line i+1
  /// (shown as animated dots). Returns the gap's (start, end) or null.
  (int, int)? breakAt(int posMs) {
    final i = indexAt(posMs);
    final gapStart = i < 0 ? 0 : (lines[i].isBreak ? lines[i].startMs : lines[i].startMs + singDuration(i));
    final next = i + 1 < lines.length ? lines[i + 1].startMs : null;
    if (next == null) return null;
    if (i >= 0 && !lines[i].isBreak && next - gapStart < 4000) return null;
    if (i < 0 && next < 3000) return null;
    if (posMs < gapStart || posMs >= next - leadMs) return null;
    return (gapStart, next);
  }
}

/// Splits a line into words keeping trailing spaces ("Hello ", "world").
List<String> splitWords(String text) {
  final out = <String>[];
  final re = RegExp(r'\S+\s*');
  for (final m in re.allMatches(text)) {
    out.add(m.group(0)!);
  }
  return out;
}


final _breakRe = RegExp(r'^[\s♪♫♬♩…·•.\-–—~*]*$');
