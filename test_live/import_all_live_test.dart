import 'dart:io';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/net.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/relay_net.dart';

class _RealHttp extends HttpOverrides {}

/// YouTube searches go through the home-connection relay when RELAY is set
/// (this build box's own address is rate-limited by YouTube).
Net ytNet() => Platform.environment['RELAY'] != null ? RelayNet(Platform.environment['RELAY']!) : HttpNet();

/// Live check of every importer, full matching, against real public links.
void main() {
  const links = {
    'spotify619': 'https://open.spotify.com/playlist/6WgaVgtRZgtmDrWVUWU1R5?si=abc',
    'spotifyAlbum': 'https://open.spotify.com/album/4yP0hdKOZPNshxUOjY0cZj',
    'apple': 'https://music.apple.com/us/playlist/bollywood-hits/pl.d60caf02fcce4d7e9788fe01243b7c2c',
    'ytmusicPlaylist': 'https://music.youtube.com/playlist?list=RDCLAK5uy_n9Fbdw7e6ap-98_A-8JYBmPv64v-Uaq1g',
    'youtubeLong': 'https://www.youtube.com/playlist?list=PL4fGSI1pDJn5kI81J1fYWK5eZRl1zJ5kM',
    'ytmusicAlbum': 'https://music.youtube.com/browse/MPREb_E4GfUXfDfhy',
    'youtubeSong': 'https://youtu.be/Umqb9KENgmk',
    'jiosaavn': 'https://www.jiosaavn.com/featured/lets-play-arijit-singh-hindi/Iz0pi7nkjUE_',
    'gaana': 'https://gaana.com/playlist/gaana-dj-hindi-top-50-1',
    'amazon': 'https://music.amazon.com/playlists/B09Z31W6FV',
    'soundcloud': 'https://soundcloud.com/user-514899698/sets/lofi-bollywood',
    'deezer': 'https://www.deezer.com/en/playlist/5714603022',
    'wynk': 'https://wynk.in/music/playlist/romantic-hits/bb_1517292429',
  };
  Future<String> match(InnerTube yt, List<ExtTrack> tracks) async {
    final ms = await PlaylistMatcher(yt).matchAll(tracks);
    final miss = ms.where((m) => !m.matched).map((m) => m.source.toString()).join(' | ');
    return '${ms.where((m) => m.matched).length}/${ms.length} MISSED: $miss';
  }

  for (final e in links.entries) {
    test(e.key, () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final net = HttpNet();
        final yt = InnerTube(ytNet());
        final r = PlaylistReader(net, yt);
        try {
          final l = await r.read(e.value);
          final n = l.ready?.length ?? l.tracks.length;
          var matched = l.ready != null ? 'ready (already YouTube Music)' : '';
          if (l.tracks.isNotEmpty) matched = await match(yt, l.tracks);
          // ignore: avoid_print
          print('LIVE ${e.key}: OK "${l.name}" read $n (service says ${l.total}) match $matched');
        } catch (err) {
          // ignore: avoid_print
          print('LIVE ${e.key}: ERROR-MESSAGE "$err"');
        }
      }, _RealHttp());
    }, timeout: const Timeout(Duration(minutes: 20)));
  }

  test('paste text', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final yt = InnerTube(ytNet());
      const text = """1. Tum Hi Ho - Arijit Singh
2. Kesariya by Arijit Singh
• Channa Mereya – Arijit Singh
Pritam - Ae Dil Hai Mushkil
Apna Bana Le
আমার পরান যাহা চায় - Shreya Ghoshal
तेरे बिना - ए आर रहमान
Shape of You — Ed Sheeran""";
      final tr = parseTextList(text);
      // ignore: avoid_print
      print('LIVE pasteText: parsed ${tr.length} match ${await match(yt, tr)}');
    }, _RealHttp());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('csv + txt files', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final yt = InnerTube(ytNet());
      const csv = '"Track URI","Track Name","Artist Name(s)","Album Name","Duration (ms)"\n'
          '"spotify:track:1","Raataan Lambiyan (From ""Shershaah"")","Tanishk Bagchi, Jubin Nautiyal, Asees Kaur","Shershaah","230000"\n'
          '"spotify:track:2","Kal Ho Naa Ho","Sonu Nigam","Kal Ho Naa Ho","321000"\n'
          '"spotify:track:3","Blinding Lights","The Weeknd","After Hours","200040"\n'
          '"spotify:track:4","Pasoori","Ali Sethi, Shae Gill","Coke Studio","224000"\n';
      final a = parseCsvList(csv);
      const tmm = 'Track name,Artist name,Album,Playlist name,Type,ISRC\nLevitating,Dua Lipa,Future Nostalgia,My,Favorite,X\nKhairiyat,Arijit Singh,Chhichhore,My,Favorite,Y\n';
      final b = parseCsvList(tmm);
      final txt = parseCsvList('Tujhe Kitna Chahne Lage - Arijit Singh\nAgar Tum Saath Ho - Alka Yagnik\n');
      // ignore: avoid_print
      print('LIVE csvExportify: parsed ${a.length} match ${await match(yt, a)}');
      // ignore: avoid_print
      print('LIVE csvTuneMyMusic: parsed ${b.length} match ${await match(yt, b)}');
      // ignore: avoid_print
      print('LIVE txtFile: parsed ${txt.length} match ${await match(yt, txt)}');
    }, _RealHttp());
  }, timeout: const Timeout(Duration(minutes: 5)));
}
