import 'dart:async';
import 'dart:math';

import '../core/innertube.dart';
import '../core/models.dart';
import 'up_next.dart' show songKey;
import '../data/library.dart';
import '../data/play_log.dart';
import '../data/stats.dart';
import 'dj_session.dart' show languageProfile;
import 'request_parser.dart';

/// Where candidate songs come from (YouTube Music on the phone; fakes in tests).
abstract class CandidateSource {
  /// "Up next" radio for a song.
  Future<List<Item>> radio(Item seed);

  /// Songs for a search phrase.
  Future<List<Item>> search(String query);

  /// Songs of the best playlist for a search phrase ("sad hindi songs").
  Future<List<Item>> playlist(String query);
}

class InnerTubeSource implements CandidateSource {
  final InnerTube yt;
  InnerTubeSource(this.yt);

  @override
  Future<List<Item>> radio(Item seed) async => (await yt.next(seed.id)).queue.where((i) => i.isPlayable && i.id != seed.id).toList();

  @override
  Future<List<Item>> search(String query) async => (await yt.search(query, SearchFilter.songs)).where((i) => i.isPlayable).toList();

  @override
  Future<List<Item>> playlist(String query) async {
    final lists = await yt.search(query, SearchFilter.playlists);
    if (lists.isEmpty) return const [];
    final p = await yt.playlist(lists.first.id, maxTracks: 60);
    return p.tracks.where((i) => i.isPlayable).take(60).toList();
  }
}

String _key(String artist) => artist.trim().toLowerCase();
String? _primary(Item it) => it.artists.isEmpty || it.artists.first.name.trim().isEmpty ? null : _key(it.artists.first.name);
bool _byArtist(Item it, String artist) {
  final k = _key(artist);
  return it.artists.any((a) {
    final n = _key(a.name);
    return n == k || n.contains(k) || (k.length >= 4 && k.contains(n) && n.length >= 4);
  });
}

/// A song's language, guessed from its script, words or artist.
String? languageOf(Item it) {
  final p = languageProfile([it]);
  if (p.isNotEmpty) return p.keys.first.toLowerCase();
  for (final a in it.artists) {
    final k = DjVocab.languageOfArtist(a.name);
    if (k?.language != null) return k!.language;
  }
  return null;
}

/// Everything the phone knows about the listener's taste.
class TasteProfile {
  final Map<String, Item> songs = {}; // every song they've heard
  final Map<String, double> plays = {};
  final Map<String, double> completion = {}; // 0..1
  final Set<String> liked = {};
  final Map<String, int> skips = {};
  final Map<String, int> completes = {};
  final Map<String, double> artist = {}; // 0..1
  final Map<String, String> artistName = {};
  final Map<String, double> artistSkipRate = {};
  final Map<String, double> artistHour = {}; // share of their plays at this time of day
  final Map<String, Map<String, int>> coArtists = {};
  final Map<String, double> language = {}; // share 0..1
  final List<Item> recent = []; // newest first
  final List<Item> yesterday = [];
  final List<Item> today = [];

  Set<String> get known => songs.keys.toSet();
  bool isKnown(String id) => songs.containsKey(id);
  bool get isEmpty => songs.isEmpty;

  /// Top artists (display names), most loved first.
  List<String> topArtists([int n = 5]) {
    final l = artist.keys.toList()..sort((a, b) => artist[b]!.compareTo(artist[a]!));
    return l.take(n).map((k) => artistName[k] ?? k).toList();
  }

  /// Artists played most in the last [days] days (for the greeting).
  final Map<String, int> lately = {};
  List<String> latelyArtists([int n = 2]) {
    final l = lately.keys.toList()..sort((a, b) => lately[b]!.compareTo(lately[a]!));
    final out = l.take(n).map((k) => artistName[k] ?? k).toList();
    return out.isEmpty ? topArtists(n) : out;
  }

  /// How much they love a song they know (0 for unknown).
  double songAffinity(String id) {
    final p = plays[id] ?? 0;
    final c = completion[id] ?? 0.6;
    var s = 0.35 * log(1 + p) * (0.4 + 0.6 * c);
    if (liked.contains(id)) s += 0.6;
    final sk = (skips[id] ?? 0) - (completes[id] ?? 0);
    if (sk > 0) s -= 0.5 * sk;
    return s;
  }

