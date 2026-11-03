import 'dart:convert';

import '../core/innertube.dart';
import '../core/models.dart';
import '../core/net.dart';

enum LinkKind { ytPlaylist, ytAlbum, ytVideo, ytArtist, spotifyPlaylist, spotifyAlbum, spotifyTrack, spotifyShort, unknown }

class ParsedLink {
  final LinkKind kind;
  final String id;
  const ParsedLink(this.kind, this.id);
  bool get isSpotify => kind.name.startsWith('spotify');
  @override
  String toString() => 'ParsedLink(${kind.name}, $id)';
}

/// Understands every common YouTube / YouTube Music / Spotify share link.
ParsedLink parseLink(String input) {
  var s = input.trim();
  final firstUrl = RegExp(r'(https?://\S+|spotify:\S+)').firstMatch(s);
  if (firstUrl != null) s = firstUrl.group(0)!;
  // spotify:playlist:ID
  final su = RegExp(r'^spotify:(playlist|album|track):([A-Za-z0-9]{22})').firstMatch(s);
  if (su != null) return ParsedLink(_spotifyKind(su.group(1)!), su.group(2)!);
  // bare playlist ids
  if (RegExp(r'^(PL|OLAK5uy_|RDCLAK|LL|UU|FL|VL)[A-Za-z0-9_\-]{10,}$').hasMatch(s)) {
    return s.startsWith('OLAK5uy_') ? ParsedLink(LinkKind.ytAlbum, s) : ParsedLink(LinkKind.ytPlaylist, s.startsWith('VL') ? s.substring(2) : s);
  }
  Uri? u;
  try {
    u = Uri.parse(s.startsWith('http') ? s : 'https://$s');
  } catch (_) {
    return const ParsedLink(LinkKind.unknown, '');
  }
  final host = u.host.toLowerCase().replaceFirst('www.', '').replaceFirst('m.', '');
  if (host == 'spotify.link' || host == 'spoti.fi') return ParsedLink(LinkKind.spotifyShort, u.toString());
  if (host == 'open.spotify.com' || host == 'play.spotify.com') {
    final segs = u.pathSegments.where((p) => !p.startsWith('intl-') && p != 'embed').toList();
    if (segs.length >= 2 && RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(segs[1])) {
      return ParsedLink(_spotifyKind(segs[0]), segs[1]);
    }
    return const ParsedLink(LinkKind.unknown, '');
  }
  if (host == 'youtu.be') {
    final list = u.queryParameters['list'];
    if (list != null && list.isNotEmpty && !list.startsWith('RD')) return ParsedLink(LinkKind.ytPlaylist, list);
    if (u.pathSegments.isNotEmpty) return ParsedLink(LinkKind.ytVideo, u.pathSegments.first);
  }
  if (host == 'youtube.com' || host == 'music.youtube.com' || host == 'youtube-nocookie.com') {
    final list = u.queryParameters['list'];
    final segs = u.pathSegments;
    if (segs.isNotEmpty && segs.first == 'browse' && segs.length > 1) {
      final id = segs[1];
      if (id.startsWith('MPRE')) return ParsedLink(LinkKind.ytAlbum, id);
      if (id.startsWith('VL')) return ParsedLink(LinkKind.ytPlaylist, id.substring(2));
      if (id.startsWith('UC')) return ParsedLink(LinkKind.ytArtist, id);
    }
    if (segs.isNotEmpty && segs.first == 'channel' && segs.length > 1) return ParsedLink(LinkKind.ytArtist, segs[1]);
    if (list != null && list.isNotEmpty) {
      if (list.startsWith('OLAK5uy_')) return ParsedLink(LinkKind.ytAlbum, list);
      // Radio mixes (RD…) are generated per session; treat as the seed video.
      if (!list.startsWith('RDAMVM') && !(list.startsWith('RD') && !list.startsWith('RDCLAK'))) {
        return ParsedLink(LinkKind.ytPlaylist, list);
      }
    }
    final v = u.queryParameters['v'];
    if (v != null && v.isNotEmpty) return ParsedLink(LinkKind.ytVideo, v);
    if (segs.length >= 2 && (segs.first == 'shorts' || segs.first == 'embed' || segs.first == 'live')) return ParsedLink(LinkKind.ytVideo, segs[1]);
  }
  return const ParsedLink(LinkKind.unknown, '');
}

LinkKind _spotifyKind(String s) => switch (s) {
  'playlist' => LinkKind.spotifyPlaylist,
  'album' => LinkKind.spotifyAlbum,
  'track' => LinkKind.spotifyTrack,
  _ => LinkKind.unknown,
};

class SpotifyTrack {
  final String title;
  final String artists;
  final int? durationMs;
  const SpotifyTrack(this.title, this.artists, this.durationMs);
}

class SpotifyList {
  final String name;
  final String? cover;
  final List<SpotifyTrack> tracks;

  /// Rows the embed listed (songs + anything it couldn't name). The embed
  /// stops at 100.
  final int listed;
  const SpotifyList(this.name, this.cover, this.tracks, [int? listed]) : listed = listed ?? tracks.length;
}

