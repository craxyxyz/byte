import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../core/net.dart';
import 'audio_lab.dart';

// Byte 2.0 © 2026 Apurba Laskar.
//
// Audio Lab → Headphone correction: pick your headphones and Byte flattens
// them toward a neutral target, under your own EQ curve. The list of
// headphones is bundled (assets/audiolab/headphones.tsv, built from the
// AutoEq project's published results, MIT License); the chosen profile's
// filters are downloaded once and kept with the Audio Lab settings.

class HeadphoneEntry {
  final String name;

  /// Where the profile lives in the results ("source/kind/Name").
  final String path;
  const HeadphoneEntry(this.name, this.path);

  /// Who measured it (shown small under the name).
  String get source {
    final parts = path.split('/');
    final kind = parts.length > 2 ? parts[1] : '';
    final type = kind.contains('in-ear') ? 'In-ear' : (kind.contains('earbud') ? 'Earbuds' : (kind.contains('over-ear') ? 'Over-ear' : ''));
    return [if (type.isNotEmpty) type, 'measured by ${parts.first}'].join(' · ');
  }

  /// The profile file (parametric filters) for this headphone.
  Uri get url {
    final last = path.split('/').last;
    final p = path.split('/').map(Uri.encodeComponent).join('/');
    return Uri.parse('https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/$p/${Uri.encodeComponent('$last ParametricEQ.txt')}');
  }
}

class HeadphoneProfile {
  final double preamp;
  final List<EqNode> nodes;
  const HeadphoneProfile(this.preamp, this.nodes);

  /// Reads a parametric profile ("Preamp: -6.0 dB", "Filter 1: ON PK Fc 180
  /// Hz Gain -3.3 dB Q 0.57"). Filters that are OFF or of an unknown kind are
  /// skipped; null when nothing usable is in [text].
  static HeadphoneProfile? parse(String text) {
    var pre = 0.0;
    final nodes = <EqNode>[];
    final preRe = RegExp(r'^\s*Preamp:\s*(-?[\d.]+)\s*dB', caseSensitive: false, multiLine: true);
    final m = preRe.firstMatch(text);
    if (m != null) pre = double.tryParse(m.group(1)!) ?? 0;
    final fRe = RegExp(r'Filter\s*\d*:\s*(ON|OFF)\s+([A-Z]+)\s+Fc\s+([\d.]+)\s*Hz(?:\s+Gain\s+(-?[\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?', caseSensitive: false);
    for (final f in fRe.allMatches(text)) {
      if (f.group(1)!.toUpperCase() != 'ON') continue;
      final kind = f.group(2)!.toUpperCase();
      final type = switch (kind) {
        'PK' || 'PEQ' || 'P' => EqNodeType.peak,
        'LS' || 'LSC' || 'LSQ' || 'LSF' => EqNodeType.lowShelf,
        'HS' || 'HSC' || 'HSQ' || 'HSF' => EqNodeType.highShelf,
        _ => null,
      };
      if (type == null) continue;
      final fc = double.tryParse(f.group(3)!);
      final g = double.tryParse(f.group(4) ?? '0') ?? 0;
      final q = double.tryParse(f.group(5) ?? '') ?? (type == EqNodeType.peak ? 1.41 : 0.71);
      if (fc == null || fc < 10 || fc > 24000) continue;
      nodes.add(EqNode(type, fc, g.clamp(-24.0, 24.0), q.clamp(0.1, 18.0)));
    }
    if (nodes.isEmpty) return null;
    return HeadphoneProfile(pre, nodes);
  }
}

class HeadphoneIndex {
  static List<HeadphoneEntry>? _all;

  /// Tests set the list directly.
  static set debugAll(List<HeadphoneEntry>? v) => _all = v;

  static Future<List<HeadphoneEntry>> all() async {
    final have = _all;
    if (have != null) return have;
    final text = await rootBundle.loadString('assets/audiolab/headphones.tsv');
    return _all = parseIndex(text);
  }

  static List<HeadphoneEntry> parseIndex(String text) => [
    for (final l in const LineSplitter().convert(text))
      if (l.contains('\t')) HeadphoneEntry(l.substring(0, l.indexOf('\t')), l.substring(l.indexOf('\t') + 1)),
  ];

  /// Best matches for what was typed: every word must appear; names that
  /// start with the words come first. At most [limit].
  static List<HeadphoneEntry> search(List<HeadphoneEntry> all, String query, {int limit = 40}) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    final hits = <(int, HeadphoneEntry)>[];
    for (final e in all) {
      final n = e.name.toLowerCase();
      if (!words.every(n.contains)) continue;
      var score = 0;
      if (n.startsWith(words.first)) score -= 10;
      if (n == query.toLowerCase().trim()) score -= 20;
      score += n.length ~/ 8;
      hits.add((score, e));
    }
    hits.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.name.compareTo(b.$2.name));
    return [for (final h in hits.take(limit)) h.$2];
  }

  /// Downloads [e]'s profile.
  static Future<HeadphoneProfile> fetch(Net net, HeadphoneEntry e) async {
    final r = await net.get(e.url);
    if (r.status != 200) throw Exception('That headphone profile could not be loaded (${r.status}). Try again in a moment.');
    final p = HeadphoneProfile.parse(r.text);
    if (p == null) throw Exception('That headphone profile has no filters Byte can use.');
    return p;
  }
}
