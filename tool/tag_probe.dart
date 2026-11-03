// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/tags.dart';

void main(List<String> a) {
  final f = File(a[0]);
  final cover = File(a[1]).readAsBytesSync();
  writeTags(
    f,
    const Item(kind: ItemKind.song, id: 'x', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], album: 'Aashiqui 2'),
    Uint8List.fromList(cover),
  );
  final m = readMetadata(f, getImage: true);
  print('read back: ${m.title} / ${m.artist} / ${m.album} / pictures ${m.pictures.length} / duration ${m.duration}');
  exit(0);
}