  /// Their known songs, most loved first.
  List<Item> favourites() {
    final ids = songs.keys.toList()..sort((a, b) => songAffinity(b).compareTo(songAffinity(a)));
    return ids.map((i) => songs[i]!).toList();
  }

  /// Songs they keep skipping and never finish.
  bool disliked(String id) => (skips[id] ?? 0) >= 2 && (completes[id] ?? 0) == 0 && !liked.contains(id);

  static TasteProfile build({required Library library, required ListeningStats stats, PlayLog? log, DateTime? now}) {
    final t = TasteProfile();
    final n = now ?? DateTime.now();
    bool ok(Item i) => i.isPlayable && i.kind != ItemKind.episode && !i.isDav;
    void know(Item i) {
      if (ok(i)) t.songs[i.id] ??= i;
    }

    final artistRaw = <String, double>{};
    void art(Item it, double w) {
      for (final a in it.artists.take(2)) {
        if (a.name.trim().isEmpty) continue;
        final k = _key(a.name);
        t.artistName[k] ??= a.name.trim();
        artistRaw[k] = (artistRaw[k] ?? 0) + w;
      }
    }

    // plays and listening time (this year counts fully, last year half)
    for (final (y, w) in [(n.year, 1.0), (n.year - 1, 0.5)]) {
      for (final s in stats.year(y).songs) {
        if (!ok(s.item)) continue;
        know(s.item);
        t.plays[s.item.id] = (t.plays[s.item.id] ?? 0) + s.plays * w;
        final d = s.item.durationSec;
        if (d != null && d > 0 && s.plays > 0) {
          t.completion[s.item.id] = (s.ms / (s.plays * d * 1000)).clamp(0.0, 1.0);
        }
        art(s.item, s.plays * w * (0.4 + 0.6 * (t.completion[s.item.id] ?? 0.6)));
      }
    }
    for (final it in library.likes) {
      know(it);
      if (ok(it)) {
        t.liked.add(it.id);
        art(it, 3);
      }
    }
    final hist = library.history;
    final dayStart = DateTime(n.year, n.month, n.day);
    final yStart = dayStart.subtract(const Duration(days: 1));
    for (final h in hist) {
      if (!ok(h.item)) continue;
      know(h.item);
      final age = n.difference(h.at).inHours / 24.0;
      art(h.item, age < 14 ? 1.5 : 0.5);
      if (age < 14) {
        for (final a in h.item.artists.take(1)) {
          final k = _key(a.name);
          if (k.isNotEmpty) t.lately[k] = (t.lately[k] ?? 0) + 1;
        }
      }
    }
    for (final p in library.playlists.take(20)) {
      for (final it in p.items.take(40)) {
        if (!ok(it)) continue;
        know(it);
        art(it, 0.25);
      }
    }

    // the play log: skips, full listens, time of day, sessions
    final events = log?.events ?? const <PlayEvent>[]; // newest first
    final artistEvents = <String, int>{}, artistSkips = <String, int>{}, artistNear = <String, int>{};
    final hourNow = n.hour;
    var near = 0;
    for (final e in events) {
      if (!ok(e.item)) continue;
      know(e.item);
      if (e.skipped) t.skips[e.id] = (t.skips[e.id] ?? 0) + 1;
      if (e.completed) t.completes[e.id] = (t.completes[e.id] ?? 0) + 1;
      final a = _primary(e.item);
      final dh = (e.at.hour - hourNow).abs();
      final isNear = min(dh, 24 - dh) <= 2;
      if (isNear) near++;
      if (a != null) {
        artistEvents[a] = (artistEvents[a] ?? 0) + 1;
        if (e.skipped) artistSkips[a] = (artistSkips[a] ?? 0) + 1;
        if (isNear && !e.skipped) artistNear[a] = (artistNear[a] ?? 0) + 1;
        t.artistName[a] ??= e.item.artists.first.name.trim();
        artistRaw[a] = (artistRaw[a] ?? 0) + (e.skipped ? -0.8 : (e.completed ? 0.8 : 0.3));
        if (n.difference(e.at).inDays < 14) t.lately[a] = (t.lately[a] ?? 0) + (e.skipped ? 0 : 1);
      }
    }
    for (final e in artistEvents.entries) {
      if (e.value >= 2) t.artistSkipRate[e.key] = (artistSkips[e.key] ?? 0) / e.value;
    }
    if (near > 0) {
      for (final e in artistNear.entries) {
        t.artistHour[e.key] = e.value / near;
      }
    }
    // co-listening: artists played within 30 min of each other
    final chrono = events.reversed.where((e) => ok(e.item) && !e.skipped).toList();
    for (var i = 0; i < chrono.length; i++) {
      final a = _primary(chrono[i].item);
      if (a == null) continue;
      for (var j = i + 1; j < chrono.length && j <= i + 6; j++) {
        if (chrono[j].at.difference(chrono[i].at).inMinutes > 30) break;
        final b = _primary(chrono[j].item);
        if (b == null || b == a) continue;
        (t.coArtists[a] ??= {})[b] = ((t.coArtists[a] ??= {})[b] ?? 0) + 1;
        (t.coArtists[b] ??= {})[a] = ((t.coArtists[b] ??= {})[a] ?? 0) + 1;
      }
    }

    final mx = artistRaw.values.fold<double>(0, max);
    for (final e in artistRaw.entries) {
      t.artist[e.key] = mx <= 0 ? 0 : (e.value / mx).clamp(-1.0, 1.0);
    }

    // recent plays, yesterday's and today's
    final recentL = <(Item, DateTime)>[
      for (final e in events) (e.item, e.at),
      for (final h in hist) (h.item, h.at),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final seen = <String>{};
    for (final (it, at) in recentL) {
      if (!ok(it) || !seen.add(it.id)) continue;
      t.recent.add(it);
      if (!at.isBefore(yStart) && at.isBefore(dayStart)) t.yesterday.add(it);
      if (!at.isBefore(dayStart)) t.today.add(it);
    }

    // languages they play
    final lp = <String, int>{};
    for (final id in t.songs.keys) {
      final l = languageOf(t.songs[id]!);
      if (l != null) lp[l] = (lp[l] ?? 0) + 1 + (t.plays[id] ?? 0).round();
    }
    final tot = lp.values.fold<int>(0, (a, b) => a + b);
    for (final e in lp.entries) {
      t.language[e.key] = e.value / tot;
    }
    return t;
  }
}

/// One pick and why.
class DjPick {
  final Item item;
  final String reason;
  final double score;
  final bool fresh;
  const DjPick(this.item, this.reason, this.score, this.fresh);
  @override
  String toString() => '${item.id}(${score.toStringAsFixed(2)}${fresh ? ' new' : ''})';
}

enum DjFeedback { skip, like, complete }

class _Cand {
  final Item item;
  double rel = 0;
  final Set<String> seeds = {}; // ids of the songs whose radio suggested it
  final Set<String> tags = {};
  String? seedTitle; // "Kesariya"
  String? like; // artist it's "like"
  _Cand(this.item);
  String? get artist => _primary(item);
}

/// The DJ's recommender: candidates from YouTube Music (radio of what they
/// love, searches and playlists for what they asked), ranked by their own
/// listening (plays, full listens, skips, likes, time of day, artists and
/// languages they love, what they play together), then mixed for variety
/// (max 2 per artist in any 10, about a quarter new to them, nothing they
/// just heard). Learns from skips and likes as it plays. All on the phone.
/// Byte © 2026 Apurba Laskar.
class DjRecommender {
  final CandidateSource source;
  final TasteProfile Function() taste;
  final DateTime Function() now;

