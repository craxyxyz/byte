import 'dart:convert';
import 'dart:io';

import '../brand.dart';
import '../core/innertube.dart';
import '../core/innertube_parse.dart' show dig;
import '../core/models.dart';
import '../core/net.dart';
import 'align.dart';
import 'dual.dart';
import 'lrc.dart';
import 'script.dart' show hasDevanagari;

/// Cleans a YouTube title for a lyrics lookup:
/// `Kesariya (From "Brahmastra") [Official Video]` → `Kesariya`.
String cleanTitle(String t) {
  var s = t;
  s = s.replaceAll(
    RegExp(
      r'\s*[\(\[][^\)\]]*(official|video|audio|lyric|lyrics|visualizer|from|remaster|hd|4k|explicit|clean|full song|live|feat\.|ft\.|featuring|with )[^\)\]]*[\)\]]',
      caseSensitive: false,
    ),
    '',
  );
  s = s.replaceAll(RegExp(r'\s*[-|]\s*(official|lyric|audio).*$', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'\s*(feat\.|ft\.|featuring)\s.*$', caseSensitive: false), '');
  return s.trim().isEmpty ? t.trim() : s.trim();
}

String cleanArtist(String a) => a.split(RegExp(r',|&| x | and |feat\.|ft\.', caseSensitive: false)).first.trim();

abstract class LyricsCache {
  String? read(String key);
  void write(String key, String value);
}

class MemoryLyricsCache implements LyricsCache {
  final _m = <String, String>{};
  @override
  String? read(String key) => _m[key];
  @override
  void write(String key, String value) => _m[key] = value;
}

/// Where lyrics can come from, in the default order.
class LyricsProvider {
  final String id;
  final String name;
  final String about;
  const LyricsProvider(this.id, this.name, this.about);

  static const all = [
    LyricsProvider('lrclib', 'Open lyrics', 'Free, community synced lyrics'),
    LyricsProvider('kugou', 'Lyrics library', 'Big public lyrics library, synced, many Indian songs'),
    LyricsProvider('ytm', 'Song page', 'Plain lyrics from the song page'),
    LyricsProvider('ytcaptions', 'Video captions', 'Timed captions of the video, when it has them'),
    LyricsProvider('files', 'Lyrics files', 'A .lrc file next to a song on your phone'),
    LyricsProvider('addons', 'Addons', 'Your addons that serve lyrics'),
    LyricsProvider('musixmatch', 'Lyrics service', 'Needs your own API key'),
  ];
  static LyricsProvider byId(String id) => all.firstWhere((p) => p.id == id, orElse: () => LyricsProvider(id, id, ''));
}

class LyricsService {
  final Net net;
  final InnerTube yt;
  final LyricsCache cache;

  /// The provider order and the ones turned off (Settings → Appearance → Lyrics sources).
  List<String> Function() order = () => [for (final p in LyricsProvider.all) p.id];
  Set<String> Function() off = () => const {'musixmatch'};
  String Function() musixmatchKey = () => '';

  /// Addon lyrics (set by Services when addons are wired).
  Future<(List<LyricLine>?, String?, String)?> Function(Item song)? addonLyrics;

  /// The file path of a song on this phone (for a .lrc next to it).
  String? Function(Item song)? localPath;

  LyricsService(this.net, this.yt, {LyricsCache? cache}) : cache = cache ?? MemoryLyricsCache();

  static const _lrclib = 'https://lrclib.net/api';

  List<String> get activeOrder {
    final o = order().where((id) => !off().contains(id)).toList();
    for (final p in LyricsProvider.all) {
      if (!o.contains(p.id) && !order().contains(p.id) && !off().contains(p.id)) o.add(p.id);
    }
    return o;
  }

  /// Lyrics for [song]: the provider picked for this song if any, else the
  /// first synced result in the order, else the first plain one.
  final Map<String, Future<Lyrics>> _inflight = {};

