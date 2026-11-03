
import 'dart:io';
import 'package:byte/core/net.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/data/playlist_import.dart';
Future<void> main(List<String> a) async {
  for (final hl in ['en','hi','bn']) {
    final yt = InnerTube(HttpNet(), hl: hl, gl: 'IN');
    for (final u in a) {
      try {
        final l = await PlaylistReader(HttpNet(), yt).read(u);
        final n = l.ready?.length ?? l.tracks.length;
        stdout.writeln('hl=$hl OK $n ${l.name}');
        if (l.tracks.isNotEmpty) { final m = await PlaylistMatcher(yt).matchAll(l.tracks.take(8).toList()); stdout.writeln('  match ${m.where((x)=>x.matched).length}/${m.length}'); }
      } catch (e) { stdout.writeln('hl=$hl FAIL $u $e'); }
    }
  }
  exit(0);
}
