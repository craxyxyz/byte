import 'dart:async';
import 'dart:convert';
import 'dart:io' hide BytesBuilder;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Song covers kept on the phone, so a cover seen once shows instantly next
/// time (and offline). Oldest-used files are dropped past [maxBytes].
class CoverCache {
  static Directory? dir;
  static int maxBytes = 150 * 1024 * 1024;
  static int _written = 0;
  static final Map<String, Future<Uint8List?>> _inflight = {};

  /// Downloads one picture (tests swap it).
  static Future<Uint8List?> Function(String url) fetch = _download;

  static Future<void> init(Directory base) async {
    final d = Directory('${base.path}/covers');
    try {
      await d.create(recursive: true);
      dir = d;
      unawaited(trim());
    } catch (_) {}
  }

  static File? fileFor(String url) {
    final d = dir;
    if (d == null) return null;
    return File('${d.path}/${sha1.convert(utf8.encode(url))}.img');
  }

  /// The picture's bytes: from the phone when it has them, else downloaded
  /// (once, however many widgets ask at the same time) and kept.
  static Future<Uint8List?> bytes(String url) {
    final f = _inflight[url];
    if (f != null) return f;
    final fut = _get(url);
    _inflight[url] = fut;
    fut.whenComplete(() => _inflight.remove(url));
    return fut;
  }

  static Future<Uint8List?> _get(String url) async {
    final f = fileFor(url);
    if (f != null) {
      try {
        if (await f.exists()) {
          final b = await f.readAsBytes();
          if (b.isNotEmpty) {
            unawaited(f.setLastModified(DateTime.now()).catchError((_) {}));
            return b;
          }
        }
      } catch (_) {}
    }
    Uint8List? b;
    for (var i = 0; i < 2 && b == null; i++) {
      try {
        b = await fetch(url);
      } catch (_) {
        b = null;
      }
    }
    if (b != null && b.isNotEmpty && f != null) {
      try {
        await f.writeAsBytes(b, flush: false);
        _written += b.length;
        if (_written > 20 * 1024 * 1024) {
          _written = 0;
          unawaited(trim());
        }
      } catch (_) {}
    }
    return b;
  }

  /// Fetches a cover ahead of time (the next songs in the queue).
  static Future<void> prefetch(String? url) async {
    if (url == null || url.isEmpty || url.startsWith('/') || url.startsWith('file:') || dir == null) return;
    try {
      await bytes(url);
    } catch (_) {}
  }

  /// Drops the least recently used covers once the folder is over [maxBytes].
  static Future<void> trim() async {
    final d = dir;
    if (d == null) return;
    try {
      final files = <(File, int, DateTime)>[];
      await for (final e in d.list()) {
        if (e is File) {
          final st = await e.stat();
          files.add((e, st.size, st.modified));
        }
      }
      var total = files.fold<int>(0, (a, f) => a + f.$2);
      if (total <= maxBytes) return;
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final f in files) {
        if (total <= maxBytes * 0.8) break;
        try {
          await f.$1.delete();
          total -= f.$2;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// The part of a [w]×[h] picture to show as a square: the centre of the
  /// picture itself (inside the black bars of a 4:3 YouTube frame).
  static ui.Rect squareCrop(int w, int h, {bool letterboxed = false}) {
    var top = 0.0, height = h.toDouble();
    if (letterboxed) {
      height = w * 9 / 16;
      top = (h - height) / 2;
    }
    final side = height < w ? height : w.toDouble();
    return ui.Rect.fromLTWH((w - side) / 2, top + (height - side) / 2, side, side);
  }

  static final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  static Future<Uint8List?> _download(String url) async {
    final req = await _http.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 15));
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final b = BytesBuilder(copy: false);
    await for (final c in res.timeout(const Duration(seconds: 20))) {
      b.add(c);
    }
    return b.takeBytes();
  }
}

/// An [ImageProvider] for a web cover that goes through [CoverCache].
@immutable
class CachedCover extends ImageProvider<CachedCover> {
  final String url;
  const CachedCover(this.url);

  @override
  Future<CachedCover> obtainKey(ImageConfiguration configuration) => SynchronousFuture<CachedCover>(this);

  @override
  ImageStreamCompleter loadImage(CachedCover key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final b = await CoverCache.bytes(url);
    if (b == null || b.isEmpty) {
      PaintingBinding.instance.imageCache.evict(this);
      throw StateError('Cover could not be loaded: $url');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(b));
  }

  @override
  bool operator ==(Object other) => other is CachedCover && other.url == url;
  @override
  int get hashCode => url.hashCode;
  @override
  String toString() => 'CachedCover("$url")';
}