  /// The lyrics for [song]; two callers asking at once share one lookup.
  Future<Lyrics> forItem(Item song, {int? durationSec}) {
    final running = _inflight[song.id];
    if (running != null) return running;
    final f = _forItem(song, durationSec ?? song.durationSec).whenComplete(() {
      _inflight.remove(song.id);
    });
    _inflight[song.id] = f;
    return f;
  }

  Future<Lyrics> _forItem(Item song, int? durationSec) async {
    // The person's own pick for this song wins.
    final mine = cache.read('lyc:${song.id}');
    if (mine != null) {
      final l = _decode(mine);
      if (l != null) return l;
    }
    // "ly2": 1.4.1 picks by the length of the version that is playing; picks
    // cached by older versions ("ly:") are not reused.
    final key = 'ly2:${song.id}';
    final cached = cache.read(key);
    if (cached != null) {
      final l = _decode(cached);
      if (l != null) return l;
    }
    // Ask every source at once, then pick timings made for THIS version.
    final ids = activeOrder;
    final target = durationSec != null && durationSec != song.durationSec ? Item.fromJson({...song.toJson(), 'd': durationSec}) : song;
    final got = await Future.wait([
      for (final id in ids) fromProvider(id, target).timeout(const Duration(seconds: 15), onTimeout: () => const Lyrics.none()).catchError((_) => const Lyrics.none()),
    ]);
    var result = pickLyrics([for (var i = 0; i < ids.length; i++) (ids[i], got[i])], durationSec);
    if (result.kind == LyricsKind.synced && !song.isLocal && !_timedToThisUpload.contains(result.source)) {
      result = await alignToUpload(song, result);
    }
    if (result.kind != LyricsKind.none) cache.write(key, _encode(result));
    return result;
  }

  static const _timedToThisUpload = {'Song page', 'Video captions', 'Lyrics file'};

  /// Moves [l] to where the words really are in THIS upload, using the
  /// upload's own captions (see align.dart). Unchanged when there are no
  /// captions or they don't agree with the lyrics clearly.
  Future<Lyrics> alignToUpload(Item song, Lyrics l) async {
    try {
      final tracks = await yt.captionTracks(song.id).timeout(const Duration(seconds: 8));
      if (tracks.isEmpty) return l;
      final text = l.lines.take(40).map((x) => x.text).join(' ');
      final want = RegExp(r'[\u0980-\u09FF]').hasMatch(text)
          ? 'bn'
          : RegExp(r'[\u0900-\u097F]').hasMatch(text)
          ? 'hi'
          : null;
      // Prefer captions in the lyrics' language; ones made from the audio are
      // timed to it best.
      int score(({String lang, bool asr, String url}) t) =>
          (want != null && t.lang.startsWith(want) ? 4 : 0) + (t.asr ? 2 : 0) + (want == null && t.lang.startsWith('en') ? 1 : 0);
      final pick = [...tracks]..sort((a, b) => score(b) - score(a));
      for (final t in pick.take(2)) {
        final r = await net.get(Uri.parse(t.url), timeout: const Duration(seconds: 10));
        if (r.status != 200) continue;
        final shift = lyricsShiftFromCaptions(l.lines, json3Words(r.json));
        if (shift == null) continue;
        if (shift == 0) return l;
        return Lyrics.synced(shiftLyricLines(l.lines, shift), l.source, durationMs: song.durationSec == null ? l.durationMs : song.durationSec! * 1000, shiftedMs: shift);
      }
    } catch (_) {}
    return l;
  }

  /// Use [l] for this song from now on (the provider picker).
  void choose(Item song, Lyrics l) => cache.write('lyc:${song.id}', _encode(l));

