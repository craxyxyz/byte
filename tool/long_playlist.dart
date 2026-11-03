// ignore_for_file: avoid_print
// Live: a YouTube Music playlist with more than 100 songs imports whole.
import 'dart:io';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/core/net.dart';

import 'relay_net.dart';

Future<void> main(List<String> args) async {
  final yt = InnerTube(RelayNet());
  final lists = await yt.search(args.isEmpty ? 'bollywood 90s 200 songs' : args.join(' '), SearchFilter.playlists);
  for (final l in lists.take(8)) {
    print('${l.id} | ${l.title} | ${l.subtitle}');
  }
  final big = lists.where((l) => RegExp(r'(\d{3,})\s+(songs|tracks)').hasMatch(l.subtitle ?? '')).toList();
  if (big.isEmpty) {
    print('no 100+ playlist in results');
    exit(0);
  }
  final pick = big.first;
  final id = pick.id.startsWith('VL') ? pick.id.substring(2) : pick.id;
  final l = await PlaylistReader(HttpNet(), yt).read('https://music.youtube.com/playlist?list=$id');
  print('IMPORTED "${l.name}": ${l.ready?.length} songs (listed as: ${pick.subtitle})');
  final page = await yt.playlist(id);
  print('raw rows ${page.tracks.length}, playable ${page.tracks.where((t) => t.isPlayable).length}, kinds ${page.tracks.map((t) => t.kind.name).toSet()}');
  exit(0);
}
