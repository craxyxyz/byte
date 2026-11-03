import 'dart:async';
import 'dart:convert';

import '../core/innertube.dart';
import '../core/models.dart';
import '../core/net.dart';
import 'link_import.dart';

/// Where a playlist comes from.
enum MusicService { youtube, spotify, apple, jiosaavn, gaana, amazon, soundcloud, deezer, wynk, web, text, file }

String serviceName(MusicService s) => switch (s) {
  // Shown in the app, so no other app is named: every streaming source is
  // "a music app".
  MusicService.youtube || MusicService.spotify || MusicService.apple || MusicService.jiosaavn || MusicService.gaana ||
  MusicService.amazon || MusicService.soundcloud || MusicService.deezer || MusicService.wynk => 'a music app',
  MusicService.web => 'the web page',
  MusicService.text => 'your list',
  MusicService.file => 'the file',
};

/// One song as another app lists it.
class ExtTrack {
  final String title;
  final String artists;
  final String? album;
  final int? durationMs;
  const ExtTrack(this.title, this.artists, {this.album, this.durationMs});
  String get query => [title, artists].where((s) => s.trim().isNotEmpty).join(' ');
  /// Title without "(From …)", "- Remastered", "feat." tags + the first artist.
  String get shortQuery {
    var t = title
        .replaceAll(RegExp(r'\((?:from|feat|ft|with)[^)]*\)|\[[^\]]*\]', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s[-–]\s(?:\d{4}\s)?(?:remaster(?:ed)?|from|single|radio edit|original).*$', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (t.isEmpty) t = title;
    final a = artists.split(RegExp(r',|&| and | x |;', caseSensitive: false)).first.trim();
    return [t, a].where((s) => s.isNotEmpty).join(' ');
  }
  @override
  String toString() => artists.isEmpty ? title : '$title — $artists';
}

class ExtList {
  final String name;
  final String? cover;
  final List<ExtTrack> tracks;
  final MusicService service;
  final String sourceKey; // saved on the Byte playlist, e.g. "spotify:<id>"
  /// How many songs the service says the list has (when it says).
  final int? total;
  /// Songs already on YouTube Music (YouTube links): no matching needed.
  final List<Item>? ready;
  const ExtList(this.name, this.cover, this.tracks, this.service, this.sourceKey, {this.total, this.ready});
  bool get partial => total != null && total! > tracks.length;
}

class ImportProblem implements Exception {
  final String message;
  /// The music app whose own login would open this playlist (shown as a button).
  final String? loginService;
  final String? link;
  const ImportProblem(this.message, {this.loginService, this.link});
  @override
  String toString() => message;
}

MusicService? detectService(String input) {
  final u = Uri.tryParse(input.trim());
  if (u == null || !u.hasScheme || u.host.isEmpty) return null;
  final h = u.host.toLowerCase();
  bool on(String d) => h == d || h.endsWith('.$d');
  if (on('youtube.com') || on('youtu.be') || h == 'youtube.app.goo.gl') return MusicService.youtube;
  if (on('spotify.com') || h == 'spotify.link' || h == 'spoti.fi') return MusicService.spotify;
  if (h == 'music.apple.com' || h == 'itunes.apple.com' || h == 'embed.music.apple.com' || h == 'apple.co') return MusicService.apple;
  if (on('jiosaavn.com') || on('saavn.com') || h == 'jiosaavn.page.link') return MusicService.jiosaavn;
  if (on('gaana.com') || h == 'gaana.page.link') return MusicService.gaana;
  if (h.startsWith('music.amazon.') || (on('amazon.com') || on('amazon.in')) && u.path.contains('music') || const {'amzn.to', 'amzn.eu', 'amzn.in', 'a.co'}.contains(h)) {
    return MusicService.amazon;
  }
  if (on('soundcloud.com') || h == 'on.soundcloud.com') return MusicService.soundcloud;
  if (on('deezer.com') || h == 'deezer.page.link' || h == 'dzr.page.link') return MusicService.deezer;
  if (on('wynk.in')) return MusicService.wynk;
  if (u.scheme == 'http' || u.scheme == 'https') return MusicService.web;
  return null;
}

/// Share links that only point somewhere else (app "Share" buttons hand these out).
bool isShortLink(Uri u) {
  final h = u.host.toLowerCase();
  if (const {
    'spotify.link', 'spoti.fi', 'link.deezer.com', 'deezer.page.link', 'dzr.page.link', 'on.soundcloud.com', 'amzn.to', 'amzn.eu',
    'amzn.in', 'a.co', 'apple.co', 'gaana.page.link', 'jiosaavn.page.link', 'youtube.app.goo.gl',
  }.contains(h)) {
    return true;
  }
  // deezer.com/... without a playlist/album/track id, e.g. www.deezer.com/s/<code>
  if ((h == 'deezer.com' || h.endsWith('.deezer.com')) && !RegExp(r'/(playlist|album|track)/\d+').hasMatch(u.path)) return true;
  return false;
}

/// Pulls the first http(s) link out of shared text ("Check this out! https://…").
String? firstLink(String text) => RegExp(r'https?://[^\s<>"]+').firstMatch(text)?.group(0);

final _entities = {'&amp;': '&', '&quot;': '"', '&#39;': "'", '&#039;': "'", '&apos;': "'", '&lt;': '<', '&gt;': '>', '&nbsp;': ' '};
String unescapeHtml(String s) {
  var o = s.replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
    final n = int.tryParse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16);
    return n == null ? m.group(0)! : String.fromCharCode(n);
  });
  _entities.forEach((k, v) => o = o.replaceAll(k, v));
  return o;
}

int? isoDurationMs(String? s) {
  if (s == null) return null;
  final m = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?').firstMatch(s);
  if (m == null) return null;
  final h = int.tryParse(m.group(1) ?? '') ?? 0, mi = int.tryParse(m.group(2) ?? '') ?? 0, se = int.tryParse(m.group(3) ?? '') ?? 0;
  final t = (h * 3600 + mi * 60 + se) * 1000;
  return t == 0 ? null : t;
}

