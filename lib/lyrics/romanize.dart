// Latin spelling of lyrics in Indian scripts (Hindi, Bengali, Punjabi,
// Gujarati, Odia, Tamil, Telugu, Kannada, Malayalam). The Unicode blocks of
// these scripts share one layout, so one table (by offset in the block) reads
// them all. Pure Dart, unit tested.

const _blocks = [0x0900, 0x0980, 0x0A00, 0x0A80, 0x0B00, 0x0B80, 0x0C00, 0x0C80, 0x0D00];

/// Scripts where a final consonant drops its "a" (kamal → "kamal", not "kamala").
const _dropFinalA = {0x0900, 0x0980, 0x0A00, 0x0A80, 0x0B00};

const _vowels = {
  0x05: 'a', 0x06: 'aa', 0x07: 'i', 0x08: 'ee', 0x09: 'u', 0x0A: 'oo', 0x0B: 'ri', 0x0C: 'li', //
  0x0D: 'e', 0x0E: 'e', 0x0F: 'e', 0x10: 'ai', 0x11: 'o', 0x12: 'o', 0x13: 'o', 0x14: 'au', 0x60: 'ri', 0x61: 'li',
};
const _consonants = {
  0x15: 'k',
  0x16: 'kh',
  0x17: 'g',
  0x18: 'gh',
  0x19: 'ng',
  0x1A: 'ch',
  0x1B: 'chh',
  0x1C: 'j',
  0x1D: 'jh',
  0x1E: 'ny',
  0x1F: 't',
  0x20: 'th',
  0x21: 'd',
  0x22: 'dh',
  0x23: 'n',
  0x24: 't',
  0x25: 'th',
  0x26: 'd',
  0x27: 'dh',
  0x28: 'n',
  0x29: 'n',
  0x2A: 'p',
  0x2B: 'ph',
  0x2C: 'b',
  0x2D: 'bh',
  0x2E: 'm',
  0x2F: 'y',
  0x30: 'r',
  0x31: 'r',
  0x32: 'l',
  0x33: 'l',
  0x34: 'zh',
  0x35: 'v',
  0x36: 'sh',
  0x37: 'sh',
  0x38: 's',
  0x39: 'h',
  0x58: 'q',
  0x59: 'kh',
  0x5A: 'g',
  0x5B: 'z',
  0x5C: 'd',
  0x5D: 'dh',
  0x5E: 'f',
  0x5F: 'y',
};
const _matras = {
  0x3E: 'aa',
  0x3F: 'i',
  0x40: 'ee',
  0x41: 'u',
  0x42: 'oo',
  0x43: 'ri',
  0x44: 'ri',
  0x45: 'e',
  0x46: 'e',
  0x47: 'e',
  0x48: 'ai',
  0x49: 'o',
  0x4A: 'o',
  0x4B: 'o',
  0x4C: 'au',
  0x57: 'au',
  0x62: 'li',
  0x63: 'li',
};

// Malayalam chillu letters and Bengali khanda ta: consonants with no vowel.
const _bare = {0x0D7A: 'n', 0x0D7B: 'n', 0x0D7C: 'r', 0x0D7D: 'l', 0x0D7E: 'l', 0x0D7F: 'k', 0x0D54: 'm', 0x09CE: 't'};

int? _blockOf(int cp) {
  for (final b in _blocks) {
    if (cp >= b && cp < b + 0x80) return b;
  }
  return null;
}

bool hasIndicLetters(String s) => s.runes.any((r) => _blockOf(r) != null);

/// One consonant (or a vowel on its own) and what follows it.
class _U {
  String c; // consonant in Latin letters ('' = a vowel on its own)
  final int raw; // offset in the script block (-1 for chillu / vowel)
  String? v; // null = the built-in "a"; '' = no vowel (virama)
  String tail = ''; // nasal "n"/"m", visarga "h"
  bool longV = false; // v came from a long vowel sign (aa, ee, oo)
  bool dropped = false; // built-in "a" not said (Hindi "dekhna", not "dekhana")
  _U(this.c, this.raw, [this.v]);
  bool get isCons => c.isNotEmpty;
}