  /// Songs from the last [recentWindow] plays are never picked again.
  final int recentWindow;

  DjRecommender({required this.source, required this.taste, DateTime Function()? now, this.recentWindow = 50}) : now = now ?? DateTime.now;

  factory DjRecommender.forPhone({required InnerTube yt, required Library library, required ListeningStats stats, PlayLog? log}) =>
      DjRecommender(source: InnerTubeSource(yt), taste: () => TasteProfile.build(library: library, stats: stats, log: log));

  /// Share of songs new to them.
  static double freshShareFor(DjRequest r) {
    if (r.fresh) return 0.6;
    if (r.familiar || r.history != null) return 0.1;
    if (r.byArtists.isNotEmpty) return 0.3;
    return 0.3;
  }

  Future<List<Item>> _safe(Future<List<Item>> f) async {
    try {
      return await f.timeout(const Duration(seconds: 15));
    } catch (_) {
      return const [];
    }
  }

  /// Builds a mix for [req] ([size] songs to start; more come from [DjMix.next]).
  Future<DjMix> mix(DjRequest req, {int size = 20, Set<String> exclude = const {}}) async {
    final t = taste();
    final pool = <String, _Cand>{};
    _Cand add(Item it, double rel, String tag, {Item? seed, String? like}) {
      final c = pool.putIfAbsent(it.id, () => _Cand(it));
      c.rel = max(c.rel, rel);
      c.tags.add(tag);
      if (seed != null) {
        c.seeds.add(seed.id);
        c.seedTitle ??= seed.title;
      }
      if (like != null) c.like ??= like;
      return c;
    }

    void addRanked(List<Item> items, double top, double bottom, String tag, {Item? seed, String? like}) {
      for (var i = 0; i < items.length; i++) {
        final r = items.length <= 1 ? top : top - (top - bottom) * i / (items.length - 1);
        add(items[i], r, tag, seed: seed, like: like);
      }
    }

    final jobs = <Future<void>>[];
    void radioOf(Item seed, double top, String tag, {String? like}) {
      jobs.add(_safe(source.radio(seed)).then((l) => addRanked(l.take(25).toList(), top, top * 0.55, tag, seed: seed, like: like)));
    }

    final favs = t.favourites();
    final langs = req.languages;
    bool langOk(Item it) => langs.isEmpty || langs.contains(languageOf(it));

    // songs they know that fit what was asked
    if (req.history == 'yesterday') {
      final y = t.yesterday.isNotEmpty ? t.yesterday : t.recent.skip(5).take(25).toList();
      addRanked(y.where(langOk).take(30).toList(), 1.1, 0.9, 'yesterday');
      for (final s in y.take(2)) {
        radioOf(s, 0.55, 'radio');
      }
    } else if (req.history == 'recent') {
      addRanked(t.recent.where(langOk).take(30).toList(), 1.0, 0.8, 'recent');
      for (final s in t.recent.take(2)) {
        radioOf(s, 0.55, 'radio');
      }
    }

    for (final a in req.byArtists) {
      final mine = favs.where((i) => _byArtist(i, a)).take(15).toList();
      addRanked(mine, 1.0, 0.85, 'by');
      if (mine.isNotEmpty) radioOf(mine.first, 0.45, 'radio');
    }
    for (final a in req.likeArtists) {
      final mine = favs.where((i) => _byArtist(i, a)).toList();
      Future<void> seedAndRadio() async {
        Item? seed = mine.isNotEmpty ? mine.first : null;
        if (seed == null) {
          final s = await _safe(source.search('$a songs'));
          final by = s.where((i) => _byArtist(i, a)).toList();
          seed = by.isNotEmpty ? by.first : (s.isNotEmpty ? s.first : null);
          // a couple of theirs for flavour
          addRanked(by.take(4).toList(), 0.55, 0.45, 'likeself', like: a);
        }
        if (seed == null) return;
        final r = await _safe(source.radio(seed));
        addRanked(r.take(25).toList(), 1.0, 0.65, 'like', seed: seed, like: a);
        if (mine.length > 1) {
          final r2 = await _safe(source.radio(mine[1]));
          addRanked(r2.take(15).toList(), 0.85, 0.6, 'like', seed: mine[1], like: a);
        }
      }

      jobs.add(seedAndRadio());
      // a few of theirs by the artist, for familiarity
      addRanked(mine.take(4).toList(), 0.6, 0.5, 'likeself', like: a);
      // artists they play together with this one
      final co = t.coArtists[_key(a)];
      if (co != null) {
        final top = co.keys.toList()..sort((x, y) => co[y]!.compareTo(co[x]!));
        for (final other in top.take(3)) {
          addRanked(favs.where((i) => _primary(i) == other).take(3).toList(), 0.75, 0.65, 'co', like: a);
        }
      }
    }

    final qs = req.queries;
    for (var i = 0; i < qs.length && i < 4; i++) {
      final q = qs[i];
      jobs.add(_safe(source.search(q)).then((l) {
        addRanked(l.take(20).toList(), 1.0, 0.6, 'search');
      }));
      if (i < 2 && req.byArtists.isEmpty) {
        jobs.add(_safe(source.playlist(q)).then((l) => addRanked(l.take(40).toList(), 0.9, 0.55, 'playlist')));
      }
    }

    // their own songs in the asked language, and radio from the best of them
    if (langs.isNotEmpty && req.byArtists.isEmpty) {
      final mine = favs.where((i) => langs.contains(languageOf(i))).take(20).toList();
      addRanked(mine, 0.8, 0.6, 'mine');
      for (final s in mine.take(2)) {
        radioOf(s, 0.7, 'radio');
      }
    }

    // no request: a daily mix from what they love (more of what suits this hour)
    if (req.isMix && req.history == null) {
      final ranked = [...favs]..sort((a, b) {
        double h(Item i) => t.songAffinity(i.id) + 0.6 * (t.artistHour[_primary(i)] ?? 0);
        return h(b).compareTo(h(a));
      });
      addRanked(ranked.take(40).toList(), 0.75, 0.5, 'fav');
      final seeds = <Item>[];
      final usedArtists = <String?>{};
      for (final s in ranked) {
        if (usedArtists.add(_primary(s))) seeds.add(s);
        if (seeds.length >= 5) break;
      }
      for (final s in seeds) {
        radioOf(s, 0.7, 'radio');
      }
      if (seeds.isEmpty) jobs.add(_safe(source.search('top hindi songs')).then((l) => addRanked(l, 0.7, 0.5, 'search')));
    }

    // only moods asked ("sad"): their own songs that the search also found
    // are kept; radio of the top search hit widens the pool
    if (req.byArtists.isEmpty && req.likeArtists.isEmpty && !req.isMix && req.history == null && qs.isNotEmpty) {
      await Future.wait(jobs);
      jobs.clear();
      final top = pool.values.where((c) => c.tags.contains('search')).toList()..sort((a, b) => b.rel.compareTo(a.rel));
      for (final c in top.take(2)) {
        radioOf(c.item, 0.7, 'radio');
      }
    }
    await Future.wait(jobs);

    final m = DjMix._(req, t, pool, this, {...exclude});
    m._fill(size);
    return m;
  }
}

/// A playing DJ mix: its picks so far, the rest of the pool, and what it
/// learned during the session.
class DjMix {
  final DjRequest request;
  final TasteProfile taste;
  final DjRecommender recommender;
  final Map<String, _Cand> _pool;
  final Set<String> _exclude;

