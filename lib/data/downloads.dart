import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../core/streams.dart';
import 'library.dart';
import 'settings.dart';
import 'tags.dart';

enum DlState { queued, running, done, failed }

class DlTask {
  final Item item;
  DlState state;
  double progress;
  String? error;
  DlTask(this.item, {this.state = DlState.queued, this.progress = 0});
}

/// Saves songs for offline listening, with title/artist/album/cover written
/// into the file itself (M4A) and kept in the library.
class Downloads extends ChangeNotifier {
  final StreamResolver resolver;
  final Library library;
  final Settings settings;
  final Net net;
  final Map<String, DlTask> tasks = {};
  int _running = 0;
  static const maxParallel = 2;

  Downloads(this.resolver, this.library, this.settings, this.net);

  bool get supported => !kIsWeb;
  DlTask? task(String id) => tasks[id];

  Future<Directory> folder() async {
    Directory base;
    if (settings.downloadDir == 'external' && Platform.isAndroid) {
      base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
    } else {
      base = await getApplicationDocumentsDirectory();
    }
    final d = Directory('${base.path}/Byte Downloads');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  void enqueue(Iterable<Item> items) {
    if (!supported) return;
    for (final it in items) {
      if (!it.isPlayable || it.isLocal || library.isDownloaded(it.id)) continue;
      final t = tasks[it.id];
      if (t != null && (t.state == DlState.queued || t.state == DlState.running)) continue;
      tasks[it.id] = DlTask(it);
    }
    notifyListeners();
    _pump();
  }

  void _pump() {
    while (_running < maxParallel) {
      final next = tasks.values.where((t) => t.state == DlState.queued).firstOrNull;
      if (next == null) return;
      _running++;
      next.state = DlState.running;
      notifyListeners();
      _run(next).whenComplete(() {
        _running--;
        _pump();
      });
    }
  }

  /// Downloads every song of a Byte playlist and remembers it, so new songs
  /// download too when "Keep downloaded playlists updated" is on.
  Future<void> downloadPlaylist(String playlistId, List<Item> items) async {
    await library.setPlaylistDownloaded(playlistId, true);
    enqueue(items);
  }

  /// New songs in downloaded playlists (after a sync or an edit).
  void refreshPlaylists() {
    if (!supported || !settings.keepPlaylistsUpdated) return;
    final ids = library.downloadedPlaylists;
    if (ids.isEmpty) return;
    final todo = <Item>[];
    for (final p in library.playlists.where((p) => ids.contains(p.id))) {
      for (final it in p.items) {
        final t = tasks[it.id];
        if (t != null) continue; // queued, running, done, or failed (retry by hand)
        if (!library.isDownloaded(it.id)) todo.add(it);
      }
    }
    if (todo.isNotEmpty) enqueue(todo);
  }

  /// "Download on Wi-Fi only": hold here until the phone is on Wi-Fi.
  Future<void> Function() waitForWifi = _waitForWifi;

  static Future<void> _waitForWifi() async {
    final c = Connectivity();
    bool wifi(List<ConnectivityResult> r) => r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    if (wifi(await c.checkConnectivity())) return;
    await c.onConnectivityChanged.firstWhere(wifi);
  }

  Future<void> _run(DlTask t) async {
    try {
      if (settings.downloadWifiOnly) {
        t.error = 'Waiting for Wi-Fi';
        notifyListeners();
        await waitForWifi();
        t.error = null;
      }
      // M4A on every platform so tags + artwork can be written into the file.
      final s = await resolver.resolve(t.item.id, settings.downloadQuality, preferMp4: true);
      final dir = await folder();
      final safe = '${t.item.artistLine} - ${t.item.title}'.replaceAll(RegExp(r'[\\/:*?"<>|\n\r]'), '_');
      final name = safe.length > 90 ? safe.substring(0, 90) : safe;
      // "Export compatible downloads": plain "Artist - Title.m4a" names that look
      // right in other music apps (no video id in the name).
      var file = File(settings.compatibleDownloads ? '${dir.path}/$name.${s.extension}' : '${dir.path}/$name [${t.item.id}].${s.extension}');
      for (var k = 2; settings.compatibleDownloads && await file.exists() && k < 50; k++) {
        file = File('${dir.path}/$name ($k).${s.extension}');
      }
      final tmp = File('${file.path}.part');
      await fetchToFile(Uri.parse(s.url), tmp, s.contentLength, s.userAgent, (p) {
        t.progress = p;
        notifyListeners();
      });
      await tmp.rename(file.path);
      String? coverPath;
      Uint8List? cover;
      final art = t.item.thumbAt(720);
      if (art != null) {
        try {
          final r = await net.get(Uri.parse(art), timeout: const Duration(seconds: 20));
          if (r.ok && r.body.isNotEmpty) {
            cover = r.body;
            final cf = File('${dir.path}/.covers/${t.item.id}.jpg');
            await cf.parent.create(recursive: true);
            await cf.writeAsBytes(cover);
            coverPath = cf.path;
          }
        } catch (_) {}
      }
      try {
        writeTags(file, t.item, cover);
      } catch (_) {
        /* the song still plays; the library keeps its details */
      }
      await library.putDownload(
        DownloadRecord(item: t.item, path: file.path, coverPath: coverPath, bytes: await file.length(), mime: s.mime, at: DateTime.now()),
      );
      t.state = DlState.done;
      t.progress = 1;
    } catch (e) {
      t.state = DlState.failed;
      t.error = '$e';
    }
    notifyListeners();
  }

  Future<void> delete(String id) async {
    final r = library.download(id);
    if (r != null) {
      for (final p in [r.path, r.coverPath]) {
        if (p == null) continue;
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    tasks.remove(id);
    await library.removeDownloadRecord(id);
    notifyListeners();
  }

  void retry(String id) {
    final t = tasks[id];
    if (t == null) return;
    t.state = DlState.queued;
    t.error = null;
    t.progress = 0;
    notifyListeners();
    _pump();
  }

  int get totalBytes => library.downloads.fold(0, (a, r) => a + r.bytes);
}

/// Downloads [url] into [out] in 4 MB ranges (YouTube serves big files that way).
Future<void> fetchToFile(Uri url, File out, int? total, String? ua, void Function(double) onProgress) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final sink = out.openWrite();
  var got = 0;
  try {
    const chunk = 4 * 1024 * 1024;
    while (true) {
      final end = total == null ? null : (got + chunk - 1).clamp(0, total - 1);
      final req = await client.getUrl(url);
      if (ua != null) req.headers.set(HttpHeaders.userAgentHeader, ua);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$got-${end ?? ''}');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 && res.statusCode != 206) throw HttpException('download refused (${res.statusCode})');
      await for (final b in res.timeout(const Duration(seconds: 30))) {
        sink.add(b);
        got += b.length;
        if (total != null && total > 0) onProgress(got / total);
      }
      if (total == null || got >= total || res.statusCode == 200) break;
    }
  } finally {
    await sink.close();
    client.close(force: true);
  }
  if (total != null && got < total) throw const HttpException('download stopped early');
}
