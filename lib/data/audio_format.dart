import 'dart:io';
import 'dart:typed_data';

import 'addons.dart' show SourceFormat;

/// Reads a music file's real format from its own header (not its name):
/// FLAC, WAV (PCM), AIFF, MP4 (ALAC or AAC), MP3, Ogg. A file is called
/// lossless only when the header says so.
SourceFormat? parseAudioHeader(Uint8List b, {Uint8List? tail}) {
  if (b.length < 12) return null;
  String tag(int o) => o + 4 <= b.length ? String.fromCharCodes(b.sublist(o, o + 4)) : '';
  int be16(Uint8List d, int o) => (d[o] << 8) | d[o + 1];
  int be32(Uint8List d, int o) => (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
  int le16(int o) => b[o] | (b[o + 1] << 8);
  int le32(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  // FLAC: "fLaC" + STREAMINFO
  var start = 0;
  if (tag(0).startsWith('ID3') && b.length > 10) {
    start = 10 + ((b[6] & 0x7f) << 21 | (b[7] & 0x7f) << 14 | (b[8] & 0x7f) << 7 | (b[9] & 0x7f));
  }
  if (start + 4 + 4 + 18 <= b.length && String.fromCharCodes(b.sublist(start, start + 4)) == 'fLaC') {
    final s = start + 8; // after "fLaC" + block header
    final rate = (b[s + 10] << 12) | (b[s + 11] << 4) | (b[s + 12] >> 4);
    final ch = ((b[s + 12] >> 1) & 0x07) + 1;
    final bps = (((b[s + 12] & 0x01) << 4) | (b[s + 13] >> 4)) + 1;
    return SourceFormat(codec: 'flac', sampleRate: rate, bitDepth: bps, channels: ch);
  }
  // WAV: RIFF....WAVE, "fmt " chunk
  if (tag(0) == 'RIFF' && tag(8) == 'WAVE') {
    var o = 12;
    while (o + 8 <= b.length) {
      final id = tag(o), size = le32(o + 4);
      if (id == 'fmt ' && o + 24 <= b.length) {
        final fmt = le16(o + 8);
        final ch = le16(o + 10), rate = le32(o + 12), bits = le16(o + 22);
        // 1 = PCM, 3 = float, 0xFFFE = extensible (PCM inside)
        final pcm = fmt == 1 || fmt == 3 || fmt == 0xFFFE;
        return SourceFormat(codec: pcm ? 'wav' : 'wav-compressed', sampleRate: rate, bitDepth: bits, channels: ch);
      }
      o += 8 + size + (size & 1);
    }
    return null;
  }
  // AIFF / AIFC: FORM....AIFF, COMM chunk
  if (tag(0) == 'FORM' && (tag(8) == 'AIFF' || tag(8) == 'AIFC')) {
    var o = 12;
    while (o + 8 <= b.length) {
      final id = tag(o), size = be32(b, o + 4);
      if (id == 'COMM' && o + 26 <= b.length) {
        final ch = be16(b, o + 8), bits = be16(b, o + 14);
        final rate = _extended80(b, o + 16).round();
        var lossless = true;
        if (tag(8) == 'AIFC' && o + 30 <= b.length) {
          final comp = tag(o + 26);
          lossless = comp == 'NONE' || comp == 'sowt' || comp == 'fl32' || comp == 'fl64';
        }
        return SourceFormat(codec: lossless ? 'aiff' : 'aiff-compressed', sampleRate: rate, bitDepth: bits, channels: ch);
      }
      o += 8 + size + (size & 1);
    }
    return null;
  }
  // MP4 / M4A: the sample entry in "stsd" says ALAC or AAC
  if (tag(4) == 'ftyp') {
    for (final d in [b, ?tail]) {
      final f = _mp4Audio(d, be16, be32);
      if (f != null) return f;
    }
    return const SourceFormat(codec: 'aac');
  }
  if (tag(0) == 'OggS') {
    final s = String.fromCharCodes(b.sublist(0, b.length.clamp(0, 200)));
    if (s.contains('OpusHead')) return const SourceFormat(codec: 'opus');
    if (s.contains('fLaC')) return const SourceFormat(codec: 'flac');
    return const SourceFormat(codec: 'vorbis');
  }
  if (tag(0).startsWith('ID3') || (b[start.clamp(0, b.length - 2)] == 0xFF && (b[(start + 1).clamp(0, b.length - 1)] & 0xE0) == 0xE0)) {
    return const SourceFormat(codec: 'mp3');
  }
  return null;
}

SourceFormat? _mp4Audio(Uint8List d, int Function(Uint8List, int) be16, int Function(Uint8List, int) be32) {
  for (var i = 4; i + 4 < d.length; i++) {
    if (d[i] != 0x73 || d[i + 1] != 0x74 || d[i + 2] != 0x73 || d[i + 3] != 0x64) continue; // "stsd"
    final e = i + 12; // after "stsd" + version/flags + entry count
    if (e + 36 > d.length) return null;
    final type = String.fromCharCodes(d.sublist(e + 4, e + 8));
    final ch = be16(d, e + 24), bits = be16(d, e + 26), rate = be32(d, e + 32) >> 16;
    if (type == 'alac') {
      // the ALAC cookie (a child "alac" box) has the true bit depth and rate
      final c = e + 36;
      if (c + 36 <= d.length && String.fromCharCodes(d.sublist(c + 4, c + 8)) == 'alac') {
        final k = c + 12;
        return SourceFormat(codec: 'alac', bitDepth: d[k + 5], channels: d[k + 9], sampleRate: be32(d, k + 20));
      }
      return SourceFormat(codec: 'alac', bitDepth: bits, channels: ch, sampleRate: rate);
    }
    if (type == 'mp4a') return SourceFormat(codec: 'aac', channels: ch, sampleRate: rate);
    if (type == 'ec-3' || type == 'ac-3') return SourceFormat(codec: type == 'ec-3' ? 'eac3' : 'ac3', channels: ch, sampleRate: rate);
    if (type == 'fLaC') return SourceFormat(codec: 'flac', bitDepth: bits, channels: ch, sampleRate: rate);
    return SourceFormat(codec: type.trim().toLowerCase());
  }
  return null;
}

/// 80-bit IEEE extended (AIFF sample rate).
double _extended80(Uint8List b, int o) {
  final exp = ((b[o] & 0x7f) << 8) | b[o + 1];
  var mant = 0.0;
  for (var i = 0; i < 8; i++) {
    mant = mant * 256 + b[o + 2 + i];
  }
  if (exp == 0 && mant == 0) return 0;
  final sign = (b[o] & 0x80) != 0 ? -1 : 1;
  return sign * mant * _pow2(exp - 16383 - 63);
}

double _pow2(int e) {
  var r = 1.0;
  if (e >= 0) {
    for (var i = 0; i < e; i++) {
      r *= 2;
    }
  } else {
    for (var i = 0; i < -e; i++) {
      r /= 2;
    }
  }
  return r;
}

/// Formats read from files, by path (Library and the player read it).
class AudioFormats {
  static final Map<String, SourceFormat?> _cache = {};
  static SourceFormat? cached(String path) => _cache[path];

  static Future<SourceFormat?> of(String path) async {
    if (_cache.containsKey(path)) return _cache[path];
    SourceFormat? f;
    try {
      final file = File(path);
      final raf = await file.open();
      try {
        final len = await raf.length();
        final head = await raf.read(len < 1 << 20 ? len : 1 << 20);
        Uint8List? tail;
        if (len > 1 << 20) {
          final from = len - (len < 3 << 20 ? len - (1 << 20) : 2 << 20);
          await raf.setPosition(from);
          tail = await raf.read(len - from);
        }
        f = parseAudioHeader(head, tail: tail);
      } finally {
        await raf.close();
      }
    } catch (_) {}
    _cache[path] = f;
    if (_cache.length > 2000) _cache.remove(_cache.keys.first);
    return f;
  }
}
