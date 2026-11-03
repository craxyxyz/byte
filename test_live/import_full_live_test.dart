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
            final ms = await PlaylistMatcher(yt).matchAll(l.tracks);
            final miss = ms.where((m) => !m.matched).take(6).map((m) => m.source.toString()).join(' | ');
            final eg = ms.map((m) => '${m.source.title} => ${m.chosen?.title ?? '-'} (${m.score.toStringAsFixed(2)})').take(3).join(' | ');
            matched = '${ms.where((m) => m.matched).length}/${ms.length} e.g. $eg MISSED: $miss';
          }
          // ignore: avoid_print
          print('LIVE ${e.key}: OK "${l.name}" $n songs (total ${l.total}) first="$first" last="$last" match $matched');
        } catch (err) {
          // ignore: avoid_print
          print('LIVE ${e.key}: FAIL $err');
        }
      }, _RealHttp());
    }, timeout: const Timeout(Duration(minutes: 20)));
  }
}