  /// One provider, never throws.
  Future<Lyrics> fromProvider(String id, Item song) async {
    try {
      switch (id) {
        case 'lrclib':
          return await _fromLrclib(song);
        case 'kugou':
          return await _fromKugou(song);
        case 'ytm':
          if (song.isLocal) return const Lyrics.none();
          try {
            final timed = parseYtmTimedLyrics(await yt.lyricsPage(song.id));
            // timed to this very upload
            if (timed != null) return Lyrics.synced(timed, 'Song page', durationMs: song.durationSec == null ? null : song.durationSec! * 1000);
          } catch (_) {}
          final plain = await yt.plainLyrics(song.id);
          return plain != null && plain.trim().isNotEmpty ? Lyrics.plain(plain, 'Song page') : const Lyrics.none();
        case 'ytcaptions':
          return song.isLocal ? const Lyrics.none() : await _fromCaptions(song);
        case 'files':
          return await _fromFile(song);
        case 'addons':
          final r = await addonLyrics?.call(song);
          if (r == null) return const Lyrics.none();
          if (r.$1 != null && r.$1!.isNotEmpty) return Lyrics.synced(r.$1!, r.$3);
          if (r.$2 != null) return Lyrics.plain(r.$2!, r.$3);
          return const Lyrics.none();
        case 'musixmatch':
          return await _fromMusixmatch(song);
      }
    } catch (_) {}
    return const Lyrics.none();
  }

  Future<Lyrics> _fromCaptions(Item song) async {
    final p = await yt.player(song.id);
    final tracks = (dig(p, ['captions', 'playerCaptionsTracklistRenderer', 'captionTracks']) as List?)?.whereType<Map>().toList() ?? const [];
    if (tracks.isEmpty) return const Lyrics.none();
    // Prefer captions written by people over auto-generated ones.
    tracks.sort((a, b) => (a['kind'] == 'asr' ? 1 : 0) - (b['kind'] == 'asr' ? 1 : 0));
    final base = tracks.first['baseUrl'] as String?;
    if (base == null) return const Lyrics.none();
    final r = await net.get(Uri.parse('$base&fmt=json3'), timeout: const Duration(seconds: 12));
    if (r.status != 200) return const Lyrics.none();
    final lines = parseJson3Captions(r.json);
    return lines.isEmpty ? const Lyrics.none() : Lyrics.synced(lines, 'Video captions', durationMs: song.durationSec == null ? null : song.durationSec! * 1000);
  }