const _short = {'aa': 'a', 'ee': 'i', 'oo': 'u'};

/// Hindi words as people type them in Roman lyrics (हम "hum", में "mein").
const _typed = {'ham': 'hum', 'hamen': 'humein', 'tumhen': 'tumhein', 'kyaa': 'kya', 'men': 'mein', 'hain': 'hain', 'nahin': 'nahin', 'kyon': 'kyun', 'kyonki': 'kyunki', 'tujhako': 'tujhko', 'mujhako': 'mujhko'};

/// Casual Roman letters, the way people type lyrics in chats:
/// "तुझे देखा तो" → "Tujhe dekha to", "കല്യാണി" → "Kalyani",
/// "आमि তোমায় ভালোবাসি" → "Ami tomay bhalobasi". No accents; Hindi drops
/// the unsaid "a" ("dekhna", "dhadkan"). English and other text is kept.
String romanizeLyric(String s, {bool capitalize = true}) {
  if (!hasIndicLetters(s)) return s;
  final out = StringBuffer();
  final word = <_U>[];
  var block = 0x0900;

  void endWord() {
    if (word.isEmpty) return;
    out.write(_renderWord(word, block));
    word.clear();
  }

  for (final cp in s.runes) {
    final bare = _bare[cp];
    if (bare != null) {
      word.add(_U(bare, -1, ''));
      continue;
    }
    final b = _blockOf(cp);
    if (b == null) {
      if (cp == 0x200C || cp == 0x200D) continue; // joiners inside a word
      endWord();
      out.writeCharCode(cp);
      continue;
    }
    if (b != block && word.isNotEmpty) endWord();
    block = b;
    final o = cp - b;
    final last = word.isEmpty ? null : word.last;
    if (_consonants.containsKey(o)) {
      var c = _consonants[o]!;
      if (b == 0x0980) {
        // Bengali: ড় ঢ় are "r" / "rh"; য starts a word as "j" (যত্নে "jotne"), after a joined letter it is "y"
        if (o == 0x5C) c = 'r';
        if (o == 0x5D) c = 'rh';
        if (o == 0x2F && (last == null || last.v != '')) c = 'j';
        // ব joined after another letter is said "w" (স্বপ্ন "swopno")
        if (o == 0x2C && last != null && last.v == '' && last.isCons) c = 'w';
      }
      word.add(_U(c, o));
    } else if (_matras.containsKey(o)) {
      if (last == null) continue;
      final m = _matras[o]!;
      last.v = m;
      last.longV = _short.containsKey(m);
    } else if (o == 0x4D) {
      if (last != null) last.v = '';
    } else if (o == 0x3C) {
      // nukta: ज़ z, फ़ f, क़ q, ड़ d
      if (last != null && b == 0x0980 && (last.raw == 0x21 || last.raw == 0x22 || last.raw == 0x2F)) {
        last.c = switch (last.raw) { 0x21 => 'r', 0x22 => 'rh', _ => 'y' }; // Bengali ড় ঢ় য় typed as letter + nukta
      } else if (last != null) {
        last.c = switch (last.c) { 'j' => 'z', 'ph' => 'f', 'k' => 'q', 'g' => 'g', 'kh' => 'kh', _ => last.c };
      }
    } else if (_vowels.containsKey(o)) {
      final v = _vowels[o]!;
      final u = _U('', -1, v)..longV = _short.containsKey(v);
      word.add(u);
    } else if (o == 0x01 || o == 0x02 || o == 0x00 || (b == 0x0A00 && o == 0x70)) {
      if (last != null) last.tail += b == 0x0D00 || b == 0x0B80 ? 'm' : 'n';
    } else if (o == 0x03) {
      if (last != null) last.tail += 'h';
    } else if (o >= 0x66 && o <= 0x6F) {
      endWord();
      out.write('${o - 0x66}');
    } else if (o == 0x64 || o == 0x65) {
      endWord();
      out.write(o == 0x65 ? ' ' : ',');
    }
    // zero-width and other marks: nothing
  }
  endWord();
  var r = out.toString().replaceAll(RegExp(r' {2,}'), ' ');
  if (s.runes.any((c) => c >= 0x0900 && c < 0x0980)) {
    r = r.replaceAllMapped(RegExp(r'\b(ham|hamen|tumhen|kyaa|men|hain|nahin|kyon|kyonki|tujhako|mujhako)\b'), (m) => _typed[m[1]]!);
  }
  if (!capitalize) return r;
  // first letter of the line in capitals, like typed lyrics
  final i = r.indexOf(RegExp(r'[a-z]'));
  if (i < 0 || r.substring(0, i).contains(RegExp(r'[A-Za-z]'))) return r;
  return r.substring(0, i) + r[i].toUpperCase() + r.substring(i + 1);
}