int? clockMs(String? s) {
  if (s == null) return null;
  final p = s.trim().split(':').map(int.tryParse).toList();
  if (p.isEmpty || p.any((x) => x == null)) return null;
  var t = 0;
  for (final x in p) {
    t = t * 60 + x!;
  }
  return t * 1000;
}

// ── Readers that work on page text (unit-tested with saved pages) ─────────

/// schema.org MusicPlaylist / MusicAlbum in a page's JSON-LD.
ExtList? parseJsonLdList(String html, MusicService service, String key) {
  for (final m in RegExp(r'<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>', dotAll: true).allMatches(html)) {
    dynamic j;
    try {
      j = jsonDecode(m.group(1)!.trim());
    } catch (_) {
      continue;
    }
    for (final o in j is List ? j : [j]) {
      if (o is! Map) continue;
      final type = '${o['@type']}';
      if (type != 'MusicPlaylist' && type != 'MusicAlbum') continue;
      var raw = o['track'];
      if (raw is Map && raw['itemListElement'] is List) raw = (raw['itemListElement'] as List).map((e) => e is Map ? (e['item'] ?? e) : e).toList();
      if (raw is! List) continue;
      final albumArtist = _ldName(o['byArtist']);
      final tracks = <ExtTrack>[
        for (final t in raw.whereType<Map>())
          if ('${t['name'] ?? ''}'.trim().isNotEmpty)
            ExtTrack(
              unescapeHtml('${t['name']}'),
              unescapeHtml(_ldName(t['byArtist']) ?? albumArtist ?? ''),
              album: t['inAlbum'] is Map ? unescapeHtml('${t['inAlbum']['name'] ?? ''}') : (type == 'MusicAlbum' ? '${o['name']}' : null),
              durationMs: isoDurationMs(t['duration'] as String?),
            ),
      ];
      if (tracks.isEmpty) continue;
      final img = o['image'];
      return ExtList(
        unescapeHtml('${o['name'] ?? 'Imported playlist'}'),
        img is String ? img : (img is List && img.isNotEmpty ? '${img.first}' : null),
        tracks,
        service,
        key,
        total: (o['numTracks'] as num?)?.toInt(),
      );
    }
  }
  return null;
}

String? _ldName(dynamic a) {
  if (a == null) return null;
  if (a is Map) return a['name'] as String?;
  if (a is List) return a.map(_ldName).whereType<String>().join(', ');
  return '$a';
}

/// Apple Music: the web page's own data (title, artist, album, duration).
ExtList? parseAppleMusic(String html, String key) {
  final m = RegExp(r'<script[^>]*id="serialized-server-data"[^>]*>(.*?)</script>', dotAll: true).firstMatch(html);
  final ld = parseJsonLdList(html, MusicService.apple, key);
  if (m == null) return ld;
  dynamic data;
  try {
    data = jsonDecode(m.group(1)!);
  } catch (_) {
    return ld;
  }
  final tracks = <ExtTrack>[];
  final seen = <String>{};
  void walk(dynamic o) {
    if (o is Map) {
      if (o['title'] is String && o['artistName'] is String && o['contentDescriptor'] is Map && (o['contentDescriptor'] as Map)['kind'] == 'song') {
        final id = '${o['id']}';
        if (seen.add(id)) {
          final links = o['tertiaryLinks'];
          tracks.add(
            ExtTrack(
              o['title'] as String,
              o['artistName'] as String,
              album: links is List && links.isNotEmpty && links.first is Map ? links.first['title'] as String? : null,
              durationMs: (o['duration'] as num?)?.toInt(),
            ),
          );
        }
      }
      o.values.forEach(walk);
    } else if (o is List) {
      o.forEach(walk);
    }
  }

  walk(data);
  if (tracks.isEmpty) return ld;
  final title = RegExp(r'<meta (?:property|name)="(?:og:title|apple:title)" content="([^"]*)"').firstMatch(html)?.group(1);
  final cover = RegExp(r'<meta property="og:image" content="([^"]*)"').firstMatch(html)?.group(1);
  var name = ld?.name ?? unescapeHtml(title ?? 'Imported playlist');
  name = name.replaceFirst(RegExp(r' (?:on|-) Apple Music$'), '');
  return ExtList(name, ld?.cover ?? cover, tracks, MusicService.apple, key, total: ld?.total);
}

/// Amazon Music: the page served to search engines lists every row.
ExtList? parseAmazonMusic(String html, String key) {
  final head = RegExp(r'<music-detail-header[^>]*headline="([^"]*)"').firstMatch(html);
  final img = RegExp(r'<music-detail-header[^>]*image-src="([^"]*)"').firstMatch(html);
  final rows = RegExp(r'<music-(?:image|text)-row[^>]*?primary-text="([^"]*)"').allMatches(html).toList();
  if (rows.isEmpty) return null;
  final tracks = <ExtTrack>[];
  for (var i = 0; i < rows.length; i++) {
    final end = i + 1 < rows.length ? rows[i + 1].start : html.length;
    final seg = html.substring(rows[i].start, end);
    String? attr(String n) => RegExp('$n="([^"]*)"').firstMatch(seg)?.group(1);
    tracks.add(
      ExtTrack(unescapeHtml(rows[i].group(1)!), unescapeHtml(attr('secondary-text-1') ?? ''), album: attr('secondary-text-2') == null ? null : unescapeHtml(attr('secondary-text-2')!), durationMs: clockMs(attr('duration'))),
    );
  }
  final total = int.tryParse(RegExp(r'tertiary-text="(\d+) SONGS').firstMatch(html)?.group(1) ?? '');
  return ExtList(unescapeHtml(head?.group(1) ?? 'Imported playlist'), img?.group(1), tracks, MusicService.amazon, key, total: total);
}

