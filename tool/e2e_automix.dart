// ignore_for_file: avoid_print
// Real songs for the Automix analysis check: search the live catalogue,
// resolve with Byte's own resolver, download both formats in full.
// Run: dart run tool/e2e_automix.dart <outDir> "query 1" "query 2" ...
import 'dart:io';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/streams.dart';

import 'relay_net.dart';

Future<void> main(List<String> args) async {
  final out = Directory(args.first)..createSync(recursive: true);
  final relayNet = RelayNet();
  final yt = InnerTube(relayNet);
  for (final query in args.skip(1)) {
    try {
      final songs = await yt.search(query, SearchFilter.songs);
      final song = songs.first;
      for (final preferMp4 in [false, true]) {
        final s = await StreamResolver(yt).resolve(song.id, AudioQuality.high, preferMp4: preferMp4);
        final r = await relayNet.get(Uri.parse(s.url), headers: {'Range': 'bytes=0-'}, timeout: const Duration(seconds: 120));
        final f = File('${out.path}/${song.id}.${s.extension}');
        await f.writeAsBytes(r.body);
        print('OK\t${song.id}\t${s.extension}\t${r.body.length}/${s.contentLength}\t${song.durationSec}\t${song.title} — ${song.artistLine}');
      }
    } catch (e) {
      print('FAIL\t$query\t$e');
    }
  }
  exit(0);
}
