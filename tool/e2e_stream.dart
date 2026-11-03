// ignore_for_file: avoid_print
// End-to-end: search the real catalogue, resolve the real audio stream with
// Byte's own resolver, then download the WHOLE file the way the player does
// (one Range request). Run: dart run tool/e2e_stream.dart [query]
import 'dart:io';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/streams.dart';

import 'relay_net.dart';

Future<void> main(List<String> args) async {
  final q = args.where((a) => !a.startsWith('--')).toList();
  final query = q.isNotEmpty ? q.join(' ') : 'Tum Hi Ho Arijit Singh';
  // Everything through the home-connection relay (this build box's own
  // address is rate-limited by YouTube; a phone talks to YouTube directly).
  final relayNet = RelayNet();
  final viaRelay = InnerTube(relayNet);
  final songs = await viaRelay.search(query, SearchFilter.songs);
  final song = songs.first;
  print('search "$query": ${songs.length} songs; first: ${song.title} — ${song.artistLine} (${song.durationSec}s) ${song.id}');
  for (final preferMp4 in [false, true]) {
    final sw = Stopwatch()..start();
    final s = await StreamResolver(viaRelay).resolve(song.id, AudioQuality.high, preferMp4: preferMp4);
    print('resolved in ${sw.elapsedMilliseconds} ms: $s, ${s.contentLength} bytes, expires ${s.expiresAt.toUtc()}');
    final r = await relayNet.get(Uri.parse(s.url), headers: {'Range': 'bytes=0-'}, timeout: const Duration(seconds: 90));
    final f = File('/tmp/byte_e2e_${song.id}.${s.extension}');
    await f.writeAsBytes(r.body);
    print('downloaded ${r.body.length} of ${s.contentLength} bytes (HTTP ${r.status}) -> ${f.path}');
  }
  exit(0);
}