/// SoundCloud: the page's hydration data (full tracks + ids for the rest).
({String name, String? cover, List<ExtTrack> tracks, List<int> missing, int total})? parseSoundCloud(String html) {
  final m = RegExp(r'window\.__sc_hydration\s*=\s*(\[.*?\]);\s*</script>', dotAll: true).firstMatch(html);
  if (m == null) return null;
  final hyd = jsonDecode(m.group(1)!) as List;
  for (final h in hyd.whereType<Map>()) {
    final d = h['data'];
    if (d is! Map) continue;
    if (h['hydratable'] == 'playlist') {
      final tracks = <ExtTrack>[];
      final missing = <int>[];
      for (final t in (d['tracks'] as List? ?? const []).whereType<Map>()) {
        if (t['title'] is String) {
          tracks.add(soundCloudTrack(t));
        } else if (t['id'] is num) {
          missing.add((t['id'] as num).toInt());
        }
      }
      return (name: '${d['title'] ?? 'Imported playlist'}', cover: d['artwork_url'] as String?, tracks: tracks, missing: missing, total: (d['track_count'] as num?)?.toInt() ?? tracks.length + missing.length);
    }
    if (h['hydratable'] == 'sound') {
      return (name: '${d['title']}', cover: d['artwork_url'] as String?, tracks: [soundCloudTrack(d)], missing: <int>[], total: 1);
    }
  }
  return null;
}

ExtTrack soundCloudTrack(Map t) {
  final pm = t['publisher_metadata'];
  final artist = pm is Map && (pm['artist'] as String?)?.isNotEmpty == true ? pm['artist'] as String : ((t['user'] as Map?)?['username'] as String? ?? '');
  return ExtTrack('${t['title']}', artist, album: pm is Map ? pm['album_title'] as String? : null, durationMs: (t['duration'] as num?)?.toInt());
}

/// A pasted song list: one song per line. "Song - Artist", "Artist – Song",
/// "Song by Artist", numbered lists and Markdown bullets all work.
List<ExtTrack> parseTextList(String text) {
  final out = <ExtTrack>[];
  for (var line in const LineSplitter().convert(text)) {
    line = line.trim().replaceFirst(RegExp(r'^(\d+[.)]\s*|[-*•]\s+)'), '').trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final by = RegExp(r'^(.+?)\s+by\s+(.+)$', caseSensitive: false).firstMatch(line);
    final dash = RegExp(r'^(.+?)\s+[-–—|]\s+(.+)$').firstMatch(line);
    if (by != null) {
      out.add(ExtTrack(by.group(1)!.trim(), by.group(2)!.trim()));
    } else if (dash != null) {
      // Which side is the artist is unknown; the matcher tries both.
      out.add(ExtTrack(dash.group(1)!.trim(), dash.group(2)!.trim()));
    } else {
      out.add(ExtTrack(line, ''));
    }
  }
  return out;
}

/// CSV exported by Exportify, TuneMyMusic, Soundiiz, Spotlistr and the like
/// (a header row naming the title and artist columns). Plain TXT falls back to
/// [parseTextList].
List<ExtTrack> parseCsvList(String text) {
  final rows = _csvRows(text);
  if (rows.length < 2) return parseTextList(text);
  final head = rows.first.map((h) => h.toLowerCase().trim()).toList();
  int col(List<String> names, {List<String> not = const []}) {
    for (final n in names) {
      final i = head.indexWhere((h) => h.contains(n) && !not.any(h.contains));
      if (i >= 0) return i;
    }
    return -1;
  }

  final ti = col(['track name', 'track title', 'song name', 'song title', 'title', 'track', 'name', 'song'], not: ['album', 'artist', 'playlist', 'uri', 'id']);
  final ai = col(['artist name', 'artist', 'artists', 'creator', 'performer']);
  final ali = col(['album name', 'album title', 'album'], not: ['artist']);
  final di = col(['duration (ms)', 'duration_ms', 'duration', 'length', 'time']);
  if (ti < 0) return parseTextList(text);
  final out = <ExtTrack>[];
  for (final r in rows.skip(1)) {
    String at(int i) => i >= 0 && i < r.length ? r[i].trim() : '';
    final t = at(ti);
    if (t.isEmpty) continue;
    final d = at(di);
    int? ms;
    if (d.isNotEmpty) {
      final n = int.tryParse(d);
      ms = n != null ? (n > 10000 ? n : n * 1000) : clockMs(d);
    }
    out.add(ExtTrack(t, at(ai).replaceAll(RegExp(r'\s*[;|]\s*'), ', '), album: at(ali).isEmpty ? null : at(ali), durationMs: ms));
  }
  return out;
}

List<List<String>> _csvRows(String text) {
  final sep = text.split('\n').first.split('\t').length > text.split('\n').first.split(',').length ? '\t' : (text.split('\n').first.contains(';') && !text.split('\n').first.contains(',') ? ';' : ',');
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == sep) {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((x) => x.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  row.add(cell.toString());
  if (row.any((x) => x.isNotEmpty)) rows.add(row);
  return rows;
}

// ── Reading links (network) ───────────────────────────────────────────────

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const _bot = 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)';

class PlaylistReader {
  final Net net;
  final InnerTube yt;
  PlaylistReader(this.net, this.yt);

  Future<NetResponse> _get(String url, {String ua = _ua, Map<String, String> headers = const {}}) =>
      net.get(Uri.parse(url), headers: {'User-Agent': ua, 'Accept-Language': 'en-US,en;q=0.9', ...headers}, timeout: const Duration(seconds: 25));

  /// Follows a share link's redirects (and, for pages that redirect with
  /// script, the canonical link in the page) to the real playlist address.
  Future<String> resolveShortLink(String link) async {
    var u = Uri.parse(link);
    for (var hop = 0; hop < 8; hop++) {
      NetResponse r;
      try {
        r = await net.send(NetRequest('GET', u, headers: {'User-Agent': _ua, 'Accept-Language': 'en-US,en;q=0.9'}, followRedirects: false), timeout: const Duration(seconds: 20));
      } catch (_) {
        break;
      }
      final loc = r.headers['location'];
      if (r.status >= 300 && r.status < 400 && loc != null && loc.isNotEmpty) {
        var next = u.resolve(loc);
        // link.deezer.com/?dest=<real url>
        final dest = next.queryParameters['dest'];
        if (dest != null && dest.startsWith('http')) next = Uri.parse(dest);
        u = next;
        if (!isShortLink(u)) break;
        continue;
      }
      if (r.ok && isShortLink(u)) {
        // A page that forwards with script / meta refresh: take the first real link in it.
        final m = RegExp(
          r'''https?:(?:\\?/){2}(?:open\.spotify\.com|www\.deezer\.com|deezer\.com|soundcloud\.com|music\.amazon\.[a-z.]+|music\.apple\.com|gaana\.com|www\.jiosaavn\.com|music\.youtube\.com|www\.youtube\.com)[^"'<>\s]*''',
        ).firstMatch(r.text);
        if (m != null) u = Uri.parse(unescapeHtml(m.group(0)!.replaceAll(r'\/', '/')));
      }
      break;
    }
    return u.toString();
  }

