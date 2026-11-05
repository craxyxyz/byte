// Byte 2.0 © 2026 Apurba Laskar.
//
// "Remove from cache" in the song menu: deletes this song's audio from the
// phone (the downloaded copy and Automix's fetched copy). The song itself
// stays in the library, playlists and history, and plays again by streaming.
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../services.dart';

class CacheRemoval {
  final int bytes;
  final bool hadDownload;
  final bool hadFetched;
  const CacheRemoval({this.bytes = 0, this.hadDownload = false, this.hadFetched = false});
  bool get nothing => !hadDownload && !hadFetched;

  /// The words for a toast.
  String get message => nothing ? 'Nothing saved on this phone for this song' : 'Removed from cache · ${formatBytes(bytes)} freed';
}

String formatBytes(int b) {
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(b >= 10 * (1 << 20) ? 0 : 1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).round()} KB';
  return '$b B';
}

/// Is there anything of [it] saved on this phone (a download or Automix's copy)?
bool hasCachedAudio(Services s, Item it) {
  if (kIsWeb || it.isLocal) return false;
  final dl = s.library.download(it.id);
  if (dl != null && File(dl.path).existsSync()) return true;
  return s.automix?.cachedFile(it.id) != null;
}

/// Deletes the downloaded and the fetched copy of [it]. A song that is playing
/// from one of those files is reloaded from the network at the same spot.
Future<CacheRemoval> removeSongCache(Services s, Item it) async {
  if (kIsWeb || it.isLocal) return const CacheRemoval();
  var bytes = 0;
  var hadDownload = false, hadFetched = false;
  final wasOnFile = s.player.current.value?.id == it.id && s.player.playingFromFile;
  final dl = s.library.download(it.id);
  if (dl != null) {
    for (final p in [dl.path, dl.coverPath]) {
      if (p == null) continue;
      try {
        final f = File(p);
        if (f.existsSync()) bytes += f.lengthSync();
      } catch (_) {}
    }
    hadDownload = true;
    await s.downloads.delete(it.id);
  }
  final fetched = await s.automix?.evict(it.id) ?? 0;
  if (fetched > 0) {
    hadFetched = true;
    bytes += fetched;
  }
  if (wasOnFile && (hadDownload || hadFetched)) {
    try {
      await s.player.reloadCurrent();
    } catch (_) {}
  }
  return CacheRemoval(bytes: bytes, hadDownload: hadDownload, hadFetched: hadFetched);
}