  /// Picks in play order (the queue the DJ handed to the player).
  final List<DjPick> picks = [];

  final Set<String> _skipped = {};
  final Set<String> _liked = {};
  final Map<String, double> _artistAdj = {};
  final Map<String, double> _seedAdj = {};

  DjMix._(this.request, this.taste, this._pool, this.recommender, this._exclude);

  int get poolSize => _pool.length;
  double get freshShare => DjRecommender.freshShareFor(request);

  String? reasonFor(String id) {
    for (final p in picks) {
      if (p.item.id == id) return p.reason;
    }
    return null;
  }

  /// Songs that must not be picked (just heard, disliked, skipped now).
  bool _blocked(String id) {
    if (_exclude.contains(id) || _skipped.contains(id)) return true;
    if (taste.disliked(id)) return true;
    final h = request.history;
    final recent = h == 'yesterday'
        ? taste.today.take(recommender.recentWindow ~/ 2)
        : h == 'recent'
        ? const <Item>[]
        : taste.recent.take(recommender.recentWindow);
    return recent.any((i) => i.id == id);
  }

  double score(String id) {
    final c = _pool[id];
    if (c == null) return double.negativeInfinity;
    final t = taste;
    final a = c.artist;
    var s = c.rel;
    s += 0.2 * min(c.seeds.length - 1, 3).clamp(0, 3);
    if (c.tags.length > 1) s += 0.1;
    if (t.isKnown(id)) s += t.songAffinity(id);
    if (a != null) {
      s += 0.7 * (t.artist[a] ?? 0);
      s -= 0.9 * (t.artistSkipRate[a] ?? 0);
      s += 0.2 * (t.artistHour[a] ?? 0);
      // artists they play together with the ones asked for / liked now
      for (final x in [...request.likeArtists.map(_key), ..._likedArtists]) {
        if ((t.coArtists[x]?[a] ?? 0) > 0) {
          s += 0.25;
          break;
        }
      }
      s += _artistAdj[a] ?? 0;
    }
    for (final sd in c.seeds) {
      s += _seedAdj[sd] ?? 0;
    }
    final l = languageOf(c.item);
    if (request.languages.isEmpty && !request.isMix) {
      if (l != null) s += 0.15 * (t.language[l] ?? 0);
    } else if (request.languages.isNotEmpty && l != null && !request.languages.contains(l)) {
      s -= 0.6; // clearly another language than asked
    }
    if (request.byArtists.isNotEmpty && !request.byArtists.any((x) => _byArtist(c.item, x))) s -= 0.8;
    if (request.likeArtists.isNotEmpty && request.likeArtists.any((x) => _byArtist(c.item, x))) s -= 0.15;
    if (_liked.contains(id)) s += 0.3;
    return s;
  }

