import 'dart:math';

import '../core/innertube.dart';
import '../core/models.dart';
import 'recommender.dart';

// Byte © 2026 Apurba Laskar.
//
// "Up next" / song radio, made personal. YouTube Music's radio for a song is
// the same for everyone; Byte seeds it with the listener's own signals and
// re-ranks what comes back, on the phone:
//  • candidates: the song's radio + its "related" songs + the radio of one of
//    the listener's own songs close to the seed (same artist, else same
//    language, picked by likes / plays / full listens);
//  • score: closeness to the seed, plus how much they love the song and its
//    artist (likes, imported likes, plays, full listens, repeats, time of
//    day), minus skips (under 30 s) of the song and of the artist;
//  • the seed's language is kept; uploads of the same song (lyric video,
//    slowed, "full song", another channel) count once; nothing from their
//    last 50 plays; at most 2 by one artist in any 10;
//  • about 70 % familiar (songs they know, or by artists they love) and
//    30 % discovery.

/// One way of writing a song's name that all its uploads share.
String songKey(Item it) {
  var t = it.title.toLowerCase();
  t = t.replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
  t = t.replaceAll(RegExp(r'\s[-|–:]\s.*$'), ' ');
  t = t.replaceAll(
    RegExp(r'\b(official|video|audio|lyrics?|lyrical|full song|title track|song|hd|4k|slowed|reverb|lofi|lo-fi|sped up|remastered|remake|cover|karaoke|from|feat\.?|ft\.?)\b.*$|\b(official|video|audio|lyrical)\b'),
    ' ',
  );
  t = t.replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.isEmpty ? it.title.toLowerCase().trim() : t;
}

final _reupload = RegExp(r'\b(cover|remake|karaoke|slowed|reverb|lofi|lo-fi|sped up|8d|lyrics?|lyrical|title track)\b', caseSensitive: false);

bool _sameSong(Item a, Item b) {
  if (songKey(a) != songKey(b)) return false;
  if (_reupload.hasMatch(a.title) || _reupload.hasMatch(b.title)) return true;
  final aa = a.artists.map((x) => x.name.toLowerCase().trim()).toSet();
  final bb = b.artists.map((x) => x.name.toLowerCase().trim()).toSet();
  // the same title by an overlapping artist, or an upload by a channel
  return aa.intersection(bb).isNotEmpty || a.kind == ItemKind.video || b.kind == ItemKind.video || aa.isEmpty || bb.isEmpty;
}

String? _artistKey(Item it) => it.artists.isEmpty || it.artists.first.name.trim().isEmpty ? null : it.artists.first.name.trim().toLowerCase();

/// A scored up-next pick (why it's there is kept for the queue sheet/tests).
class RadioPick {
  final Item item;
  final double score;
  final bool familiar;
  final String why;
  const RadioPick(this.item, this.score, this.familiar, this.why);
  @override
  String toString() => '${item.title} — ${item.artistLine}${familiar ? '' : ' (new)'}';
}

class PersonalRadio {
  /// Their plays never picked again.
  static const recentWindow = 50;
  static const familiarShare = 0.7;

  /// The listener's own song to seed a second radio with: same artist as
  /// [seed] first, else same language; their best-loved such song.
  static Item? personalSeed(Item seed, TasteProfile t) {
    final a = _artistKey(seed);
    final lang = languageOf(seed);
    Item? best;
    var bestS = 0.15;
    for (final it in t.songs.values) {
      if (it.id == seed.id || t.disliked(it.id) || _sameSong(it, seed)) continue;
      final sameArtist = a != null && _artistKey(it) == a;
      final sameLang = lang != null && languageOf(it) == lang;
      if (!sameArtist && !sameLang) continue;
      final s = t.songAffinity(it.id) + (sameArtist ? 0.5 : 0) + 0.3 * (t.artistHour[_artistKey(it)] ?? 0);
      if (s > bestS) {
        bestS = s;
        best = it;
      }
    }
    return best;
  }

