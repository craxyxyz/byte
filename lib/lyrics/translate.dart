import 'dart:convert';

import '../core/net.dart';

/// Lyrics translation through the free MyMemory service (no key, no sign-in).
/// Lines go in small batches; results are kept for the session.
class LyricsTranslator {
  final Net net;
  LyricsTranslator(this.net);
  final _cache = <String, String>{};

  static const languages = {
    'en': 'English',
    'hi': 'Hindi',
    'bn': 'Bengali',
    'ta': 'Tamil',
    'te': 'Telugu',
    'ml': 'Malayalam',
    'kn': 'Kannada',
    'mr': 'Marathi',
    'gu': 'Gujarati',
    'pa': 'Punjabi',
    'ur': 'Urdu',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'pt': 'Portuguese',
    'ar': 'Arabic',
    'ja': 'Japanese',
    'ko': 'Korean',
    'zh-CN': 'Chinese',
  };

  /// Guess the source language from the script (MyMemory needs one).
  static String guessSource(String text) {
    int count(int a, int b) => text.runes.where((r) => r >= a && r <= b).length;
    final scores = {
      'hi': count(0x0900, 0x097F),
      'bn': count(0x0980, 0x09FF),
      'pa': count(0x0A00, 0x0A7F),
      'gu': count(0x0A80, 0x0AFF),
      'or': count(0x0B00, 0x0B7F),
      'ta': count(0x0B80, 0x0BFF),
      'te': count(0x0C00, 0x0C7F),
      'kn': count(0x0C80, 0x0CFF),
      'ml': count(0x0D00, 0x0D7F),
      'ar': count(0x0600, 0x06FF),
      'ja': count(0x3040, 0x30FF),
      'ko': count(0xAC00, 0xD7AF),
      'zh-CN': count(0x4E00, 0x9FFF),
    };
    final best = scores.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (best.value > 0) return best.key;
    // Latin script: Hinglish lyrics are the common case here.
    final hinglish = RegExp(r'\b(hai|hain|mera|meri|tera|teri|tum|dil|nahi|kya|main|mujhe|tujhe|pyaar|ishq)\b', caseSensitive: false);
    return hinglish.allMatches(text).length >= 2 ? 'hi' : 'en';
  }

  /// One translation per line, same order; untranslatable lines come back as "".
  /// Tests swap the network translators for this.
  Future<List<String>> Function(List<String> lines, String to)? override;

  Future<List<String>> lines(List<String> lines, String to) async {
    if (override != null) return override!(lines, to);
    // First the auto-detecting translator (it tells native-script and
    // Latin-script lyrics apart by itself), then the free fallback.
    try {
      final g = await _auto(lines, to);
      if (g.where((x) => x.isNotEmpty).length >= lines.where((x) => x.trim().isNotEmpty).length * 0.6) {
        return await _latinIndic(lines, g, to);
      }
    } catch (_) {}
    return _myMemory(lines, to);
  }

  static String _unescape(String s) => s.replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');

  static const indic = {'hi', 'bn', 'ta', 'te', 'ml', 'kn', 'mr', 'gu', 'pa', 'ur', 'or', 'ne'};

  /// True when [out] is basically [input] handed back (the translator didn't
  /// understand Hinglish / Tanglish written in English letters).
  static bool echoed(String input, String out) {
    List<String> words(String s) => s.toLowerCase().split(RegExp(r'[^a-z0-9\u00C0-\u024F]+')).where((w) => w.isNotEmpty).toList();
    final a = words(input).toSet(), b = words(out);
    if (b.isEmpty) return true;
    return b.where(a.contains).length >= b.length * 0.7;
  }

