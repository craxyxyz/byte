import 'dart:math';

import '../core/innertube.dart';
import '../core/models.dart';
import '../data/library.dart';
import '../data/stats.dart';
import 'dj_lines.dart';

/// A mood the DJ can switch to ("Switch it up").
class DjVibe {
  final String id;
  final String title; // shown in the app
  final String spoken; // said by the DJ
  final String query; // what to look for on YouTube Music
  const DjVibe(this.id, this.title, this.spoken, this.query);
}

const djVibes = <DjVibe>[
  DjVibe('chill', 'Chill', 'kuch chill gaane', 'chill hindi songs'),
  DjVibe('party', 'Party', 'party mode', 'bollywood party songs'),
  DjVibe('romantic', 'Romantic', 'thoda romance', 'romantic hindi songs'),
  DjVibe('retro', 'Retro', 'retro classics', '90s hindi songs'),
  DjVibe('bangla', 'Bangla', 'Bangla gaan', 'bangla hit songs'),
  DjVibe('focus', 'Focus', 'focus music', 'lofi focus instrumental'),
  DjVibe('workout', 'Workout', 'workout energy', 'workout songs hindi'),
  DjVibe('soft', 'Soft & sad', 'kuch soft gaane', 'sad songs hindi'),
];

DjVibe vibeById(String id) => djVibes.firstWhere((v) => v.id == id, orElse: () => djVibes.first);

/// The vibe that suits the time of day.
DjVibe vibeForTime(DateTime t) => switch (DjLines.partOfDay(t)) {
  'morning' => vibeById('chill'),
  'afternoon' => vibeById('workout'),
  'evening' => vibeById('romantic'),
  _ => vibeById('soft'),
};

enum SegmentKind { favourites, throwback, discover, language, vibe, request }

/// One part of a DJ session: a theme and its songs.
class DjSegment {
  final SegmentKind kind;
  final String title;
  final String subtitle;
  final List<Item> items;
  final DjVibe? vibe;
  final String? language;

  /// When a throwback's songs were last played ("2025", "March").
  final String? period;
  const DjSegment({required this.kind, required this.title, required this.subtitle, required this.items, this.vibe, this.language, this.period});

  DjMoment get moment => switch (kind) {
    SegmentKind.favourites => DjMoment.favourites,
    SegmentKind.throwback => DjMoment.throwback,
    SegmentKind.discover => DjMoment.discover,
    SegmentKind.language => DjMoment.language,
    SegmentKind.vibe => DjMoment.vibe,
    SegmentKind.request => DjMoment.request,
  };
}

/// Which languages someone listens to, from the scripts and words in their songs.
Map<String, int> languageProfile(Iterable<Item> items) {
  final out = <String, int>{};
  final bengaliScript = RegExp(r'[\u0980-\u09FF]');
  final devanagari = RegExp(r'[\u0900-\u097F]');
  final bengaliWords = RegExp(r'\b(bangla|bengali|rabindra|rabindrasangeet|nazrul|kolkata|tagore|baul|adhunik)\b', caseSensitive: false);
  // 1.4.1: Bengali songs written in Latin letters ("Tomake Chai", "Bojhena Shey Bojhena")
  final bengaliRoman = RegExp(
    r'\b(tomake|tomar|tomay|aamar|amake|aamake|tumi|ami|aami|bhalobasha|bhalobashi|bhalobeshe|bhalolaage|bojhena|bojhe|shudhu|ekhon|keno|jeno|kache|kachhe|theke|thakte|thakbo|bolbo|korbo|parbo|robe|nirobe|ekla|cholo|ebhabe|emon|ektu|onek|premer|likhechi|dakchhi|toke|tui|chere|niye|majhe|hoye|olpo|ghore|jonmodin|ekta|egiye|ovhiman|shey)\b',
    caseSensitive: false,
  );
  final hindiWords = RegExp(r'\b(bollywood|hindi|filmi|ghazal|qawwali|sufi)\b', caseSensitive: false);
  final punjabi = RegExp(r'[\u0A00-\u0A7F]|\bpunjabi\b', caseSensitive: false);
  for (final it in items) {
    final text = '${it.title} ${it.artistLine} ${it.album ?? ''}';
    String? lang;
    if (bengaliScript.hasMatch(text) || bengaliWords.hasMatch(text) || bengaliRoman.hasMatch(it.title)) {
      lang = 'Bengali';
    } else if (punjabi.hasMatch(text)) {
      lang = 'Punjabi';
    } else if (devanagari.hasMatch(text) || hindiWords.hasMatch(text)) {
      lang = 'Hindi';
    }
    if (lang != null) out[lang] = (out[lang] ?? 0) + 1;
  }
  return out;
}

/// Builds the DJ's segments from what's on the phone (listening history,
/// likes, library, plays) plus YouTube Music's radio and search. Everything
/// is worked out on the phone.
class DjBrain {
  final Library library;
  final ListeningStats stats;
  final InnerTube yt;
  final Random rng;
  final DateTime Function() now;