/// Reads the public embed page's data (no account or API key needed).
SpotifyList? parseSpotifyEmbed(String html) {
  final m = RegExp(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', dotAll: true).firstMatch(html);
  if (m == null) return null;
  final data = jsonDecode(m.group(1)!);
  Map? entity;
  void find(dynamic o) {
    if (entity != null) return;
    if (o is Map) {
      if (o['entity'] is Map) {
        entity = o['entity'] as Map;
        return;
      }
      o.values.forEach(find);
    } else if (o is List) {
      o.forEach(find);
    }
  }

  find(data);
  final e = entity;
  if (e == null) return null;
  final name = (e['name'] ?? e['title'] ?? 'Imported playlist') as String;
  String? cover;
  final imgs = (e['coverArt']?['sources'] ?? e['visualIdentity']?['image']) as List?;
  if (imgs != null && imgs.isNotEmpty) cover = (imgs.last as Map)['url'] as String?;
  final tracks = <SpotifyTrack>[];
  final tl = e['trackList'] as List?;
  if (tl != null) {
    for (final t in tl.whereType<Map>()) {
      final title = t['title'] as String? ?? '';
      if (title.isEmpty) continue;
      tracks.add(SpotifyTrack(title, t['subtitle'] as String? ?? '', (t['duration'] as num?)?.toInt()));
    }
  } else if (e['type'] == 'track') {
    final artists = ((e['artists'] as List?) ?? const []).map((a) => (a as Map)['name']).join(', ');
    tracks.add(SpotifyTrack(name, artists, (e['duration'] as num?)?.toInt()));
  }
  return SpotifyList(name, cover, tracks, tl?.length);
}

double _similar(String a, String b) {
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
      .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097F\u0980-\u09FF ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final x = norm(a).split(' ').where((w) => w.isNotEmpty).toSet();
  final y = norm(b).split(' ').where((w) => w.isNotEmpty).toSet();
  if (x.isEmpty || y.isEmpty) return 0;
  return x.intersection(y).length / x.union(y).length;
}

/// Best YouTube Music song for a Spotify track (title + artist + duration).
Item? pickMatch(SpotifyTrack t, List<Item> candidates) {
  Item? best;
  var bestScore = -1.0;
  for (final c in candidates.take(8)) {
    var score = _similar(t.title, c.title) * 2 + _similar(t.artists, c.artistLine);
    if (t.durationMs != null && c.durationSec != null) {
      final d = (t.durationMs! / 1000 - c.durationSec!).abs();
      score += d <= 3 ? 1 : (d <= 10 ? 0.5 : (d > 40 ? -1 : 0));
    }
    if (c.kind == ItemKind.song) score += 0.2;
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return bestScore >= 0.8 ? best : null;
}

class ImportResult {
  final String name;
  final String? cover;
  final List<Item> items;
  final int notFound;
  final String source;
  const ImportResult(this.name, this.cover, this.items, this.notFound, this.source);
}

class LinkImporter {
  final InnerTube yt;
  final Net net;
  LinkImporter(this.yt, this.net);

  Future<ImportResult> import(String link, {void Function(int done, int total)? onProgress}) async {
    var p = parseLink(link);
    if (p.kind == LinkKind.spotifyShort) {
      final r = await net.get(Uri.parse(p.id), headers: {'User-Agent': _browserUa});
      final m = RegExp(r'open\.spotify\.com/(?:intl-[a-z]+/)?(playlist|album|track)/([A-Za-z0-9]{22})').firstMatch(r.text);
      if (m == null) throw const FormatException('That link did not open a playlist');
      p = ParsedLink(_spotifyKind(m.group(1)!), m.group(2)!);
    }
    switch (p.kind) {
      case LinkKind.ytPlaylist:
      case LinkKind.ytAlbum:
        final page = p.kind == LinkKind.ytAlbum && p.id.startsWith('MPRE') ? await yt.album(p.id) : await yt.playlist(p.id);
        final tracks = page.tracks.where((t) => t.isPlayable).toList();
        if (tracks.isEmpty) throw const FormatException('That playlist is empty or private');
        return ImportResult(page.header.title.isEmpty ? 'Imported playlist' : page.header.title, page.header.thumb, tracks, 0, 'youtube:${p.id}');
      case LinkKind.ytVideo:
        final n = await yt.next(p.id);
        final first = n.queue.where((i) => i.id == p.id).firstOrNull ?? (n.queue.isNotEmpty ? n.queue.first : null);
        if (first == null) throw const FormatException('Could not find that song');
        return ImportResult(first.title, first.thumb, [first], 0, 'youtube:${p.id}');
      case LinkKind.spotifyPlaylist:
      case LinkKind.spotifyAlbum:
      case LinkKind.spotifyTrack:
        final type = p.kind == LinkKind.spotifyPlaylist ? 'playlist' : (p.kind == LinkKind.spotifyAlbum ? 'album' : 'track');
        final r = await net.get(Uri.parse('https://open.spotify.com/embed/$type/${p.id}'), headers: {'User-Agent': _browserUa});
        if (!r.ok) throw FormatException('The music app answered ${r.status}');
        final list = parseSpotifyEmbed(r.text);
        if (list == null || list.tracks.isEmpty) throw const FormatException('That playlist is empty or private');
        final out = List<Item?>.filled(list.tracks.length, null);
        var done = 0;
        var next = 0;
        Future<void> worker() async {
          while (next < list.tracks.length) {
            final i = next++;
            final t = list.tracks[i];
            try {
              final res = await yt.search('${t.title} ${t.artists}', SearchFilter.songs);
              out[i] = pickMatch(t, res);
            } catch (_) {}
            done++;
            onProgress?.call(done, list.tracks.length);
          }
        }

        await Future.wait([for (var w = 0; w < 4; w++) worker()]);
        final items = out.whereType<Item>().toList();
        return ImportResult(list.name, list.cover, items, list.tracks.length - items.length, 'spotify:${p.id}');
      case LinkKind.ytArtist:
        final page = await yt.artist(p.id);
        final songs = page.shelves.expand((s) => s.items).where((i) => i.kind == ItemKind.song).toList();
        return ImportResult(page.header.title, page.header.thumb, songs, 0, 'youtube:${p.id}');
      case LinkKind.spotifyShort:
      case LinkKind.unknown:
        throw const FormatException('Paste a playlist link from a music app');
    }
  }
}

const _browserUa = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Mobile Safari/537.36';
