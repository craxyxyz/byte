// ignore_for_file: avoid_print
// Debug: what each player client returns for one video, and whether each
// audio format serves past its first megabyte. dart run tool/stream_probe.dart <videoId>
import 'dart:io';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/innertube_parse.dart';

import 'relay_net.dart';

Future<void> main(List<String> args) async {
  final id = args.isEmpty ? 'n_ABgnlFIcI' : args.first;
  final net = RelayNet();
  final yt = InnerTube(net);
  for (final c in playerClients) {
    try {
      final p = await yt.player(id, clients: [c]);
      final fmts = (dig(p, ['streamingData', 'adaptiveFormats']) as List).whereType<Map>().where((f) => '${f['mimeType']}'.startsWith('audio/')).toList();
      for (final f in fmts) {
        final url = f['url'] as String?;
        final len = int.tryParse('${f['contentLength'] ?? ''}');
        var probe = 'no url';
        if (url != null && len != null) {
          final r = await net.get(Uri.parse('$url&range=${len - 2048}-${len - 1}'), timeout: const Duration(seconds: 15));
          probe = 'tail ${r.status} ${r.body.length}B';
        }
        print('${c.name}: itag ${f['itag']} ${f['mimeType']} drc=${f['isDrc']} track=${(f['audioTrack'] as Map?)?['displayName']} len=$len -> $probe');
      }
    } catch (e) {
      print('${c.name}: ERROR $e');
    }
  }
  exit(0);
}