  /// Indian-language lyrics written in English letters: turn them into their
  /// own script first, then translate that (so "Thuli thuli mazhaiyai vanthaley"
  /// becomes "If it rains drop by drop" instead of coming back unchanged).
  Future<List<String>> _latinIndic(List<String> lines, List<String> first, String to) async {
    final lang = detected;
    if (!indic.contains(lang) || lang == to) return first;
    final idx = [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].trim().isNotEmpty && !lines[i].contains(' - ') && !RegExp(r'[^\x00-\x7F\u00C0-\u024F\u2018-\u201D]').hasMatch(lines[i]) && echoed(lines[i], first[i])) i,
    ];
    if (idx.length < lines.where((x) => x.trim().isNotEmpty).length * 0.3) return first;
    final out = [...first];
    try {
      final native = <int, String>{};
      // one line per request (the service cuts long answers short), 8 at a time
      Future<void> one(int i) async {
        try {
          final r = await net.get(
            Uri.parse('https://inputtools.google.com/request').replace(
              queryParameters: {'text': lines[i].trim(), 'itc': '$lang-t-i0-und', 'num': '1', 'cp': '0', 'cs': '1', 'ie': 'utf-8', 'oe': 'utf-8', 'app': 'byte'},
            ),
            timeout: const Duration(seconds: 10),
          );
          if (r.status != 200) return;
          final j = r.json as List;
          if (j.isEmpty || j.first != 'SUCCESS') return;
          final text = ((((j[1] as List).first as List)[1] as List).first as String);
          if (text.trim().isNotEmpty) native[i] = _unescape(text);
        } catch (_) {}
      }

      for (var s = 0; s < idx.length; s += 8) {
        await Future.wait([for (final i in idx.sublist(s, (s + 8).clamp(0, idx.length))) one(i)]);
      }
      if (native.isEmpty) return first;
      final keys = native.keys.toList();
      final tr = await _auto([for (final i in keys) native[i]!], to, from: lang);
      for (var k = 0; k < keys.length; k++) {
        if (tr[k].isNotEmpty && !echoed(lines[keys[k]], tr[k])) out[keys[k]] = tr[k];
      }
    } catch (_) {}
    detected = lang;
    return out;
  }

  /// Language detected by the last auto translation ('' = unknown).
  String detected = '';

  Future<List<String>> _auto(List<String> lines, String to, {String from = 'auto'}) async {
    final out = List<String>.filled(lines.length, '');
    final idx = [for (var i = 0; i < lines.length; i++) if (lines[i].trim().isNotEmpty) i];
    final langs = <String, int>{};
    for (var start = 0; start < idx.length; start += 40) {
      final part = idx.sublist(start, (start + 40).clamp(0, idx.length));
      final todo = part.where((i) => !_cache.containsKey('$from>$to:${lines[i].trim()}')).toList();
      if (todo.isNotEmpty) {
        final body = todo.map((i) => 'q=${Uri.encodeQueryComponent(lines[i].trim())}').join('&');
        final r = await net.send(
          NetRequest(
            'POST',
            Uri.parse('https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=$from&tl=${Uri.encodeQueryComponent(to)}'),
            headers: const {'content-type': 'application/x-www-form-urlencoded;charset=utf-8'},
            body: utf8.encode(body),
          ),
          timeout: const Duration(seconds: 15),
        );
        if (r.status != 200) throw NetException('translate ${r.status}');
        final rows = r.json as List;
        if (rows.length != todo.length) throw NetException('translate rows');
        for (var k = 0; k < todo.length; k++) {
          final row = rows[k];
          final text = row is List ? '${row.first}' : '$row';
          if (row is List && row.length > 1) langs.update('${row[1]}', (v) => v + 1, ifAbsent: () => 1);
          _cache['$from>$to:${lines[todo[k]].trim()}'] = text.trim();
        }
      }
      for (final i in part) {
        out[i] = _cache['$from>$to:${lines[i].trim()}'] ?? '';
      }
    }
    if (langs.isNotEmpty) detected = langs.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    return out;
  }

  Future<List<String>> _myMemory(List<String> lines, String to) async {
    final src = guessSource(lines.join(' '));
    if (src == to) return [for (final _ in lines) ''];
    final out = List<String>.filled(lines.length, '');
    final todo = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty) continue;
      final c = _cache['$src>$to:$t'];
      if (c != null) {
        out[i] = c;
      } else {
        todo.add(i);
      }
    }
    // Batches of up to ~450 characters, one line per row.
    var batch = <int>[];
    var len = 0;
    Future<void> run() async {
      if (batch.isEmpty) return;
      final text = batch.map((i) => lines[i].trim()).join('\n');
      final r = await net.get(
        Uri.parse('https://api.mymemory.translated.net/get').replace(queryParameters: {'q': text, 'langpair': '$src|$to'}),
        timeout: const Duration(seconds: 15),
      );
      if (r.status == 200) {
        final t = ((r.json as Map)['responseData'] as Map?)?['translatedText'] as String?;
        if (t != null) {
          final parts = t.split(RegExp(r'\r?\n'));
          if (parts.length == batch.length) {
            for (var k = 0; k < batch.length; k++) {
              out[batch[k]] = parts[k].trim();
              _cache['$src>$to:${lines[batch[k]].trim()}'] = parts[k].trim();
            }
          } else if (batch.length == 1) {
            out[batch.first] = t.trim();
          }
        }
      }
      batch = [];
      len = 0;
    }

    for (final i in todo) {
      final l = lines[i].trim().length + 1;
      if (len + l > 450) await run();
      batch.add(i);
      len += l;
    }
    await run();
    return out;
  }
}
