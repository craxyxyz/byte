
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:byte/core/net.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/data/playlist_import.dart';

/// Replays responses captured from an Indian (Airtel, Mumbai) IP.
class ReplayNet extends Net {
  final String dir;
  final Map<String, String> map;
  ReplayNet(this.dir, this.map);
  @override
  Future<NetResponse> send(NetRequest r, {Duration timeout = const Duration(seconds: 20)}) async {
    final u = r.url.toString();
    for (final e in map.entries) {
      if (u.startsWith(e.key)) return NetResponse(200, const {}, Uint8List.fromList(File('$dir/${e.value}.txt').readAsBytesSync()));
    }
    return NetResponse(404, const {}, Uint8List.fromList(utf8.encode('{}')));
  }
}

Future<void> main(List<String> a) async {
  final dir = a.first;
  final net = ReplayNet(dir, {
    'https://open.spotify.com/embed/playlist/37i9dQZEVXbLZ52XmnySJg': 'spotify_embed',
    'https://open.spotify.com/embed/playlist/4VxLLwRnF6c7sY6FrKWFgK': 'spotify_embed_user',
    'https://music.apple.com/jo/': 'apple',
    'https://music.apple.com/in/': 'apple_in',
    'https://www.jiosaavn.com/api.php': 'saavn_api',
    'https://music.amazon.in/playlists/': 'amazon_in',
    'https://music.amazon.com/playlists/': 'amazon_com',
    'https://music.amazon.in/user-playlists/': 'amazon_user',
    'https://api.deezer.com/playlist/5714603022/tracks': 'none',
    'https://api.deezer.com/playlist/5714603022': 'deezer_api',
    'https://soundcloud.com/': 'sc',
    'https://gaana.com/apiv2': 'gaana_api',
  });
  final r = PlaylistReader(net, InnerTube(net));
  for (final u in [
    'https://open.spotify.com/playlist/37i9dQZEVXbLZ52XmnySJg',
    'https://open.spotify.com/playlist/4VxLLwRnF6c7sY6FrKWFgK',
    'https://music.apple.com/jo/playlist/bollywood-chill/pl.322309345de044cdb07921938347e36e',
    'https://music.apple.com/in/playlist/from-across-the-room-english/pl.u-d2b00l0FdLdRkA',
    'https://www.jiosaavn.com/featured/trending-today/I3kvhipIy73uCJW60TJk1Q__',
    'https://music.amazon.in/playlists/B07646V4CG',
    'https://music.amazon.com/playlists/B09Z31W6FV',
    'https://music.amazon.in/user-playlists/6b90e13c16a7465e8cb325ccbcf26b8bi8n0',
    'https://soundcloud.com/chillhopdotcom/sets/lofihiphop',
    'https://gaana.com/playlist/gaana-dj-hindi-top-50-1',
  ]) {
    try {
      final l = await r.read(u);
      stdout.writeln('INDIA-IP OK\t${l.service.name}\t${l.tracks.length}\t${l.name}\t${l.tracks.take(2).join(" | ")}');
    } catch (e) {
      stdout.writeln('INDIA-IP FAIL\t$u\t$e');
    }
  }
  exit(0);
}