  /// Songs per section; null = 4 to 6, varied like a radio show.
  int? segmentSize;

  DjBrain({required this.library, required this.stats, required this.yt, Random? rng, DateTime Function()? now, this.segmentSize})
    : rng = rng ?? Random(),
      now = now ?? DateTime.now;

  int _step = 0;

  /// The running order, like a radio show: current favourites, then
  /// throwbacks from their own history, then new discoveries close to their
  /// taste, then back to favourites. It loops.
  static const order = [SegmentKind.favourites, SegmentKind.throwback, SegmentKind.discover];

  // ── taste ──
  List<Item> get _history => library.history.map((h) => h.item).where(_ok).toList();
  bool _ok(Item i) => i.isPlayable && i.kind != ItemKind.episode && !i.isDav;

  /// Most-loved songs: plays this year and last, likes, playlist songs.
  List<Item> favourites() {
    final score = <String, double>{};
    final byId = <String, Item>{};
    void add(Item it, double s) {
      if (!_ok(it)) return;
      byId[it.id] ??= it;
      score[it.id] = (score[it.id] ?? 0) + s;
    }

    final y = now().year;
    for (final s in stats.year(y).songs.take(60)) {
      add(s.item, 2.0 + s.plays);
    }
    for (final s in stats.year(y - 1).songs.take(30)) {
      add(s.item, 1.0 + s.plays * 0.5);
    }
    for (final it in library.likes) {
      add(it, 3);
    }
    final h = _history;
    for (var i = 0; i < h.length && i < 100; i++) {
      add(h[i], 1.0 - i / 120);
    }
    for (final p in library.playlists.take(20)) {
      for (final it in p.items.take(30)) {
        add(it, 0.4);
      }
    }
    final ids = score.keys.toList()..sort((a, b) => score[b]!.compareTo(score[a]!));
    return [for (final id in ids) byId[id]!];
  }

  /// Everything the listener already knows (for "new for you").
  Set<String> known() => {
    ..._history.map((i) => i.id),
    ...library.likes.map((i) => i.id),
    for (final y in stats.years) ...stats.year(y).songs.map((s) => s.item.id),
  };

  /// When they last played [items] ("2025" for last year, else the month).
  String? periodOf(Iterable<Item> items) {
    final ids = items.map((e) => e.id).toSet();
    final when = <DateTime>[for (final h in library.history) if (ids.contains(h.item.id)) h.at];
    final y = now().year;
    final lastYear = stats.year(y - 1).songs.where((s) => ids.contains(s.item.id)).length;
    if (when.length < ids.length / 2 && lastYear >= ids.length / 2) return '${y - 1}';
    if (when.isEmpty) return null;
    final count = <String, int>{};
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    for (final d in when) {
      final k = d.year == y ? months[d.month - 1] : '${d.year}';
      count[k] = (count[k] ?? 0) + 1;
    }
    final top = count.entries.reduce((a, b) => b.value > a.value ? b : a);
    return top.value * 2 >= when.length ? top.key : null;
  }

  /// Songs they loved but haven't played in a while.
  List<Item> throwbacks() {
    final cutoff = now().subtract(const Duration(days: 21));
    final recent = library.history.where((h) => h.at.isAfter(cutoff)).map((h) => h.item.id).toSet();
    final old = library.history.where((h) => h.at.isBefore(cutoff)).map((h) => h.item).where(_ok).toList();
    final y = now().year;
    final lastYear = stats.year(y - 1).songs.map((s) => s.item).where((i) => _ok(i) && !recent.contains(i.id));
    final out = <Item>[];
    final seen = <String>{};
    for (final it in [...lastYear, ...old]) {
      if (seen.add(it.id)) out.add(it);
    }
    return out;
  }

  /// The language besides English they listen to most (null = none clear).
  String? mainLanguage() {
    final p = languageProfile([...favourites().take(80), ..._history.take(150)]);
    if (p.isEmpty) return null;
    final e = p.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return e.first.value >= 2 ? e.first.key : null;
  }

  // ── helpers ──
  List<Item> _take(Iterable<Item> pool, Set<String> exclude, int n, {bool shuffle = true, int? fromTop}) {
    var list = pool.where((i) => _ok(i) && !exclude.contains(i.id)).toList();
    if (fromTop != null && list.length > fromTop) list = list.sublist(0, fromTop);
    if (shuffle) list.shuffle(rng);
    final out = <Item>[];
    final seen = <String>{};
    for (final i in list) {
      if (seen.add(i.id)) out.add(i);
      if (out.length >= n) break;
    }
    return out;
  }