  /// Reads any supported link. [onStatus] gets short progress lines.
  Future<ExtList> read(String input, {void Function(String)? onStatus}) async {
    var link = (firstLink(input) ?? input.trim()).replaceAll(RegExp(r'[.,;:!?)\]]+$'), '');
    final first = Uri.tryParse(link);
    if (first != null && first.hasScheme && isShortLink(first)) {
      onStatus?.call('Opening the share link…');
      link = await resolveShortLink(link);
    }
    final s = detectService(link);
    if (s == null) throw const ImportProblem('Paste a playlist or album link (it starts with https://)');
    onStatus?.call('Reading the playlist…');
    return switch (s) {
      MusicService.youtube => _youtube(link),
      MusicService.spotify => _spotify(link, onStatus),
      MusicService.apple => _apple(link),
      MusicService.jiosaavn => _saavn(link, onStatus),
      MusicService.gaana => _gaana(link),
      MusicService.amazon => _amazon(link),
      MusicService.soundcloud => _soundcloud(link),
      MusicService.deezer => _deezer(link, onStatus),
      MusicService.wynk => _wynk(link),
      _ => _web(link),
    };
  }

  Future<ExtList> _youtube(String link) async {
    final p = parseLink(link);
    switch (p.kind) {
      case LinkKind.ytPlaylist:
      case LinkKind.ytAlbum:
        final page = p.kind == LinkKind.ytAlbum && p.id.startsWith('MPRE') ? await yt.album(p.id) : await yt.playlist(p.id);
        final items = page.tracks.where((t) => t.isPlayable).toList();
        if (items.isEmpty) throw const ImportProblem('That playlist is empty or private');
        return ExtList(page.header.title.isEmpty ? 'Imported playlist' : page.header.title, page.header.thumb, const [], MusicService.youtube, 'youtube:${p.id}', ready: items);
      case LinkKind.ytVideo:
        final n = await yt.next(p.id);
        final first = n.queue.where((i) => i.id == p.id).firstOrNull ?? n.queue.firstOrNull;
        if (first == null) throw const ImportProblem('Couldn\'t find that song');
        return ExtList(first.title, first.thumb, const [], MusicService.youtube, 'youtube:${p.id}', ready: [first]);
      case LinkKind.ytArtist:
        final page = await yt.artist(p.id);
        final songs = page.shelves.expand((s) => s.items).where((i) => i.kind == ItemKind.song).toList();
        return ExtList(page.header.title, page.header.thumb, const [], MusicService.youtube, 'youtube:${p.id}', ready: songs);
      default:
        throw const ImportProblem('That link isn\'t a playlist, album or song');
    }
  }

  // Spotify: the public embed lists the first 100 songs and carries a guest
  // token; the rest of a long playlist comes from the same public endpoints
  // Spotify's web player reads (song ids, then each song's name).
  Future<ExtList> _spotify(String link, void Function(String)? onStatus) async {
    var u = link;
    if (!u.contains('open.spotify.com')) {
      final r = await _get(u);
      final m = RegExp(r'open\.spotify\.com/(?:intl-[a-z]+/)?(playlist|album|track)/([A-Za-z0-9]{22})').firstMatch(r.text);
      if (m == null) throw const ImportProblem('That link didn\'t open a playlist');
      u = 'https://open.spotify.com/${m.group(1)}/${m.group(2)}';
    }
    final m = RegExp(r'/(playlist|album|track)/([A-Za-z0-9]{22})').firstMatch(u);
    if (m == null) throw const ImportProblem('Paste a playlist, album or song link');
    final type = m.group(1)!, id = m.group(2)!;
    final r = await _get('https://open.spotify.com/embed/$type/$id');
    if (!r.ok) throw ImportProblem('The music app didn\'t open that $type (${r.status}). Is it public?');
    final list = parseSpotifyEmbed(r.text);
    if (list == null || list.tracks.isEmpty) throw const ImportProblem('That playlist is empty or private');
    final tracks = [for (final t in list.tracks) ExtTrack(t.title, t.artists, durationMs: t.durationMs)];
    int? total;
    if (type == 'playlist' && list.listed >= 100) {
      final token = RegExp(r'"accessToken"\s*:\s*"([^"]+)"').firstMatch(r.text)?.group(1);
      if (token != null) {
        try {
          final more = await _spotifyRest(id, token, from: list.listed, onStatus: onStatus, onTotal: (n) => total = n);
          tracks.addAll(more);
        } catch (_) {
          // keep the first 100; the review screen says the list was cut short
        }
      }
    }
    return ExtList(list.name, list.cover, tracks, MusicService.spotify, 'spotify:$id', total: total);
  }