  Future<Lyrics> _fromFile(Item song) async {
    final path = localPath?.call(song);
    if (path == null) return const Lyrics.none();
    final lrc = File(path.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '.lrc'));
    if (!lrc.existsSync()) return const Lyrics.none();
    final text = await lrc.readAsString();
    final lines = parseLrc(text);
    if (lines.isNotEmpty) return Lyrics.synced(lines, 'Lyrics file', durationMs: song.durationSec == null ? null : song.durationSec! * 1000);
    return text.trim().isEmpty ? const Lyrics.none() : Lyrics.plain(text.trim(), 'Lyrics file');
  }

  Future<Lyrics> _fromMusixmatch(Item song) async {
    final key = musixmatchKey().trim();
    if (key.isEmpty) return const Lyrics.none();
    final q = {
      'q_track': cleanTitle(song.title),
      if (song.artists.isNotEmpty) 'q_artist': cleanArtist(song.artists.first.name),
      if (song.durationSec != null) 'f_subtitle_length': '${song.durationSec}',
      'f_subtitle_length_max_deviation': '4',
      'apikey': key,
    };
    final r = await net.get(
      Uri.parse('https://api.musixmatch.com/ws/1.1/matcher.subtitle.get').replace(queryParameters: q),
      timeout: const Duration(seconds: 12),
    );
    if (r.status == 200) {
      final body = dig(r.json, ['message', 'body', 'subtitle', 'subtitle_body']) as String?;
      if (body != null) {
        final lines = parseLrc(body);
        if (lines.isNotEmpty) return Lyrics.synced(lines, 'Lyrics service', durationMs: song.durationSec == null ? null : song.durationSec! * 1000);
      }
    }
    q.remove('f_subtitle_length');
    q.remove('f_subtitle_length_max_deviation');
    final r2 = await net.get(
      Uri.parse('https://api.musixmatch.com/ws/1.1/matcher.lyrics.get').replace(queryParameters: q),
      timeout: const Duration(seconds: 12),
    );
    if (r2.status == 200) {
      final body = dig(r2.json, ['message', 'body', 'lyrics', 'lyrics_body']) as String?;
      if (body != null && body.trim().isNotEmpty) return Lyrics.plain(body.split('\n...').first.trim(), 'Lyrics service');
    }
    return const Lyrics.none();
  }

  /// KuGou's public lyric search: find the song (closest length), then its
  /// lyric candidates, then download the LRC.
  Future<Lyrics> _fromKugou(Item song) async {
    final title = cleanTitle(song.title);
    final artist = song.artists.isNotEmpty ? cleanArtist(song.artists.first.name) : '';
    final dur = song.durationSec;
    const t = Duration(seconds: 10);
    final hits = <Map>[];
    // KuGou's two song searches answer differently from day to day: ask both.
    Future<void> webSearch(String kw) async {
      try {
        final s = await net.get(
          Uri.parse('https://songsearch.kugou.com/song_search_v2').replace(
            queryParameters: {
              'keyword': kw,
              'page': '1',
              'pagesize': '20',
              'userid': '-1',
              'clientver': '',
              'platform': 'WebFilter',
              'tag': 'em',
              'filter': '2',
              'iscorrection': '1',
              'privilege_filter': '0',
            },
          ),
          timeout: t,
        );
        if (s.status != 200) return;
        for (final x in ((dig(s.json, ['data', 'lists']) as List?) ?? const []).whereType<Map>()) {
          hits.add({'songname': '${x['SongName'] ?? ''}'.replaceAll(RegExp(r'</?em>'), ''), 'duration': x['Duration'], 'hash': x['FileHash']});
        }
      } catch (_) {}
    }

    Future<void> mobileSearch(String kw) async {
      try {
        final s = await net.get(
          Uri.parse('http://mobilecdn.kugou.com/api/v3/search/song').replace(
            queryParameters: {'format': 'json', 'keyword': kw, 'page': '1', 'pagesize': '20', 'showtype': '1'},
          ),
          timeout: t,
        );
        if (s.status == 200) hits.addAll(((dig(s.json, ['data', 'info']) as List?) ?? const []).whereType<Map>());
      } catch (_) {}
    }

    final kw = '$title $artist'.trim();
    await Future.wait([webSearch(kw), mobileSearch(kw)]);
    if (pickBestKugou(hits, title, dur) == null && artist.isNotEmpty) await Future.wait([webSearch(title), mobileSearch(title)]);
    final pick = pickBestKugou(hits, title, dur);
    final candidates = <Map>[];
    Future<void> search(Map<String, String> q) async {
      final r = await net.get(
        Uri.parse('https://krcs.kugou.com/search').replace(queryParameters: {'ver': '1', 'man': 'yes', 'client': 'mobi', ...q}),
        timeout: t,
      );
      if (r.status == 200) candidates.addAll(((dig(r.json, ['candidates']) as List?) ?? const []).whereType<Map>());
    }

    if (pick != null) {
      await search({'keyword': '', 'hash': '${pick['hash']}', 'duration': '${((pick['duration'] as num?) ?? 0).toInt() * 1000}'});
    }
    if (candidates.isEmpty) {
      await search({'keyword': '$artist - $title', if (dur != null) 'duration': '${dur * 1000}'});
    }
    // Closest length first: a lyric timed to another cut of the song (radio
    // edit, film version, video with an intro) drifts by the difference.
    if (dur != null) {
      double d(Map c) => c['duration'] is num ? ((c['duration'] as num) / 1000 - dur).abs() : 99;
      candidates.sort((a, b) => d(a).compareTo(d(b)));
    }
    for (final c in candidates.take(3)) {
      if (dur != null && c['duration'] is num && ((c['duration'] as num) / 1000 - dur).abs() > 4) continue;
      final d = await net.get(
        Uri.parse('https://lyrics.kugou.com/download').replace(
          queryParameters: {'ver': '1', 'client': 'pc', 'id': '${c['id']}', 'accesskey': '${c['accesskey']}', 'fmt': 'lrc', 'charset': 'utf8'},
        ),
        timeout: t,
      );
      if (d.status != 200) continue;
      final content = dig(d.json, ['content']) as String?;
      if (content == null || content.isEmpty) continue;
      final lrc = utf8.decode(base64.decode(content), allowMalformed: true);
      final lines = cleanKugouLines(parseLrc(lrc));
      if (lines.length >= 3) return Lyrics.synced(lines, 'Lyrics library', durationMs: (c['duration'] as num?)?.toInt());
    }
    return const Lyrics.none();
  }

  Future<Lyrics> _fromLrclib(Item song) async {
    final title = cleanTitle(song.title);
    final artist = song.artists.isNotEmpty ? cleanArtist(song.artists.first.name) : '';
    final dur = song.durationSec;
    final headers = {'User-Agent': Brand.userAgent};
    Map? best;
    if (artist.isNotEmpty && dur != null) {
      final q = {'track_name': title, 'artist_name': artist, if (song.album != null) 'album_name': song.album!, 'duration': '$dur'};
      final r = await net.get(
        Uri.parse('$_lrclib/get').replace(queryParameters: q),
        headers: headers,
        timeout: const Duration(seconds: 12),
      );
      if (r.status == 200) best = r.json as Map;
    }
    if (best == null || (best['syncedLyrics'] == null && best['plainLyrics'] == null)) {
      final r = await net.get(
        Uri.parse('$_lrclib/search').replace(queryParameters: {'track_name': title, if (artist.isNotEmpty) 'artist_name': artist}),
        headers: headers,
        timeout: const Duration(seconds: 12),
      );
      if (r.status == 200) {
        final list = (r.json as List).whereType<Map>().toList();
        best = pickBestLrclib(list, dur) ?? best;
        if (best == null && artist.isNotEmpty) {
          final r2 = await net.get(
            Uri.parse('$_lrclib/search').replace(queryParameters: {'q': '$title $artist'}),
            headers: headers,
            timeout: const Duration(seconds: 12),
          );
          if (r2.status == 200) best = pickBestLrclib((r2.json as List).whereType<Map>().toList(), dur);
        }
      }
    }
    if (best == null) return const Lyrics.none();
    final synced = best['syncedLyrics'] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      final lines = parseLrc(synced);
      final d = best['duration'] as num?;
      if (lines.isNotEmpty) return Lyrics.synced(lines, 'Open lyrics', durationMs: d == null ? null : (d * 1000).round());
    }
    final plain = best['plainLyrics'] as String?;
    if (plain != null && plain.trim().isNotEmpty) return Lyrics.plain(plain, 'Open lyrics');
    if (best['instrumental'] == true) return Lyrics.plain('♪ Instrumental ♪', 'Open lyrics');
    return const Lyrics.none();
  }

  final Map<String, Future<DualLyrics>> _dual = {};

  /// Dual lyrics (1.4.3): the Roman side of [original]. People often post a
  /// Roman-letter (or Hindi-letter) version of the same song to the open
  /// lyric library; those are matched to [original] word by word and their
  /// spelling is used. Byte's own reading fills whatever none of them has.
  /// The lyrics screen and the mini line asking at once share one lookup.
  Future<DualLyrics> dualFor(Item song, Lyrics original) {
    final key = '${song.id}:${original.text.hashCode}';
    final hit = _dual[key];
    if (hit != null) return hit;
    if (_dual.length > 40) _dual.clear();
    return _dual[key] = () async {
      List<Lyrics> versions;
      try {
        versions = await otherVersions(song);
      } catch (_) {
        versions = const [];
      }
      return buildDual(original, versions: versions);
    }();
  }

  /// The song's lyrics in Roman or Devanagari letters from the open lyric
  /// library and the song page (any timing: they are matched by words).
  Future<List<Lyrics>> otherVersions(Item song) async {
    final title = cleanTitle(song.title);
    final artist = song.artists.isNotEmpty ? cleanArtist(song.artists.first.name) : '';
    final headers = {'User-Agent': Brand.userAgent};
    final queries = [
      {'track_name': title, if (artist.isNotEmpty) 'artist_name': artist},
      if (artist.isNotEmpty) {'q': '$title $artist'},
    ];
    final got = await Future.wait([
      for (final q in queries)
        net
            .get(Uri.parse('$_lrclib/search').replace(queryParameters: q), headers: headers, timeout: const Duration(seconds: 12))
            .then((r) => r.status == 200 && r.json is List ? (r.json as List).whereType<Map>().toList() : <Map>[])
            .catchError((_) => <Map>[]),
      fromProvider('ytm', song).timeout(const Duration(seconds: 10), onTimeout: () => const Lyrics.none()).catchError((_) => const Lyrics.none()),
    ]);
    final seen = <Object?>{};
    final out = <(double, Lyrics)>[];
    final dur = song.durationSec;
    for (final list in got.whereType<List<Map>>()) {
      for (final h in list) {
        if (!seen.add(h['id'])) continue;
        final synced = h['syncedLyrics'] as String?;
        final plain = h['plainLyrics'] as String?;
        final text = (synced != null && synced.trim().isNotEmpty) ? synced : plain;
        if (text == null || text.trim().isEmpty) continue;
        final l = synced != null && synced.trim().isNotEmpty ? Lyrics.synced(parseLrc(synced), 'Open lyrics') : Lyrics.plain(plain!, 'Open lyrics');
        if (!isRomanOrHindiVersion(l)) continue;
        final d = (h['duration'] as num?)?.toDouble();
        out.add((dur == null || d == null ? 30 : (d - dur).abs(), l));
      }
    }
    final page = got.whereType<Lyrics>().firstOrNull;
    if (page != null && page.kind != LyricsKind.none && isRomanOrHindiVersion(page)) out.add((0, page));
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final e in out.take(5)) e.$2];
  }

  String _encode(Lyrics l) => jsonEncode({
    'k': l.kind.name,
    's': l.source,
    'd': ?l.durationMs,
    'sh': ?l.shiftedMs,
    'p': l.plain,
    'l': [
      for (final x in l.lines)
        {
          't': x.startMs,
          'x': x.text,
          if (x.words != null)
            'w': [
              for (final w in x.words!) [w.text, w.startMs, w.endMs],
            ],
        },
    ],
  });

  Lyrics? _decode(String s) {
    try {
      final j = jsonDecode(s) as Map;
      final kind = LyricsKind.values.byName(j['k'] as String);
      if (kind == LyricsKind.plain) return Lyrics.plain(j['p'] as String, j['s'] as String);
      if (kind == LyricsKind.synced) {
        return Lyrics.synced([
          for (final x in (j['l'] as List))
            LyricLine(
              x['t'] as int,
              x['x'] as String,
              x['w'] == null ? null : [for (final w in x['w'] as List) LyricWord(w[0] as String, w[1] as int, w[2] as int)],
            ),
        ], j['s'] as String, durationMs: j['d'] as int?, shiftedMs: j['sh'] as int?);
      }
    } catch (_) {}
    return null;
  }
}

