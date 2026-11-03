
import 'dart:io';
import 'package:byte/core/net.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/data/playlist_import.dart';

Future<void> main(List<String> args) async {
  final net = HttpNet();
  final yt = InnerTube(net);
  final urls = args.isNotEmpty ? args : File('tool/live_urls.txt').readAsLinesSync().where((l) => l.trim().isNotEmpty && !l.startsWith('#')).toList();
  final match = Platform.environment['MATCH'] == '1';
  for (final u in urls) {
    final sw = Stopwatch()..start();
    try {
      final l = await PlaylistReader(net, yt).read(u, onStatus: (_) {}).timeout(const Duration(seconds: 90));
      final n = l.ready?.length ?? l.tracks.length;
      final sample = (l.ready != null ? l.ready!.take(3).map((i) => '${i.title} — ${i.artistLine}') : l.tracks.take(3).map((t) => t.toString())).join(' | ');
      stdout.writeln('OK\t${l.service.name}\t$n${l.total != null ? "/${l.total}" : ""}\t"${l.name}"\t${sw.elapsedMilliseconds}ms\t$u\t$sample');
      if (match && l.tracks.isNotEmpty) {
        final m = await PlaylistMatcher(yt).matchAll(l.tracks.take(int.tryParse(Platform.environment['MATCHN'] ?? '') ?? 10).toList());
        final ok = m.where((x) => x.chosen != null).toList();
        final picks = ok.take(3).map((x) => '${x.source.title} -> ${x.chosen!.title} [${x.chosen!.id}]').join(' | ');
        stdout.writeln('  MATCH\t${ok.length}/${m.length}\t${sw.elapsedMilliseconds}ms\t$picks');
      }
    } catch (e, st) {
      stdout.writeln('FAIL\t${detectService(u)?.name}\t${sw.elapsedMilliseconds}ms\t$u\t${e.toString().split("\n").first}');
      if (Platform.environment['TRACE'] == '1') stdout.writeln(st);
    }
  }
  exit(0);
}