  Future<List<ExtTrack>> _spotifyRest(String id, String token, {required int from, void Function(String)? onStatus, void Function(int)? onTotal}) async {
    final h = {'Authorization': 'Bearer $token', 'Accept': 'application/json', 'app-platform': 'WebPlayer'};
    final uris = <String>[];
    var pos = from;
    for (var guard = 0; guard < 120; guard++) {
      final r = await _get('https://spclient.wg.spotify.com/playlist/v2/playlist/$id?from=$pos&length=100', headers: h);
      if (!r.ok) break;
      final j = r.json as Map;
      final total = (j['length'] as num?)?.toInt();
      if (total != null) onTotal?.call(total);
      final items = ((j['contents'] as Map?)?['items'] as List?) ?? const [];
      if (items.isEmpty) break;
      for (final it in items.whereType<Map>()) {
        final uri = '${it['uri']}';
        if (uri.startsWith('spotify:track:')) uris.add(uri.substring(14));
      }
      pos += items.length;
      if (total != null && pos >= total) break;
    }
    final out = List<ExtTrack?>.filled(uris.length, null);
    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < uris.length) {
        final i = next++;
        try {
          Future<NetResponse> meta(String id) async {
            var r = await _get('https://spclient.wg.spotify.com/metadata/4/track/${spotifyGidHex(id)}?market=from_token', headers: h);
            // Busy (429) or a hiccup (5xx): wait a little and try again.
            for (var attempt = 1; attempt <= 4 && (r.status == 429 || r.status >= 500); attempt++) {
              await Future<void>.delayed(Duration(milliseconds: 600 * attempt * attempt));
              r = await _get('https://spclient.wg.spotify.com/metadata/4/track/${spotifyGidHex(id)}?market=from_token', headers: h);
            }
            return r;
          }

          var r = await meta(uris[i]);
          var j = r.ok ? r.json as Map : null;
          // Songs Spotify "relinked" to another release hide their own name.
          final canon = j?['canonical_uri'] as String?;
          if (j != null && '${j['name'] ?? ''}'.isEmpty && canon != null && canon.startsWith('spotify:track:') && canon.substring(14) != uris[i]) {
            r = await meta(canon.substring(14));
            j = r.ok ? r.json as Map : null;
          }
          if (j != null) {
            final artists = ((j['artist'] as List?) ?? const []).whereType<Map>().map((a) => a['name']).join(', ');
            final name = j['name'] as String?;
            if (name != null && name.trim().isNotEmpty) {
              out[i] = ExtTrack(name, artists, album: (j['album'] as Map?)?['name'] as String?, durationMs: (j['duration'] as num?)?.toInt());
            }
          }
        } catch (_) {}
        done++;
        if (done % 20 == 0 || done == uris.length) onStatus?.call('Reading songs… ${from + done} of ${from + uris.length}');
      }
    }

    await Future.wait([for (var w = 0; w < 6; w++) worker()]);
    return out.whereType<ExtTrack>().toList();
  }

  Future<ExtList> _apple(String link) async {
    final r = await _get(link);
    if (!r.ok) throw ImportProblem('The music app didn\'t open that link (${r.status})');
    final key = 'apple:${RegExp(r'(pl\.[A-Za-z0-9.-]+|/(\d+))(?:\?|$)').firstMatch(link)?.group(1) ?? link}';
    final l = parseAppleMusic(r.text, key);
    if (l == null || l.tracks.isEmpty) throw const ImportProblem('That playlist is empty or private');
    return l;
  }

  Future<ExtList> _saavn(String link, void Function(String)? onStatus) async {
    final u = Uri.parse(link);
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) throw const ImportProblem('Paste a playlist or album link');
    final token = segs.last;
    final type = segs.contains('album') ? 'album' : (segs.contains('song') ? 'song' : 'playlist');
    final tracks = <ExtTrack>[];
    String name = 'Imported playlist';
    String? cover;
    int? total;
    for (var page = 1; page <= 40; page++) {
      final r = await _get('https://www.jiosaavn.com/api.php?__call=webapi.get&token=$token&type=$type&p=$page&n=100&includeMetaTags=0&ctx=web6dot0&api_version=4&_format=json&_marker=0');
      if (!r.ok) break;
      final j = r.json;
      if (j is! Map) break;
      name = unescapeHtml('${j['title'] ?? name}');
      cover ??= j['image'] as String?;
      total ??= int.tryParse('${j['list_count'] ?? j['more_info']?['song_count'] ?? ''}');
      final list = type == 'song' ? (j['songs'] as List? ?? [j]) : (j['list'] as List? ?? const []);
      if (list.isEmpty) break;
      for (final s in list.whereType<Map>()) {
        final mi = s['more_info'] as Map? ?? const {};
        final prim = ((mi['artistMap'] as Map?)?['primary_artists'] as List?)?.whereType<Map>().map((a) => a['name']).join(', ');
        tracks.add(
          ExtTrack(
            unescapeHtml('${s['title'] ?? s['song'] ?? ''}'),
            unescapeHtml(prim?.isNotEmpty == true ? prim! : '${mi['music'] ?? s['subtitle'] ?? ''}'),
            album: mi['album'] == null ? null : unescapeHtml('${mi['album']}'),
            durationMs: int.tryParse('${mi['duration'] ?? ''}') == null ? null : int.parse('${mi['duration']}') * 1000,
          ),
        );
      }
      onStatus?.call('Reading songs… ${tracks.length}${total != null ? ' of $total' : ''}');
      if (type != 'playlist' || (total != null && tracks.length >= total) || list.length < 100) break;
    }
    if (tracks.isEmpty) throw const ImportProblem('That playlist is empty or private');
    return ExtList(name, cover, tracks, MusicService.jiosaavn, 'jiosaavn:$token', total: total);
  }

  Future<ExtList> _gaana(String link) async {
    final u = Uri.parse(link);
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    final seokey = segs.isEmpty ? '' : segs.last;
    final kind = segs.contains('album') ? 'albumDetail' : 'playlistDetail';
    try {
      final r = await net.send(
        NetRequest('POST', Uri.parse('https://gaana.com/apiv2?seokey=$seokey&type=$kind'), headers: {'User-Agent': _ua}),
        timeout: const Duration(seconds: 25),
      );
      final j = r.ok ? r.json : null;
      final list = j is Map ? (j['tracks'] as List?) : null;
      if (list != null && list.isNotEmpty) {
        final info = (j['playlist'] ?? j['album']) as Map?;
        return ExtList(
          unescapeHtml('${info?['title'] ?? info?['name'] ?? 'Imported playlist'}'),
          info?['atw'] as String? ?? info?['artwork'] as String?,
          [
            for (final t in list.whereType<Map>())
              ExtTrack(
                unescapeHtml('${t['track_title']}'),
                ((t['artist'] as List?) ?? const []).whereType<Map>().map((a) => a['name']).join(', '),
                album: t['album_title'] as String?,
                durationMs: int.tryParse('${t['duration'] ?? ''}') == null ? null : int.parse('${t['duration']}') * 1000,
              ),
          ],
          MusicService.gaana,
          'gaana:$seokey',
          // "trackcount" counts songs Gaana has since hidden; the id list is what it really holds.
          total: '${info?['trackids'] ?? ''}'.isEmpty ? null : '${info?['trackids']}'.split(',').length,
        );
      }
    } catch (_) {}
    final r = await _get(link);
    final l = parseJsonLdList(r.text, MusicService.gaana, 'gaana:$seokey');
    if (l == null) throw const ImportProblem('That playlist is empty or private');
    return l;
  }

  Future<ExtList> _amazon(String link) async {
    var u = link;
    if (!Uri.parse(u).host.startsWith('music.amazon.')) {
      final r = await _get(u);
      final m = RegExp(r'https://music\.amazon\.[a-z.]+/(?:playlists|albums|user-playlists)/[A-Za-z0-9]+').firstMatch(r.text);
      if (m != null) u = m.group(0)!;
    }
    final r = await _get(u, ua: _bot);
    final l = parseAmazonMusic(r.text, 'amazon:${Uri.parse(u).pathSegments.lastOrNull ?? u}');
    if (l == null || l.tracks.isEmpty) {
      // Amazon shows a person's own playlists (and "My Likes") only to them:
      // to everyone else its page says "this playlist is no longer available".
      throw ImportProblem(
        'Amazon Music only shows this playlist to the account that made it, so the link alone can\'t open it. Log in to Amazon Music here and Byte brings it from your account.',
        loginService: 'amazon',
        link: u,
      );
    }
    return l;
  }

  Future<ExtList> _soundcloud(String link) async {
    final r = await _get(link);
    final p = parseSoundCloud(r.text);
    if (p == null) throw const ImportProblem('That link isn\'t a public playlist or track');
    final tracks = [...p.tracks];
    if (p.missing.isNotEmpty) {
      final cid = await _soundCloudClientId(r.text);
      if (cid != null) {
        for (var i = 0; i < p.missing.length; i += 50) {
          final ids = p.missing.skip(i).take(50).join(',');
          try {
            final rr = await _get('https://api-v2.soundcloud.com/tracks?ids=$ids&client_id=$cid');
            final byId = {for (final t in (rr.json as List).whereType<Map>()) t['id']: t};
            for (final id in p.missing.skip(i).take(50)) {
              final t = byId[id];
              if (t != null) tracks.add(soundCloudTrack(t));
            }
          } catch (_) {}
        }
      }
    }
    return ExtList(p.name, p.cover, tracks, MusicService.soundcloud, 'soundcloud:${Uri.parse(link).path}', total: p.total);
  }

  Future<String?> _soundCloudClientId(String html) async {
    final scripts = RegExp(r'<script crossorigin src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)"').allMatches(html).map((m) => m.group(1)!).toList();
    for (final s in scripts.reversed) {
      try {
        final r = await _get(s);
        final m = RegExp(r'client_id\s*[:=]\s*"([A-Za-z0-9]{32})"').firstMatch(r.text) ?? RegExp(r'client_id=([A-Za-z0-9]{32})').firstMatch(r.text);
        if (m != null) return m.group(1);
      } catch (_) {}
    }
    return null;
  }

  Future<ExtList> _deezer(String link, void Function(String)? onStatus) async {
    var u = link;
    if (!Uri.parse(u).host.contains('deezer.com')) {
      final r = await _get(u);
      final m = RegExp(r'deezer\.com/(?:[a-z]{2}/)?(playlist|album|track)/(\d+)').firstMatch(r.text);
      if (m != null) u = 'https://www.deezer.com/${m.group(1)}/${m.group(2)}';
    }
    final m = RegExp(r'/(playlist|album|track)/(\d+)').firstMatch(u);
    if (m == null) throw const ImportProblem('Paste a playlist or album link');
    final type = m.group(1)!, id = m.group(2)!;
    final info = (await _get('https://api.deezer.com/$type/$id')).json as Map;
    if (info['error'] != null) throw const ImportProblem('That playlist is private or gone');
    if (type == 'track') {
      return ExtList('${info['title']}', (info['album'] as Map?)?['cover_xl'] as String?, [_dzTrack(info)], MusicService.deezer, 'deezer:$id');
    }
    final tracks = <ExtTrack>[];
    String? next = 'https://api.deezer.com/$type/$id/tracks?index=0&limit=100';
    while (next != null && tracks.length < 5000) {
      final j = (await _get(next)).json as Map;
      for (final t in (j['data'] as List? ?? const []).whereType<Map>()) {
        tracks.add(_dzTrack(t, album: type == 'album' ? '${info['title']}' : null));
      }
      onStatus?.call('Reading songs… ${tracks.length}');
      next = j['next'] as String?;
    }
    return ExtList('${info['title']}', (info['picture_xl'] ?? info['cover_xl']) as String?, tracks, MusicService.deezer, 'deezer:$id', total: (info['nb_tracks'] as num?)?.toInt());
  }

  ExtTrack _dzTrack(Map t, {String? album}) =>
      ExtTrack('${t['title']}', '${(t['artist'] as Map?)?['name'] ?? ''}', album: album ?? (t['album'] as Map?)?['title'] as String?, durationMs: (t['duration'] as num?) == null ? null : (t['duration'] as num).toInt() * 1000);

  Future<ExtList> _wynk(String link) async {
    try {
      return await _web(link, service: MusicService.wynk);
    } catch (_) {
      throw const ImportProblem(
        'That music app has shut down, so its playlists can\'t be opened any more. Paste the same playlist from another app, or import a CSV of it.',
      );
    }
  }

  /// Any other site that describes its playlist with schema.org data.
  Future<ExtList> _web(String link, {MusicService service = MusicService.web}) async {
    final r = await _get(link);
    final l = parseJsonLdList(r.text, service, 'web:$link');
    if (l == null) throw const ImportProblem('Couldn\'t find a song list on that page. Paste the songs as text, or import a CSV file.');
    return l;
  }
}