/// Picks the lyrics to show from every source's answer ([results] in the
/// person's source order), for a recording [durationSec] long:
/// 1. synced lyrics timed for this length (within 2 s), in source order;
/// 2. synced lyrics whose source didn't say the length;
/// 3. the closest synced lyrics within 4 s;
/// 4. otherwise the words without timings (timings made for another version
///    of the song drift by the difference and never line up), then plain.
Lyrics pickLyrics(List<(String, Lyrics)> results, int? durationSec) {
  double? delta(Lyrics l) => durationSec == null || l.durationMs == null ? null : (l.durationMs! / 1000 - durationSec).abs();
  final synced = [for (final r in results) if (r.$2.kind == LyricsKind.synced) r.$2];
  for (final l in synced) {
    final d = delta(l);
    if (d != null && d <= 2) return l;
  }
  for (final l in synced) {
    if (delta(l) == null) return l;
  }
  final near = synced.where((l) => delta(l)! <= 4).toList()..sort((a, b) => delta(a)!.compareTo(delta(b)!));
  if (near.isNotEmpty) return near.first;
  for (final r in results) {
    if (r.$2.kind == LyricsKind.plain) return r.$2;
  }
  if (synced.isNotEmpty) return Lyrics.plain(synced.first.text, synced.first.source);
  return const Lyrics.none();
}

