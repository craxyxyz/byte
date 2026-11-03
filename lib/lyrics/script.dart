// Byte © 2026 Apurba Laskar.
// The same lyrics in Hindi (Devanagari) letters: a Malayalam, Tamil, Telugu,
// Kannada, Bengali, Punjabi, Gujarati or Odia line keeps its words and sound,
// only the letters change ("കല്യാണി" → "कल्याणि"). These Unicode blocks share
// one layout, so most letters move by a fixed offset; the few letters only
// one script has (Malayalam chillus, Bengali khanda ta, Gurmukhi tippi…) are
// spelled out below. Pure Dart, unit tested.

const _indicBlocks = [0x0980, 0x0A00, 0x0A80, 0x0B00, 0x0B80, 0x0C00, 0x0C80, 0x0D00];

int? _blockOf(int r) {
  for (final b in _indicBlocks) {
    if (r >= b && r < b + 0x80) return b;
  }
  return null;
}

/// True when [s] has letters of an Indian script other than Devanagari.
bool hasOtherIndicLetters(String s) => s.runes.any((r) => _blockOf(r) != null);

/// True when [s] already has Devanagari letters.
bool hasDevanagari(String s) => s.runes.any((r) => r >= 0x0900 && r < 0x0980);

const _special = <int, String>{
  // Malayalam chillu letters: a consonant with no vowel
  0x0D7A: 'ण्', 0x0D7B: 'न्', 0x0D7C: 'र्', 0x0D7D: 'ल्', 0x0D7E: 'ळ्', 0x0D7F: 'क्', 0x0D54: 'म्', 0x0D55: 'य्', 0x0D56: 'ऴ्',
  // the "rr" letters read as Hindi's र; ṉ as न
  0x0D31: 'र', 0x0D29: 'न', 0x0BB1: 'र', 0x0BA9: 'न',
  0x0D4E: 'र्', // dot reph
  0x0D57: 'ौ', // au length mark (on its own)
  // Bengali / Assamese
  0x09CE: 'त्', 0x09F0: 'र', 0x09F1: 'व', 0x09D7: 'ौ',
  // Gurmukhi
  0x0A70: 'ं', 0x0A71: '', 0x0A72: 'इ', 0x0A73: 'उ', 0x0A74: '',
  // Odia
  0x0B5F: 'य', 0x0B71: 'व', 0x0B57: 'ै',
  // Tamil au length mark, Telugu/Kannada length marks
  0x0BD7: 'ौ', 0x0C55: '', 0x0C56: 'ै', 0x0CD5: '', 0x0CD6: 'ै',
};

/// Offsets that move to a different Devanagari letter: the short e / o of the
/// southern scripts become Hindi's e / o.
const _remap = <int, int>{0x0E: 0x0F, 0x12: 0x13, 0x46: 0x47, 0x4A: 0x4B};

/// Letter groups that sound different from their parts (Malayalam റ്റ is
/// "tt", ന്റ is "nt"; Tamil ற்ற is "tr", ன்ற is "ndr").
const _clusters = <List<int>, String>{
  [0x0D31, 0x0D4D, 0x0D31]: 'ट्ट',
  [0x0D28, 0x0D4D, 0x0D31]: 'न्ट',
  [0x0D7B, 0x0D31]: 'न्ट',
  [0x0BB1, 0x0BCD, 0x0BB1]: 'त्र',
  [0x0BA9, 0x0BCD, 0x0BB1]: 'न्ड्र',
};

/// [s] in Devanagari letters. Text in other scripts (Latin, Devanagari
/// itself, Urdu, emoji) is left exactly as it is.
String toDevanagari(String s) {
  final rs = s.runes.toList();
  final out = StringBuffer();
  for (var i = 0; i < rs.length; i++) {
    final r = rs[i];
    final b = _blockOf(r);
    if (b == null) {
      out.writeCharCode(r);
      continue;
    }
    String? cluster;
    var len = 0;
    for (final e in _clusters.entries) {
      final k = e.key;
      if (i + k.length <= rs.length && k[0] == r) {
        var ok = true;
        for (var j = 1; j < k.length; j++) {
          if (rs[i + j] != k[j]) {
            ok = false;
            break;
          }
        }
        if (ok && k.length > len) {
          cluster = e.value;
          len = k.length;
        }
      }
    }
    if (cluster != null) {
      out.write(cluster);
      i += len - 1;
      continue;
    }
    final sp = _special[r];
    if (sp != null) {
      out.write(sp);
      continue;
    }
    var off = r - b;
    final next = i + 1 < rs.length && _blockOf(rs[i + 1]) == b ? rs[i + 1] - b : null;
    // two-part vowel signs written as two characters: e + aa = o, e + au mark = au
    if ((off == 0x46 || off == 0x47) && next == 0x3E) {
      out.writeCharCode(0x094B);
      i++;
      continue;
    }
    if ((off == 0x46 || off == 0x47) && next == 0x57) {
      out.writeCharCode(0x094C);
      i++;
      continue;
    }
    if (off >= 0x66 && off <= 0x6F) {
      out.writeCharCode(0x30 + off - 0x66); // digits → 0-9
      continue;
    }
    off = _remap[off] ?? off;
    // Tamil writes the dead-consonant mark (pulli) where Hindi has a halant: same code.
    out.writeCharCode(0x0900 + off);
  }
  return out.toString();
}
