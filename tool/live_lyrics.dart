
import 'dart:convert';
import 'dart:io';
import 'package:byte/core/net.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/lyrics/lyrics_service.dart';

// Byte 1.4.1 live lyrics check: what Byte picks for real songs and videos,
// and how far it moved the timings to line them up with the upload.
Future<void> main(List<String> a) async {
  final net = HttpNet();
  final yt = InnerTube(net);
  final svc = LyricsService(net, yt);
  svc.order = () => ['lrclib', 'kugou', 'ytm'];
  svc.off = () => {'ytcaptions', 'files', 'addons', 'musixmatch'};
  final out = <Map>[];
  for (final q in a) {
    for (final f in [SearchFilter.songs, SearchFilter.videos]) {
      final r = await yt.search(q, f);
      if (r.isEmpty) continue;
      final it = r.first;
      final l = await svc.forItem(it);
      String s(int? ms) => ms == null ? '-' : (ms / 1000).toStringAsFixed(2);
      stdout.writeln('${f.name.padRight(6)} ${it.id} ${it.durationSec}s "${it.title}" — ${it.artistLine}');
      stdout.writeln('       -> ${l.kind.name} · ${l.source} · timed for ${s(l.durationMs)} s · moved ${s(l.shiftedMs)} s · ${l.lines.length} lines');
      out.add({'q': q, 'kind': f.name, 'id': it.id, 'title': it.title, 'dur': it.durationSec, 'lyrics': l.kind.name, 'source': l.source, 'timedFor': l.durationMs, 'shifted': l.shiftedMs});
    }
  }
  File(Platform.environment['OUT'] ?? '/tmp/lyrics_live.json').writeAsStringSync(jsonEncode(out));
  exit(0);
}