/// Best LRCLIB search hit: synced lyrics with the closest duration (±4 s),
/// then any synced, then plain.
Map? pickBestLrclib(List<Map> hits, int? durationSec) {
  if (hits.isEmpty) return null;
  double diff(Map h) => durationSec == null ? 0 : ((h['duration'] as num? ?? 0) - durationSec).abs().toDouble();
  final synced = hits.where((h) => (h['syncedLyrics'] as String?)?.trim().isNotEmpty == true).toList()
    ..sort((a, b) {
      final w = (b['hasWordSync'] == true ? 1 : 0) - (a['hasWordSync'] == true ? 1 : 0);
      if (diff(a) <= 2 && diff(b) <= 2 && w != 0) return w;
      return diff(a).compareTo(diff(b));
    });
  if (synced.isNotEmpty && (durationSec == null || diff(synced.first) <= 4)) return synced.first;
  final plain = hits.where((h) => (h['plainLyrics'] as String?)?.trim().isNotEmpty == true).toList()..sort((a, b) => diff(a).compareTo(diff(b)));
  if (plain.isNotEmpty && (durationSec == null || diff(plain.first) <= 8)) return plain.first;
  return null;
}

/// YouTube timed captions (json3) → synced lines; music-note-only lines dropped.
List<LyricLine> parseJson3Captions(dynamic j) {
  final out = <LyricLine>[];
  final events = (j is Map ? j['events'] as List? : null) ?? const [];
  for (final e in events.whereType<Map>()) {
    final segs = (e['segs'] as List?)?.whereType<Map>() ?? const [];
    final text = segs.map((s) => s['utf8'] ?? '').join().replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final t = (e['tStartMs'] as num?)?.toInt();
    if (t == null || text.isEmpty) continue;
    if (RegExp(r'^[\[\(]?[♪♫\s]*(music|संगीत)?[♪♫\s]*[\]\)]?$', caseSensitive: false).hasMatch(text)) continue;
    out.add(LyricLine(t, text));
  }
  out.sort((a, b) => a.startMs.compareTo(b.startMs));
  return out;
}

