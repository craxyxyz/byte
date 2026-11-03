import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../core/models.dart';

/// Writes title / artist / album / cover into a downloaded M4A.
void writeTags(File f, Item it, Uint8List? cover) {
  updateMetadata(f, (m) {
    m.setTitle(it.title);
    if (it.artistLine.isNotEmpty) m.setArtist(it.artistLine);
    if (it.album != null) m.setAlbum(it.album!);
    if (cover != null) m.setPictures([Picture(cover, 'image/jpeg', PictureType.coverFront)]);
  });
}
