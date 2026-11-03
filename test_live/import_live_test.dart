import 'dart:io';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/net.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

/// Live check of every importer against real public links (needs internet).
void main() {
  const links = {
    'spotify500': 'https://open.spotify.com/playlist/6WgaVgtRZgtmDrWVUWU1R5?si=abc',
    'spotifyAlbum': 'https://open.spotify.com/album/4yP0hdKOZPNshxUOjY0cZj',
    'apple': 'https://music.apple.com/us/playlist/bollywood-hits/pl.d60caf02fcce4d7e9788fe01243b7c2c',
    'jiosaavn': 'https://www.jiosaavn.com/featured/lets-play-arijit-singh-hindi/Iz0pi7nkjUE_',
    'gaana': 'https://gaana.com/playlist/gaana-dj-hindi-top-50-1',
    'amazon': 'https://music.amazon.com/playlists/B09Z31W6FV',
    'soundcloud': 'https://soundcloud.com/user-514899698/sets/lofi-bollywood',
    'deezer': 'https://www.deezer.com/en/playlist/5714603022',
    'youtube': 'https://music.youtube.com/playlist?list=RDCLAK5uy_n9Fbdw7e6ap-98_A-8JYBmPv64v-Uaq1g',
    'wynk': 'https://wynk.in/music/playlist/romantic-hits/bb_1517292429',
  };
  for (final e in links.entries) {
    test(e.key, () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final net = HttpNet();
        final yt = InnerTube(net);
        final r = PlaylistReader(net, yt);
        try {
          final l = await r.read(e.value);
          final n = l.ready?.length ?? l.tracks.length;
          final first = l.ready?.firstOrNull?.title ?? l.tracks.firstOrNull?.toString();
          final last = l.tracks.isEmpty ? '' : l.tracks.last.toString();
          var matched = '';
          if (l.tracks.isNotEmpty) {
            final ms = await PlaylistMatcher(yt).matchAll(l.tracks.take(8).toList());
            final eg = ms.map((m) => '${m.source.title} => ${m.chosen?.title ?? '-'} (${m.score.toStringAsFixed(2)})').take(3).join(' | ');
            matched = '${ms.where((m) => m.matched).length}/${ms.length} e.g. $eg';
          }
          // ignore: avoid_print
          print('LIVE ${e.key}: OK "${l.name}" $n songs (total ${l.total}) first="$first" last="$last" match $matched');
        } catch (err) {
          // ignore: avoid_print
          print('LIVE ${e.key}: FAIL $err');
        }
      }, _RealHttp());
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