  /// Ranks [lists] (each in the source's own order: the seed's radio, its
  /// related songs, the personal seed's radio) for [seed] and returns up to
  /// [count] picks. [exclude]: already queued / heard this session.
  static List<RadioPick> rank(Item seed, List<List<Item>> lists, TasteProfile t, {int count = 25, Set<String> exclude = const {}}) {
    final rel = <String, double>{};
    final agree = <String, int>{};
    final items = <String, Item>{};
    final weights = [1.0, 0.8, 0.85, 0.7]; // radio, related, their seed's radio, their own songs
    for (var li = 0; li < lists.length; li++) {
      final l = lists[li];
      final w = li < weights.length ? weights[li] : 0.7;
      for (var i = 0; i < l.length; i++) {
        final it = l[i];
        if (!it.isPlayable || it.id == seed.id) continue;
        items[it.id] ??= it;
        final r = w * (1.0 - 0.5 * i / max(1, l.length - 1));
        rel[it.id] = max(rel[it.id] ?? 0, r);
        agree[it.id] = (agree[it.id] ?? 0) + 1;
      }
    }
    final recent = t.recent.take(recentWindow).toList();
    final recentIds = recent.map((e) => e.id).toSet();
    final seedLang = languageOf(seed);
    final scored = <(Item, double, bool, String)>[];
    for (final it in items.values) {
      if (exclude.contains(it.id) || recentIds.contains(it.id) || t.disliked(it.id)) continue;
      if (_sameSong(it, seed) || recent.any((r) => _sameSong(r, it))) continue;
      final a = _artistKey(it);
      final known = t.isKnown(it.id);
      final artistLove = a == null ? 0.0 : (t.artist[a] ?? 0);
      var s = rel[it.id]! + 0.15 * min(agree[it.id]! - 1, 2);
      var why = 'radio';
      if (known) {
        s += t.songAffinity(it.id);
        why = t.liked.contains(it.id) ? 'you liked it' : 'you play it';
      }
      if (a != null) {
        s += 0.7 * artistLove;
        // skips of any artist on the song count (a duet with one they skip)
        var skipRate = 0.0;
        for (final x in it.artists) {
          skipRate = max(skipRate, t.artistSkipRate[x.name.trim().toLowerCase()] ?? 0);
        }
        s -= 0.9 * skipRate;
        s += 0.25 * (t.artistHour[a] ?? 0);
        if (!known && artistLove > 0.3) why = 'an artist you love';
      }
      final l = languageOf(it);
      if (seedLang != null && l != null) {
        if (l == seedLang) {
          s += 0.1;
        } else {
          s -= 0.8 * (1 - (t.language[l] ?? 0)); // keep the seed's language
        }
      }
      scored.add((it, s, known || artistLove >= 0.25, why));
    }
    scored.sort((x, y) => y.$2.compareTo(x.$2));
    // one upload per song (the best-scored one)
    final unique = <(Item, double, bool, String)>[];
    for (final c in scored) {
      if (unique.any((u) => _sameSong(u.$1, c.$1))) continue;
      unique.add(c);
    }
    final fam = unique.where((c) => c.$3).toList();
    final disc = unique.where((c) => !c.$3).toList();
    final out = <RadioPick>[];
    bool fits(Item it) {
      final a = _artistKey(it);
      if (a == null) return true;
      final w = out.length < 9 ? out : out.sublist(out.length - 9);
      return w.where((p) => _artistKey(p.item) == a).length < 2;
    }

    (Item, double, bool, String)? take(List<(Item, double, bool, String)> l) {
      for (final c in l) {
        if (fits(c.$1)) {
          l.remove(c);
          return c;
        }
      }
      return null;
    }

    var famSoFar = 0;
    while (out.length < count && (fam.isNotEmpty || disc.isNotEmpty)) {
      final wantFam = famSoFar < (familiarShare * (out.length + 1)).round();
      final c = (wantFam ? take(fam) : take(disc)) ?? (wantFam ? take(disc) : take(fam));
      if (c == null) break;
      if (c.$3) famSoFar++;
      out.add(RadioPick(c.$1, c.$2, c.$3, c.$4));
    }
    return out;
  }

  /// Their own songs that suit [seed] (same language or artist, or artists
  /// they play together), best loved first: the familiar part of up next.
  static List<Item> ownSongsFor(Item seed, TasteProfile t, {int n = 30}) {
    final a = _artistKey(seed);
    final lang = languageOf(seed);
    final co = a == null ? const <String, int>{} : (t.coArtists[a] ?? const <String, int>{});
    final l = t.songs.values.where((it) {
      if (it.id == seed.id || t.disliked(it.id) || t.songAffinity(it.id) <= 0.2) return false;
      final ia = _artistKey(it);
      return (lang != null && languageOf(it) == lang) || (a != null && ia == a) || (ia != null && co.containsKey(ia));
    }).toList()
      ..sort((x, y) => t.songAffinity(y.id).compareTo(t.songAffinity(x.id)));
    return l.take(n).toList();
  }

  /// Fetches the candidates for [seed] and ranks them for this listener.
  static Future<List<RadioPick>> forSeed(InnerTube yt, Item seed, TasteProfile t, {int count = 25, Set<String> exclude = const {}}) async {
    Future<List<Item>> safe(Future<List<Item>> f) => f.timeout(const Duration(seconds: 12)).catchError((_) => <Item>[]);
    final mine = personalSeed(seed, t);
    final got = await Future.wait([
      safe(yt.next(seed.id).then((n) => n.queue)),
      safe(yt.related(seed.id).then((shelves) => [for (final s in shelves) ...s.items.where((i) => i.kind == ItemKind.song || i.kind == ItemKind.video)])),
      if (mine != null) safe(yt.next(mine.id).then((n) => n.queue)) else Future.value(<Item>[]),
    ]);
    return rank(seed, [...got, ownSongsFor(seed, t)], t, count: count, exclude: exclude);
  }
}
