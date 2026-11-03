import '../core/net.dart';

/// "Work out genres via Last.fm": the person's top artists' Last.fm tags,
/// weighted by how much they listen to each artist. Needs only their own
/// Last.fm API key (the one they gave for scrobbling); no login.
class GenreGuesser {
  final Net net;
  GenreGuesser(this.net);
  static const api = 'https://ws.audioscrobbler.com/2.0/';
  final Map<String, List<(String, int)>> _cache = {};

  /// Tags that say nothing about the music.
  static const _noise = {'seen live', 'favorites', 'favourite', 'favorite', 'my favorite', 'love', 'awesome', 'beautiful', 'male vocalists', 'female vocalists', 'singer-songwriter'};

  Future<List<(String, int)>> artistTags(String artist, String key) async {
    final k = artist.toLowerCase();
    final c = _cache[k];
    if (c != null) return c;
    final r = await net.get(
      Uri.parse(api).replace(queryParameters: {'method': 'artist.gettoptags', 'artist': artist, 'api_key': key, 'format': 'json', 'autocorrect': '1'}),
      timeout: const Duration(seconds: 10),
    );
    if (r.status != 200) return const [];
    final tags = ((((r.json as Map)['toptags'] as Map?)?['tag'] as List?) ?? const []).whereType<Map>();
    final out = <(String, int)>[
      for (final t in tags.take(8))
        if (!_noise.contains('${t['name']}'.toLowerCase()) && ((t['count'] as num?) ?? 0) >= 10) ('${t['name']}', ((t['count'] as num?) ?? 0).toInt()),
    ];
    _cache[k] = out;
    return out;
  }

  /// Genre → share (0..1) from [artists] (name, minutes listened), best first.
  Future<List<(String, double)>> topGenres(List<(String, int)> artists, String key, {int n = 10}) async {
    if (key.isEmpty) throw StateError('no key');
    final score = <String, double>{};
    final names = <String, String>{};
    final results = await Future.wait([for (final a in artists.take(15)) artistTags(a.$1, key).catchError((_) => <(String, int)>[])]);
    for (var i = 0; i < results.length; i++) {
      final w = artists[i].$2.toDouble().clamp(1, double.infinity);
      for (final (tag, count) in results[i]) {
        final k = tag.toLowerCase().trim();
        if (k.isEmpty) continue; // 1.4.5 QA: an empty tag crashed here
        final t = tag.trim();
        names[k] ??= t[0].toUpperCase() + t.substring(1);
        score[k] = (score[k] ?? 0) + w * count / 100;
      }
    }
    final total = score.values.fold<double>(0, (a, b) => a + b);
    if (total == 0) return const [];
    final keys = score.keys.toList()..sort((a, b) => score[b]!.compareTo(score[a]!));
    return [for (final k in keys.take(n)) (names[k]!, score[k]! / total)];
  }
}