String spotifyGidHex(String base62) {
  const abc = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var n = BigInt.zero;
  for (final c in base62.split('')) {
    n = n * BigInt.from(62) + BigInt.from(abc.indexOf(c));
  }
  return n.toRadixString(16).padLeft(32, '0');
}

// ── Matching on YouTube Music ─────────────────────────────────────────────

class TrackMatch {
  final ExtTrack source;
  List<Item> candidates;
  Item? chosen;
  double score;
  bool searched;
  /// The search itself failed (no internet, YouTube busy): worth trying again.
  bool failed = false;
  TrackMatch(this.source, {this.candidates = const [], this.chosen, this.score = 0, this.searched = false});
  bool get matched => chosen != null;
}

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\((?:from|feat|ft|with|official|lyric|audio|video|remaster)[^)]*\)|\[[^\]]*\]', caseSensitive: false), ' ')
    .replaceAll(RegExp(r'\b(feat|ft|featuring)\.?\b.*$'), ' ')
    .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();


// ── Hindi / Bengali script → Latin, for matching ──────────────────────────
// Song lists typed in Devanagari or Bengali script are compared with YouTube
// Music's (usually Latin) titles by their consonant "skeleton".
const _devCons = {
  'क': 'k', 'ख': 'kh', 'ग': 'g', 'घ': 'gh', 'ङ': 'n', 'च': 'ch', 'छ': 'chh', 'ज': 'j', 'झ': 'jh', 'ञ': 'n',
  'ट': 't', 'ठ': 'th', 'ड': 'd', 'ढ': 'dh', 'ण': 'n', 'त': 't', 'थ': 'th', 'द': 'd', 'ध': 'dh', 'न': 'n',
  'प': 'p', 'फ': 'ph', 'ब': 'b', 'भ': 'bh', 'म': 'm', 'य': 'y', 'र': 'r', 'ल': 'l', 'व': 'v', 'श': 'sh',
  'ष': 'sh', 'स': 's', 'ह': 'h', 'क़': 'k', 'ख़': 'kh', 'ग़': 'g', 'ज़': 'z', 'ड़': 'r', 'ढ़': 'rh', 'फ़': 'f', 'य़': 'y', 'ळ': 'l',
  // Bengali
  'ক': 'k', 'খ': 'kh', 'গ': 'g', 'ঘ': 'gh', 'ঙ': 'ng', 'চ': 'ch', 'ছ': 'chh', 'জ': 'j', 'ঝ': 'jh', 'ঞ': 'n',
  'ট': 't', 'ঠ': 'th', 'ড': 'd', 'ঢ': 'dh', 'ণ': 'n', 'ত': 't', 'থ': 'th', 'দ': 'd', 'ধ': 'dh', 'ন': 'n',
  'প': 'p', 'ফ': 'ph', 'ব': 'b', 'ভ': 'bh', 'ম': 'm', 'য': 'j', 'র': 'r', 'ল': 'l', 'শ': 'sh', 'ষ': 'sh',
  'স': 's', 'হ': 'h', 'ড়': 'r', 'ঢ়': 'rh', 'য়': 'y', 'ৎ': 't',
};
const _devVowels = {
  'अ': 'a', 'आ': 'aa', 'इ': 'i', 'ई': 'ii', 'उ': 'u', 'ऊ': 'uu', 'ऋ': 'ri', 'ए': 'e', 'ऐ': 'ai', 'ओ': 'o', 'औ': 'au',
  'ा': 'aa', 'ि': 'i', 'ी': 'ii', 'ु': 'u', 'ू': 'uu', 'ृ': 'ri', 'े': 'e', 'ै': 'ai', 'ो': 'o', 'ौ': 'au', 'ॉ': 'o', 'ॅ': 'e',
  'অ': 'o', 'আ': 'a', 'ই': 'i', 'ঈ': 'i', 'উ': 'u', 'ঊ': 'u', 'ঋ': 'ri', 'এ': 'e', 'ঐ': 'oi', 'ও': 'o', 'ঔ': 'ou',
  'া': 'a', 'ি': 'i', 'ী': 'i', 'ু': 'u', 'ূ': 'u', 'ৃ': 'ri', 'ে': 'e', 'ৈ': 'oi', 'ো': 'o', 'ৌ': 'ou',
};