  Iterable<String> get _likedArtists => _liked.map((id) => _pool[id]?.artist).whereType<String>();

  bool _exempt(String? artist) => artist != null && request.byArtists.any((x) => _key(x) == artist || artist.contains(_key(x)));

  /// Picks up to [count] more songs after [before] (what's already in play order).
  List<DjPick> _choose(int count, List<Item> before) {
    final scores = <String, double>{};
    final taken = before.map((e) => e.id).toSet();
    for (final id in _pool.keys) {
      if (taken.contains(id) || _blocked(id)) continue;
      scores[id] = score(id);
    }
    final fresh = scores.keys.where((id) => !taste.isKnown(id)).toList()..sort((a, b) => scores[b]!.compareTo(scores[a]!));
    final known = scores.keys.where((id) => taste.isKnown(id)).toList()..sort((a, b) => scores[b]!.compareTo(scores[a]!));
    final order = [...before];
    var freshSoFar = before.where((i) => !taste.isKnown(i.id)).length;
    final out = <DjPick>[];
    final share = freshShare;

    bool fits(String id) {
      final a = _pool[id]!.artist;
      if (a == null || _exempt(a)) return true;
      final window = order.length < 9 ? order : order.sublist(order.length - 9);
      return window.where((i) => _primary(i) == a).length < 2;
    }

    // 1.4.1: uploads of one song (lyric video, slowed, another channel) count once
    bool dup(String id) {
      final it = _pool[id]!.item;
      return order.any((o) => o.id != id && songKey(o) == songKey(it) && (o.kind == ItemKind.video || it.kind == ItemKind.video || _primary(o) == _primary(it)));
    }

    String? takeFrom(List<String> l) {
      for (final id in l) {
        if (fits(id) && !dup(id)) return id;
      }
      return null;
    }

    while (out.length < count && (fresh.isNotEmpty || known.isNotEmpty)) {
      final n = order.length + 1;
      final wantFresh = freshSoFar < (share * n).round();
      String? id = wantFresh ? takeFrom(fresh) : takeFrom(known);
      id ??= wantFresh ? takeFrom(known) : takeFrom(fresh);
      if (id == null) {
        // only same-artist songs left: stop rather than break variety
        break;
      }
      final isFresh = !taste.isKnown(id);
      (isFresh ? fresh : known).remove(id);
      if (isFresh) freshSoFar++;
      final c = _pool[id]!;
      order.add(c.item);
      out.add(DjPick(c.item, _reason(c), scores[id]!, isFresh));
    }
    return out;
  }