String _renderWord(List<_U> w, int block) {
  final hindiLike = _dropFinalA.contains(block); // Devanagari, Bengali, Gurmukhi, Gujarati, Odia
  final schwa = block == 0x0980 || block == 0x0B00 ? 'o' : 'a';
  final n = w.length;
  if (hindiLike && n > 1) {
    // the last consonant's "a" is not said (but "mitra": after a joined consonant it is)
    final l = w[n - 1];
    if (l.isCons && l.v == null && l.tail.isEmpty && !(n >= 2 && w[n - 2].v == '' && const {'r', 'y', 'v', 'w'}.contains(l.c))) l.dropped = true;
    // in the middle: V C(a) C V → V C C V ("dekhana" → "dekhna"), right to left
    for (var i = n - 2; i >= 1; i--) {
      final u = w[i], prev = w[i - 1], next = w[i + 1];
      if (!u.isCons || u.v != null || u.tail.isNotEmpty) continue;
      final prevHasVowel = prev.v != '' && !prev.dropped && prev.tail.isEmpty; // "zindagi" keeps it
      final nextSaid = next.isCons && next.v != '' && !next.dropped;
      if (prevHasVowel && nextSaid) u.dropped = true;
    }
  }
  // syllables (consonant clusters count once): "pyaar", "kaam" keep the long sound
  final syllables = w.where((u) => u.v != '' && !u.dropped).length;
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    final u = w[i];
    var c = u.c;
    // Malayalam / Tamil ṟ clusters: ന്റ "nt", റ്റ "tt"; ன்ற "ndr", ற்ற "tr"
    if (u.raw == 0x31 && (block == 0x0D00 || block == 0x0B80) && i > 0 && w[i - 1].v == '') {
      final p = w[i - 1];
      if (p.raw == 0x28 || p.raw == 0x29) c = block == 0x0D00 ? 't' : 'dr';
      if (p.raw == 0x31) c = block == 0x0D00 ? 't' : 'r';
    } else if (u.raw == 0x31 && (block == 0x0D00 || block == 0x0B80) && u.v == '' && i + 1 < n && w[i + 1].raw == 0x31) {
      c = 't';
    } else if (u.raw == 0x1A && u.v == '' && i + 1 < n && (w[i + 1].raw == 0x1A || w[i + 1].raw == 0x1B)) {
      c = 'c'; // अच्छा "accha", कच्चा "kaccha"
    }
    if (u.raw == 0x1A && i > 0 && w[i - 1].raw == 0x1A && w[i - 1].v == '') c = 'ch';
    if (u.raw == 0x1B && i > 0 && w[i - 1].raw == 0x1A && w[i - 1].v == '') c = 'ch';
    sb.write(c);
    var v = u.v;
    if (v == null) {
      v = u.dropped ? '' : schwa;
    } else if (v == '') {
      // Malayalam word-final ് is said "u" (എന്ന് "ennu")
      if (block == 0x0D00 && i == n - 1 && u.raw != -1) v = 'u';
    } else if (u.longV) {
      final keepLong = (i == 0 && !u.isCons && block == 0x0900 && v == 'aa') || (syllables == 1 && n > 1);
      if (!keepLong) v = _short[v]!;
    }
    sb.write(v);
    sb.write(u.tail);
  }
  return sb.toString();
}