bool hasIndicScript(String s) => RegExp(r'[\u0900-\u09FF]').hasMatch(s);

/// Rough Latin spelling of Hindi (Devanagari) or Bengali text.
String romanizeIndic(String s) {
  if (!hasIndicScript(s)) return s;
  final out = StringBuffer();
  final chars = s.characters0();
  var pendingA = false;
  for (var i = 0; i < chars.length; i++) {
    var c = chars[i];
    // nukta forms written as two code points
    if (i + 1 < chars.length && (chars[i + 1] == '\u093C' || chars[i + 1] == '\u09BC') && _devCons.containsKey('$c${chars[i + 1]}')) {
      c = '$c${chars[i + 1]}';
      i++;
    }
    final cons = _devCons[c];
    final vow = _devVowels[c];
    if (cons != null) {
      if (pendingA) out.write('a');
      out.write(cons);
      pendingA = true;
    } else if (vow != null) {
      out.write(vow);
      pendingA = false;
    } else if (c == '\u094D' || c == '\u09CD') {
      pendingA = false; // virama: no vowel
    } else if (c == 'ं' || c == 'ँ' || c == 'ঁ') {
      if (pendingA) out.write('a');
      out.write('n');
      pendingA = false;
    } else if (c == 'ং') {
      if (pendingA) out.write('o');
      out.write('ng');
      pendingA = false;
    } else if (c == 'ः' || c == 'ঃ' || c == '\u093C' || c == '\u09BC') {
      // visarga / stray nukta
    } else {
      pendingA = false;
      out.write(c);
    }
  }
  return out.toString();
}

extension on String {
  List<String> characters0() => runes.map(String.fromCharCode).toList();
}

/// Consonant skeleton of one word: "Rahman" and "रहमान" both give "rmn".
String _skeleton(String w) {
  var s = w.toLowerCase().replaceAll('w', 'v').replaceAll('z', 'j').replaceAll('q', 'k').replaceAll('f', 'p').replaceAll(RegExp(r'[aeiouy]'), '');
  s = s.replaceAllMapped(RegExp(r'([bcdgjklmnprstv])h'), (m) => m.group(1)!);
  s = s.replaceAll(RegExp(r'^h'), '');
  s = s.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);
  return s;
}