  void _fill(int size) {
    picks.addAll(_choose(size, const []));
  }

  String _reason(_Cand c) {
    final t = taste;
    final id = c.item.id;
    final known = t.isKnown(id);
    final art = c.item.artists.isEmpty ? null : c.item.artists.first.name;
    if (c.tags.contains('yesterday')) return 'You played this yesterday';
    if (c.tags.contains('recent') && known) return 'You played this recently';
    for (final a in request.byArtists) {
      if (_byArtist(c.item, a)) {
        final p = (t.plays[id] ?? 0).round();
        if (known && p >= 2) return 'By $a · you\'ve played it $p times';
        return known ? 'By $a, one you know' : 'New for you, by $a';
      }
    }
    if (known) {
      if (t.liked.contains(id)) return 'You liked this';
      if (c.seedTitle != null && c.seeds.any((s) => s != id)) return 'Because you play ${c.seedTitle}';
      final p = (t.plays[id] ?? 0).round();
      if (p >= 3) return 'One of your most played · $p plays';
      if (c.tags.contains('co') && c.like != null) return 'You play this with ${c.like}';
      if (art != null && (t.artist[_primary(c.item)] ?? 0) > 0.5) return 'More from $art, one of your top artists';
      return 'From your listening';
    }
    if (c.like != null) return 'New for you, like ${c.like}';
    if (c.seedTitle != null && c.seeds.any((s) => taste.isKnown(s))) return 'New for you, like ${c.seedTitle}';
    if (art != null && (t.artist[_primary(c.item)] ?? 0) > 0.3) return 'New from $art, one of your top artists';
    if (!request.isMix && request.summary.isNotEmpty && request.freeText == null) return 'New for you · ${request.summary}';
    return 'New for you';
  }

