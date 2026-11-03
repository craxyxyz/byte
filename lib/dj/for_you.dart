import '../core/innertube.dart';
import '../core/models.dart';
import '../data/library.dart';
import '../data/stats.dart';
import 'dj_session.dart';

/// One recommendation and the plain reason it was picked.
class ForYouPick {
  final Item item;
  final String reason;
  final double score;
  const ForYouPick(this.item, this.reason, this.score);
}

/// What the person has been playing, boiled down: songs (with plays) and artists.
class TasteSeed {
  final Item item;
  final int plays;
  const TasteSeed(this.item, this.plays);
}

/// "For you" in the DJ tab: songs the person hasn't played yet, picked from
/// the radios of what they play most, scored by how many of their favourites
/// point at the same song and whether it's by an artist they love. Runs on the
/// phone; nothing about the person leaves it except the song ids it looks up.
class ForYou {
  final Library library;
  final ListeningStats stats;
  final InnerTube yt;
  final DateTime Function() now;
  ForYou({required this.library, required this.stats, required this.yt, DateTime Function()? now}) : now = now ?? DateTime.now;

  late final DjBrain _brain = DjBrain(library: library, stats: stats, yt: yt, now: now);

  /// Most played songs (last 30 days first, then the year), with play counts.
  List<TasteSeed> seeds({int n = 6}) {
    final plays = <String, int>{};
    final byId = <String, Item>{};
    final cutoff = now().subtract(const Duration(days: 30));
    for (final h in library.history) {
      final it = h.item;
      if (!it.isPlayable || it.kind == ItemKind.episode || it.isDav) continue;
      byId[it.id] ??= it;
      plays[it.id] = (plays[it.id] ?? 0) + (h.at.isAfter(cutoff) ? 2 : 1);
    }
    for (final s in stats.year(now().year).songs.take(40)) {
      byId[s.item.id] ??= s.item;
      plays[s.item.id] = (plays[s.item.id] ?? 0) + s.plays;
    }
    for (final it in library.likes) {
      byId[it.id] ??= it;
      plays[it.id] = (plays[it.id] ?? 0) + 2;
    }
    if (plays.isEmpty) {
      return [for (final it in _brain.favourites().take(n)) TasteSeed(it, 1)];
    }
    final ids = plays.keys.toList()..sort((a, b) => plays[b]!.compareTo(plays[a]!));
    return [for (final id in ids.take(n)) TasteSeed(byId[id]!, plays[id]!)];
  }

  /// Artist name → weight, from the same listening.
  Map<String, double> artistTaste() {
    final w = <String, double>{};
    for (final it in _brain.favourites().take(80)) {
      for (final a in it.artists.take(2)) {
        final k = a.name.toLowerCase();
        if (k.isEmpty) continue;
        w[k] = (w[k] ?? 0) + 1;
      }
    }
    return w;
  }

  /// Up to [count] picks, best first, each with its reason.
  Future<List<ForYouPick>> build({int count = 20, int seedCount = 6}) async {
    final seeds = this.seeds(n: seedCount);
    if (seeds.isEmpty) return const [];
    final known = _brain.known();
    final radios = await Future.wait([
      for (final s in seeds)
        yt.next(s.item.id).then((n) => n.queue).catchError((_) => <Item>[]),
    ]);
    return rank(seeds, radios, known, artistTaste(), count: count);
  }

  /// The scoring, apart from the network (tests feed it directly).
  static List<ForYouPick> rank(List<TasteSeed> seeds, List<List<Item>> radios, Set<String> known, Map<String, double> artists, {int count = 20}) {
    final score = <String, double>{};
    final byId = <String, Item>{};
    final from = <String, List<int>>{};
    final seedIds = seeds.map((s) => s.item.id).toSet();
    for (var si = 0; si < seeds.length && si < radios.length; si++) {
      final r = radios[si];
      for (var k = 0; k < r.length; k++) {
        final it = r[k];
        if (seedIds.contains(it.id) || known.contains(it.id) || !it.isPlayable || it.kind == ItemKind.episode) continue;
        byId[it.id] ??= it;
        // earlier in a radio = closer to the seed; more-played seeds count more
        final w = (1.0 - k / (r.length + 4)) * (1 + seeds[si].plays / 10).clamp(1, 3);
        score[it.id] = (score[it.id] ?? 0) + w;
        (from[it.id] ??= []).add(si);
      }
    }
    final maxArtist = artists.values.fold<double>(0, (a, b) => b > a ? b : a);
    String? lovedArtist(Item it) {
      for (final a in it.artists) {
        final v = artists[a.name.toLowerCase()];
        if (v != null && v >= 2) return a.name;
      }
      return null;
    }

    for (final id in score.keys.toList()) {
      final a = lovedArtist(byId[id]!);
      if (a != null && maxArtist > 0) score[id] = score[id]! + 0.8 * (artists[a.toLowerCase()]! / maxArtist) + 0.4;
    }
    final ids = score.keys.toList()..sort((a, b) => score[b]!.compareTo(score[a]!));
    // keep it varied: at most 3 songs by the same first artist, and no one
    // favourite's radio fills the whole list
    final perArtist = <String, int>{};
    final perSeed = <int, int>{};
    final seedCap = (count / seeds.length).ceil() + 2;
    final out = <ForYouPick>[];
    final spill = <String>[];
    for (final id in ids) {
      final it = byId[id]!;
      final first = it.artists.isEmpty ? '' : it.artists.first.name.toLowerCase();
      if ((perArtist[first] ?? 0) >= 3) continue;
      final main = from[id]!.first;
      if (from[id]!.length == 1 && (perSeed[main] ?? 0) >= seedCap) {
        spill.add(id);
        continue;
      }
      perArtist[first] = (perArtist[first] ?? 0) + 1;
      perSeed[main] = (perSeed[main] ?? 0) + 1;
      out.add(ForYouPick(it, reasonFor(it, [for (final s in from[id]!) seeds[s]], lovedArtist(it)), score[id]!));
      if (out.length >= count) break;
    }
    // not enough variety to fill the list: top up with the rest
    for (final id in spill) {
      if (out.length >= count) break;
      final it = byId[id]!;
      final first = it.artists.isEmpty ? '' : it.artists.first.name.toLowerCase();
      if ((perArtist[first] = (perArtist[first] ?? 0) + 1) > 3) continue;
      out.add(ForYouPick(it, reasonFor(it, [for (final s in from[id]!) seeds[s]], lovedArtist(it)), score[id]!));
    }
    return out;
  }

  /// "Because you play X a lot" / "Fans of X and Y play this" / "More from Z, one of your top artists".
  /// "Kesariya (From \"Brahmastra\")" → "Kesariya" for the reason line.
  static String shortTitle(String t) {
    final s = t.replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), '').split(' - ').first.trim();
    return s.isEmpty ? t : s;
  }

  static String reasonFor(Item it, List<TasteSeed> via, String? lovedArtist) {
    via = [for (final v in via) TasteSeed(v.item.copyWith(title: shortTitle(v.item.title)), v.plays)];
    if (via.length >= 2) {
      final a = via[0].item.title, b = via[1].item.title;
      return 'Because you play $a and $b';
    }
    if (lovedArtist != null && (via.isEmpty || !via.first.item.artists.any((x) => x.name.toLowerCase() == lovedArtist.toLowerCase()))) {
      return 'More from $lovedArtist, one of your top artists';
    }
    if (via.isNotEmpty) {
      final s = via.first;
      return s.plays >= 6 ? 'Because you play ${s.item.title} a lot' : 'Because you played ${s.item.title}';
    }
    return 'New for you';
  }
}