  Future<List<Item>> _radio(Item seed, Set<String> exclude, {Set<String>? notKnown}) async {
    try {
      final n = await yt.next(seed.id);
      return n.queue.where((i) => i.id != seed.id && _ok(i) && !exclude.contains(i.id) && !(notKnown?.contains(i.id) ?? false)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Item>> _search(String q, Set<String> exclude) async {
    try {
      final r = await yt.search(q, SearchFilter.songs);
      return r.where((i) => _ok(i) && !exclude.contains(i.id)).toList();
    } catch (_) {
      return const [];
    }
  }

  // ── segments ──
  Future<DjSegment?> build(SegmentKind kind, {Set<String> exclude = const {}, DjVibe? vibe}) async {
    final n = segmentSize ?? 4 + rng.nextInt(3);
    switch (kind) {
      case SegmentKind.favourites:
        final fav = favourites();
        var items = _take(fav, exclude, n, fromTop: max(n * 4, 24));
        if (items.length < n ~/ 2 && fav.isNotEmpty) {
          items = [...items, ..._take(await _radio(fav.first, {...exclude, ...items.map((e) => e.id)}), {}, n - items.length, shuffle: false)];
        }
        if (items.isEmpty) return null;
        return DjSegment(kind: kind, title: 'Your favourites', subtitle: 'The songs you keep coming back to', items: items);
      case SegmentKind.throwback:
        // only from their own history: songs they played before, not lately
        final items = _take(throwbacks(), exclude, n);
        if (items.length < 2) return null;
        final period = periodOf(items);
        return DjSegment(
          kind: kind,
          title: period == null ? 'Throwback' : '$period throwbacks',
          subtitle: 'Old favourites you haven\'t played in a while',
          items: items,
          period: period,
        );
      case SegmentKind.discover:
        final fav = favourites();
        final k = known();
        final seeds = _take(fav, {}, 3, fromTop: 30);
        final pool = <Item>[];
        for (final s in seeds) {
          pool.addAll(await _radio(s, exclude, notKnown: k));
          if (pool.length >= n * 2) break;
        }
        if (pool.isEmpty) pool.addAll((await _search('new hindi songs', exclude)).where((i) => !k.contains(i.id)));
        // the radio's top picks are the closest matches: keep the order mostly
        final items = _take(pool, exclude, n, fromTop: n * 3);
        if (items.isEmpty) return null;
        return DjSegment(kind: kind, title: 'New for you', subtitle: 'Picked from what you love', items: items);
      case SegmentKind.language:
        final lang = mainLanguage() ?? 'Hindi';
        final mine = favourites().where((i) => languageProfile([i]).containsKey(lang)).toList();
        final items = _take(mine, exclude, n ~/ 2);
        final rest = n - items.length;
        final ex = {...exclude, ...items.map((e) => e.id)};
        final pool = <Item>[];
        if (mine.isNotEmpty) pool.addAll(await _radio(mine[rng.nextInt(mine.length)], ex));
        if (pool.length < rest) {
          final q = switch (lang) {
            'Bengali' => 'bangla hit songs',
            'Punjabi' => 'punjabi hit songs',
            _ => 'bollywood hit songs',
          };
          pool.addAll(await _search(q, ex));
        }
        // Bengali listeners get a Bengali + Hindi blend
        if (lang == 'Bengali' && rest > 2) pool.insertAll(0, (await _search('arijit singh hits', ex)).take(2));
        items.addAll(_take(pool, ex, rest, fromTop: rest * 3));
        if (items.isEmpty) return null;
        final title = lang == 'Bengali' ? 'Bengali + Hindi mix' : '$lang mix';
        return DjSegment(
          kind: kind,
          title: title,
          subtitle: 'In your language',
          items: items,
          language: lang == 'Bengali' ? 'Bangla aur Hindi' : lang,
        );
      case SegmentKind.request:
        return null; // built by the recommender (DJ chat)
      case SegmentKind.vibe:
        final v = vibe ?? vibeForTime(now());
        final items = _take(await _search(v.query, exclude), exclude, n, fromTop: n * 3);
        if (items.isEmpty) return null;
        return DjSegment(kind: kind, title: v.title, subtitle: 'A ${v.title.toLowerCase()} set', items: items, vibe: v);
    }
  }

  /// The next segment in the running order (skips any that come out empty).
  Future<DjSegment?> next({Set<String> exclude = const {}}) async {
    for (var tries = 0; tries < order.length; tries++) {
      final kind = order[_step % order.length];
      _step++;
      final s = await build(kind, exclude: exclude);
      if (s != null && s.items.isNotEmpty) return s;
    }
    // nothing personal yet (a brand-new phone): the time-of-day vibe
    return build(SegmentKind.vibe, exclude: exclude);
  }

  /// "Switch it up": a vibe different from [current].
  DjVibe nextVibe(String? current) {
    final options = djVibes.where((v) => v.id != current).toList();
    return options[rng.nextInt(options.length)];
  }

  void reset() => _step = 0;
}