  /// Learns from what they did with a song during the session.
  void feedback(Item it, DjFeedback f) {
    final a = _primary(it);
    final c = _pool[it.id];
    switch (f) {
      case DjFeedback.skip:
        _skipped.add(it.id);
        if (a != null) _artistAdj[a] = (_artistAdj[a] ?? 0) - 0.9;
        for (final s in c?.seeds ?? const <String>{}) {
          _seedAdj[s] = (_seedAdj[s] ?? 0) - 0.35;
        }
      case DjFeedback.like:
        _liked.add(it.id);
        if (a != null) _artistAdj[a] = (_artistAdj[a] ?? 0) + 0.7;
        for (final s in c?.seeds ?? const <String>{}) {
          _seedAdj[s] = (_seedAdj[s] ?? 0) + 0.3;
        }
      case DjFeedback.complete:
        if (a != null) _artistAdj[a] = (_artistAdj[a] ?? 0) + 0.15;
    }
  }

  /// Re-ranks everything after [played] (the songs already heard, current
  /// one last) and returns the new upcoming [count] picks. The pick list
  /// becomes played + new upcoming.
  List<DjPick> rerank(List<Item> played, {int count = 15}) {
    final up = _choose(count, played);
    final playedIds = played.map((e) => e.id).toSet();
    final keep = [
      for (final it in played)
        picks.firstWhere((p) => p.item.id == it.id, orElse: () => DjPick(it, reasonFor(it.id) ?? '', 0, !taste.isKnown(it.id))),
    ];
    picks
      ..clear()
      ..addAll(keep)
      ..addAll(up.where((p) => !playedIds.contains(p.item.id)));
    return up;
  }

  /// [count] more songs after the current picks (fetches more radio when low).
  Future<List<DjPick>> more({int count = 10}) async {
    if (_pool.length - picks.length < count * 2) await _grow();
    final up = _choose(count, picks.map((p) => p.item).toList());
    picks.addAll(up);
    return up;
  }

  Future<void> _grow() async {
    // radio of what they liked or played to the end in this session, else the last picks
    final seeds = <Item>[
      ..._liked.map((id) => _pool[id]?.item).whereType<Item>(),
      ...picks.reversed.where((p) => !_skipped.contains(p.item.id)).map((p) => p.item),
    ].take(2);
    for (final s in seeds) {
      final l = await recommender._safe(recommender.source.radio(s));
      for (var i = 0; i < l.length && i < 25; i++) {
        final c = _pool.putIfAbsent(l[i].id, () => _Cand(l[i]));
        c.rel = max(c.rel, 0.75 - 0.3 * i / 25);
        c.tags.add('radio');
        c.seeds.add(s.id);
        c.seedTitle ??= s.title;
      }
    }
  }
}