/// The KuGou search hit for [title]: the closest length within 10 s whose
/// name shares a word with the title (null when nothing is close).
Map? pickBestKugou(List<Map> hits, String title, int? durationSec) {
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ');
  final want = norm(title).split(RegExp(r'\s+')).where((w) => w.length > 1).toSet();
  bool named(Map h) {
    final n = norm('${h['songname'] ?? ''} ${h['filename'] ?? ''}');
    return want.isEmpty || want.any(n.contains);
  }

  double diff(Map h) => durationSec == null ? 0 : (((h['duration'] as num?) ?? 0) - durationSec).abs().toDouble();
  final ok = hits.where((h) => h['hash'] != null && named(h) && diff(h) <= 10).toList()..sort((a, b) => diff(a).compareTo(diff(b)));
  return ok.isEmpty ? null : ok.first;
}

/// KuGou LRCs carry credit lines (作词/作曲/…, lyricist / composer) at 0 s;
/// drop those, keep the singing.
List<LyricLine> cleanKugouLines(List<LyricLine> lines) {
  final credit = RegExp(r'^\s*(作词|作曲|编曲|制作人|词|曲|演唱|混音|母带|lyricist|composer|lyrics by|music by|arranged by|producer)\s*[:：]', caseSensitive: false);
  return [for (final l in lines) if (!credit.hasMatch(l.text) && !l.text.contains('酷狗') && !l.text.toLowerCase().contains('kugou')) l];
}

/// A version that can give dual lyrics their Roman side: Roman letters, or Devanagari.
bool isRomanOrHindiVersion(Lyrics l) {
  final t = versionLines(l).take(40).join(' ');
  if (t.trim().isEmpty) return false;
  return !needsDualText(t) || hasDevanagari(t);
}
