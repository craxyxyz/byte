
import 'dart:convert';
import 'dart:io';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/dj/recommender.dart';
import 'package:byte/dj/up_next.dart';
import 'package:flutter_test/flutter_test.dart';

// Byte 1.4.1 live check of the personal up next: three listener profiles,
// real YouTube Music candidates, the ranked list next to YouTube's own radio.

Future<Item?> find(InnerTube yt, String q) async {
  final r = await yt.search(q, SearchFilter.songs);
  return r.isEmpty ? null : r.first;
}

void main() => test('live radio', run, timeout: const Timeout(Duration(minutes: 8)));

Future<void> run() async {
  final net = HttpNet();
  final yt = InnerTube(net);
  final profiles = <String, Map<String, List<String>>>{
    'Hindi romantic': {
      'liked': ['Tum Hi Ho Arijit Singh', 'Raabta Arijit Singh', 'Tera Ban Jaunga Akhil Sachdeva', 'Pehla Nasha Udit Narayan', 'Tujhe Kitna Chahne Lage Arijit', 'Agar Tum Saath Ho Arijit Alka'],
      'played': ['Channa Mereya Arijit Singh', 'Hawayein Arijit Singh', 'Tum Se Hi Mohit Chauhan', 'Pee Loon Mohit Chauhan'],
      'skipped': ['Paani Paani Badshah', 'Genda Phool Badshah', 'DJ Waley Babu Badshah'],
      'seed': ['Kesariya Arijit Singh'],
    },
    'Bengali': {
      'liked': ['Tomake Chai Arijit Singh', 'Bojhena Shey Bojhena Arijit', 'Amake Amar Moto Thakte Dao Anupam Roy', 'Mon Majhi Re Arijit', 'Ki Kore Toke Bolbo Arijit', 'Boba Tunnel Anupam Roy'],
      'played': ['Tumi Robe Nirobe Rabindra Sangeet', 'Ekla Cholo Re', 'Bhalobashar Morshum'],
      'skipped': ['Laila Main Laila', 'Kala Chashma', 'Chamma Chamma'],
      'seed': ['Tomake Chai Arijit Singh'],
    },
    'English pop': {
      'liked': ['Shape of You Ed Sheeran', 'Levitating Dua Lipa', 'As It Was Harry Styles', 'Perfect Ed Sheeran', 'Watermelon Sugar Harry Styles', 'Don\'t Start Now Dua Lipa'],
      'played': ['Save Your Tears The Weeknd', 'Stay The Kid LAROI', 'bad guy Billie Eilish'],
      'skipped': ['Peaches Justin Bieber', 'Ghost Justin Bieber', 'Baby Justin Bieber'],
      'seed': ['Blinding Lights The Weeknd'],
    },
  };
  final out = <String, Object>{};
  for (final e in profiles.entries) {
    final t = TasteProfile();
    Future<List<Item>> all(List<String> qs) async => [for (final q in qs) ?(await find(yt, q))];
    final liked = await all(e.value['liked']!);
    final played = await all(e.value['played']!);
    final skipped = await all(e.value['skipped']!);
    final seed = (await all(e.value['seed']!)).first;
    void art(Item it, double w) {
      for (final a in it.artists.take(2)) {
        final k = a.name.trim().toLowerCase();
        t.artistName[k] = a.name;
        t.artist[k] = ((t.artist[k] ?? 0) + w).clamp(-1.0, 1.0);
      }
    }
    for (final it in liked) {
      t.songs[it.id] = it; t.liked.add(it.id); t.plays[it.id] = 6; t.completes[it.id] = 5; t.completion[it.id] = 0.95; art(it, 0.35);
    }
    for (final it in played) {
      t.songs[it.id] = it; t.plays[it.id] = 3; t.completes[it.id] = 2; t.completion[it.id] = 0.8; art(it, 0.2);
    }
    for (final it in skipped) {
      t.songs[it.id] = it; t.skips[it.id] = 2; t.plays[it.id] = 2; t.completion[it.id] = 0.1; art(it, -0.5);
      final k = it.artists.isEmpty ? '' : it.artists.first.name.trim().toLowerCase();
      if (k.isNotEmpty) t.artistSkipRate[k] = 1.0;
    }
    t.recent.addAll([...played, ...liked.take(2)]);
    final lp = <String, int>{};
    for (final it in t.songs.values) {
      final l = languageOf(it);
      if (l != null) lp[l] = (lp[l] ?? 0) + 1;
    }
    final tot = lp.values.fold<int>(0, (a, b) => a + b);
    lp.forEach((k, v) => t.language[k] = v / tot);
    final raw = (await yt.next(seed.id)).queue.where((i) => i.id != seed.id).take(20).toList();
    final picks = await PersonalRadio.forSeed(yt, seed, t, count: 20);
    final mineSeed = PersonalRadio.personalSeed(seed, t);
    String langOf(Item i) => languageOf(i) ?? '?';
    stdout.writeln('\n=== ${e.key} · seed "${seed.title}" — ${seed.artistLine} · their own seed: ${mineSeed?.title ?? '-'} · languages ${t.language.map((k, v) => MapEntry(k, v.toStringAsFixed(2)))}');
    stdout.writeln('  Byte 1.4.1 up next:');
    for (var i = 0; i < picks.length; i++) {
      final p = picks[i];
      stdout.writeln('   ${(i + 1).toString().padLeft(2)}. ${p.item.title} — ${p.item.artistLine} [${langOf(p.item)}${p.familiar ? ', familiar' : ', new'}; ${p.why}]');
    }
    final fam = picks.where((p) => p.familiar).length;
    final seedL = languageOf(seed);
    final sameL = picks.where((p) => languageOf(p.item) == seedL).length;
    final rawSameL = raw.where((i) => languageOf(i) == seedL).length;
    final skippedArtists = skipped.map((i) => i.artists.isEmpty ? '' : i.artists.first.name.toLowerCase()).toSet()..remove('');
    bool bySkipped(Item i) => i.artists.any((a) => skippedArtists.contains(a.name.toLowerCase()));
    final recentIds = t.recent.map((i) => i.id).toSet();
    stdout.writeln('  familiar $fam/${picks.length} · seed language $sameL/${picks.length} (YouTube radio $rawSameL/${raw.length}) · by skipped artists ${picks.where((p) => bySkipped(p.item)).length} (YouTube radio ${raw.where(bySkipped).length}) · from recent plays ${picks.where((p) => recentIds.contains(p.item.id)).length} (YouTube radio ${raw.where((i) => recentIds.contains(i.id)).length})');
    stdout.writeln('  YouTube Music radio as it comes: ${raw.take(12).map((i) => i.title).join(' · ')}');
    out[e.key] = {
      'seed': '${seed.title} — ${seed.artistLine}',
      'byte': [for (final p in picks) {'title': p.item.title, 'artist': p.item.artistLine, 'lang': langOf(p.item), 'familiar': p.familiar, 'why': p.why}],
      'youtube': [for (final i in raw) '${i.title} — ${i.artistLine}'],
    };
  }
  File(Platform.environment['OUT'] ?? '/tmp/radio_live.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
}
