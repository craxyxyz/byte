import 'models.dart';

/// 1.4.6: search puts the original song above its slowed / reverb / lo-fi /
/// sped-up / 8D / cover uploads (2.0: remixes, dance / club / DJ mixes too), unless the search itself asks for one of
/// those ("tum hi ho slowed" still finds the slowed one first).
///
/// The catalogue's own order is kept otherwise (a stable sort), so nothing
/// else about the results moves.

/// Edits of a song that change how it sounds (strong) and other people's
/// takes on it (soft).
final _strong = RegExp(
  r'\b(slowed|reverb(?:ed)?|lo-?fi|lo fi|sped[ -]?up|speed[ -]?up|nightcore|8d|16d|bass[ -]?boost(?:ed)?|jhankar|mashup|daycore|remix(?:ed)?|rmx|dance[ -]?mix|club[ -]?mix|dj[ -]?(?:mix|remix|version)|bootleg|edm[ -]?mix)\b',
  caseSensitive: false,
);
final _soft = RegExp(r'\b(cover|karaoke|instrumental|reprise|unplugged|female[ -]version|male[ -]version|cover[ -]version)\b', caseSensitive: false);

/// How far down an item should go for [query]: 0 = the original.
int searchPenalty(String query, Item it) {
  if (it.kind != ItemKind.song && it.kind != ItemKind.video) return 0;
  final text = [it.title, it.album ?? '', for (final a in it.artists) a.name].join(' ');
  final q = query.toLowerCase();
  var p = 0;
  for (final m in _strong.allMatches(text)) {
    if (!_asked(q, m.group(0)!)) p = 2;
  }
  if (p == 0) {
    for (final m in _soft.allMatches(text)) {
      if (!_asked(q, m.group(0)!)) p = 1;
    }
  }
  return p;
}

/// Whether the search itself asks for this kind of upload ("remix" asks for
/// a "DJ Remix", "dance" for a "Dance Mix"; "mix" or "version" alone don't).
bool _asked(String q, String match) {
  final tokens = q.split(RegExp(r'[^a-z0-9-]+')).where((t) => t.isNotEmpty).toList();
  if (q.contains(_root(match))) {
    // one-word kinds keep the old reading (a query containing the word)
    if (!match.contains(RegExp(r'[ -]')) || RegExp(r'^(sped|speed|bass|lo)', caseSensitive: false).hasMatch(match)) return true;
  }
  for (final w in match.toLowerCase().split(RegExp(r'[ -]'))) {
    if (w.isEmpty || w == 'mix' || w == 'version' || w == 'dj') continue;
    final r = _root(w);
    if (tokens.any((t) => t.startsWith(r))) return true;
  }
  return false;
}

/// The part of a matched word a query would contain ("reverbed" → "reverb",
/// "lo-fi" → "lo", "sped up" → "sped", "bass boosted" → "bass").
String _root(String w) {
  final s = w.toLowerCase();
  if (s.startsWith('reverb')) return 'reverb';
  if (s.startsWith('lo')) return 'lo';
  if (s.startsWith('bass')) return 'bass';
  if (s.startsWith('sped') || s.startsWith('speed')) return 'sp';
  return s.split(RegExp(r'[ -]')).first;
}

/// [items] with originals first; the order is otherwise unchanged.
List<Item> rankSearchItems(String query, List<Item> items) {
  if (items.length < 2) return items;
  final indexed = [for (var i = 0; i < items.length; i++) (i, searchPenalty(query, items[i]), items[i])];
  indexed.sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
  return [for (final e in indexed) e.$3];
}

/// Each shelf ranked like [rankSearchItems]; a "Top result" shelf that holds
/// only edits moves below the first shelf that has the original.
List<Shelf> rankSearchShelves(String query, List<Shelf> shelves) {
  final out = [for (final s in shelves) Shelf(s.title, rankSearchItems(query, s.items), subtitle: s.subtitle, moreBrowseId: s.moreBrowseId, moreParams: s.moreParams)];
  bool onlyEdits(Shelf s) {
    final songs = s.items.where((i) => i.kind == ItemKind.song || i.kind == ItemKind.video).toList();
    return songs.isNotEmpty && songs.every((i) => searchPenalty(query, i) > 0);
  }

  bool hasOriginal(Shelf s) => s.items.any((i) => (i.kind == ItemKind.song || i.kind == ItemKind.video) && searchPenalty(query, i) == 0);
  if (out.isNotEmpty && onlyEdits(out.first)) {
    final j = out.indexWhere(hasOriginal);
    if (j > 0) {
      final top = out.removeAt(0);
      out.insert(j, top);
    }
  }
  return out;
}