double _skeletonOverlap(String a, String b) {
  Set<String> words(String s) => _norm(romanizeIndic(s)).split(' ').map(_skeleton).where((w) => w.isNotEmpty).toSet();
  final x = words(a), y = words(b);
  if (x.isEmpty || y.isEmpty) return 0;
  final inter = x.intersection(y).length;
  return inter / (x.length < y.length ? x.length : y.length) * 0.6 + inter / x.union(y).length * 0.4;
}

double _overlap(String a, String b) {
  if (hasIndicScript(a) != hasIndicScript(b)) return _skeletonOverlap(a, b) * 0.9;
  final x = _norm(a).split(' ').where((w) => w.isNotEmpty).toSet();
  final y = _norm(b).split(' ').where((w) => w.isNotEmpty).toSet();
  if (x.isEmpty || y.isEmpty) return 0;
  final inter = x.intersection(y).length;
  return inter / (x.length < y.length ? x.length : y.length) * 0.6 + inter / x.union(y).length * 0.4;
}

/// Settings → Sources → Track length tolerance (seconds): how far a song's
/// length may differ and still count as the same recording.
int matchToleranceSec = 3;

/// How well a YouTube Music result fits a song from another app (0 … ~4).
double matchScore(ExtTrack t, Item c) {
  final titleFit = _overlap(t.title, c.title);
  var artistFit = t.artists.isEmpty ? 0.5 : _overlap(t.artists, c.artistLine);
  // "Artist - Song" lines: the sides may be swapped.
  if (t.artists.isNotEmpty) {
    final swapped = _overlap(t.artists, c.title) * 0.9 + (_overlap(t.title, c.artistLine)) * 0.9;
    if (swapped > titleFit * 2 + artistFit) return swapped + 0.1;
  }
  var s = titleFit * 2 + artistFit;
  if (t.durationMs != null && c.durationSec != null) {
    final d = (t.durationMs! / 1000 - c.durationSec!).abs();
    final tol = matchToleranceSec;
    s += d <= tol ? 0.8 : (d <= tol * 3 + 1 ? 0.4 : (d > 45 ? -0.8 : 0));
  }
  if (c.kind == ItemKind.song) s += 0.25;
  final lowT = t.title.toLowerCase(), lowC = c.title.toLowerCase();
  for (final w in ['remix', 'live', 'lofi', 'lo-fi', 'slowed', 'reverb', 'cover', 'karaoke', 'instrumental', 'acoustic', 'unplugged']) {
    if (lowC.contains(w) != lowT.contains(w)) s -= 0.5;
  }
  return s;
}

class PlaylistMatcher {
  final InnerTube yt;
  PlaylistMatcher(this.yt, {Future<void> Function(Duration)? sleep}) : _sleep = sleep ?? Future<void>.delayed;

  static const minScore = 1.3;

  /// Shared pause: when YouTube says "slow down", every worker waits.
  DateTime _pauseUntil = DateTime.fromMillisecondsSinceEpoch(0);
  final Future<void> Function(Duration) _sleep;

  /// One search, retried with growing pauses when the net hiccups or YouTube
  /// is busy (403 / 429 / 5xx). Throws only after the last try.
  Future<List<Item>> _search(String q, SearchFilter f) async {
    Object? last;
    for (var attempt = 0; attempt < 4; attempt++) {
      final wait = _pauseUntil.difference(DateTime.now());
      if (wait > Duration.zero) await _sleep(wait);
      try {
        return await yt.search(q, f);
      } on NetException catch (e) {
        last = e;
        final s = e.status;
        if (s != null && s != 403 && s != 429 && s < 500) rethrow; // a real "no"
      } catch (e) {
        last = e; // offline / timeout
      }
      final backoff = Duration(milliseconds: 1500 * (1 << attempt));
      final until = DateTime.now().add(backoff);
      if (until.isAfter(_pauseUntil)) _pauseUntil = until;
    }
    throw last ?? Exception('search failed');
  }

  Future<void> matchOne(TrackMatch m) async {
    final t = m.source;
    var results = <Item>[];
    var errors = 0, tries = 0;
    Future<List<Item>> trySearch(String q, SearchFilter f) async {
      tries++;
      try {
        return await _search(q, f);
      } catch (_) {
        errors++;
        return const [];
      }
    }

    results = await trySearch(t.query, SearchFilter.songs);
    var best = _best(t, results);
    if (best.$2 < minScore) {
      final videos = await trySearch(t.query, SearchFilter.videos);
      final bv = _best(t, videos);
      results = [...results, ...videos];
      if (bv.$2 > best.$2) best = bv;
    }
    // Still nothing: a shorter search (clean title + main artist) often finds
    // songs whose full artist list or "(From …)" tag confuses the search.
    final short = t.shortQuery;
    if (best.$2 < minScore && short != t.query) {
      final more = await trySearch(short, SearchFilter.songs);
      final bs = _best(t, more);
      results = [...results, ...more];
      if (bs.$2 > best.$2) best = bs;
    }
    final seen = <String>{};
    results = results.where((i) => seen.add(i.id)).toList();
    m.candidates = (results.where((i) => i.isPlayable).toList()..sort((a, b) => matchScore(t, b).compareTo(matchScore(t, a)))).take(8).toList();
    m.score = best.$2;
    m.chosen = best.$2 >= minScore ? best.$1 : null;
    m.searched = true;
    m.failed = m.chosen == null && errors > 0 && errors == tries;
  }

  (Item?, double) _best(ExtTrack t, List<Item> items) {
    Item? best;
    var score = -9.0;
    for (final c in items.where((i) => i.isPlayable).take(10)) {
      final s = matchScore(t, c);
      if (s > score) {
        score = s;
        best = c;
      }
    }
    return (best, score);
  }

  /// Matches every song, 4 at a time. [cancelled] stops early.
  Future<List<TrackMatch>> matchAll(List<ExtTrack> tracks, {void Function(int done, int total)? onProgress, bool Function()? cancelled}) async {
    final out = [for (final t in tracks) TrackMatch(t)];
    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < out.length && !(cancelled?.call() ?? false)) {
        final i = next++;
        await matchOne(out[i]);
        done++;
        onProgress?.call(done, out.length);
      }
    }

    await Future.wait([for (var w = 0; w < 4; w++) worker()]);
    return out;
  }
}
