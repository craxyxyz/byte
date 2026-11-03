// © 2026 Apurba Laskar
//
// The picture the phone's lock screen, notification, car and watch show for
// the playing song: one square file on the phone, at least 720 px (1080 when
// Byte has to crop or scale it), so the system can draw it big and sharp
// even with the screen locked or the phone offline.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'cover_cache.dart';
import 'models.dart';

class LockArt {
  /// The smallest side the lock screen card is happy with.
  static const minSide = 720;

  /// The side Byte draws a cropped or scaled picture at.
  static const side = 1080;

  /// How many songs' pictures stay on the phone (newest used first).
  static int keep = 20;

  /// Where the pictures live (tests may set it; else inside the cover cache).
  static Directory? dirOverride;

  static Directory? get dir {
    if (dirOverride != null) return dirOverride;
    final c = CoverCache.dir;
    return c == null ? null : Directory('${c.path}/lock');
  }

  /// Reads one picture's bytes: phone first, then the web (tests swap it).
  static Future<Uint8List?> Function(String url) read = _read;

  /// Files in use right now (the playing song's, and the one before while the
  /// system may still be loading it). Never deleted.
  static final Set<String> pinned = {};

  static final Map<String, Future<File?>> _inflight = {};

  static String _key(String id) => sha1.convert(utf8.encode(id)).toString();

  /// The best picture made so far for [it]: full size, else a smaller stand-in.
  static File? existing(Item it) {
    final d = dir;
    if (d == null) return null;
    final k = _key(it.id);
    for (final name in ['$k.jpg', '$k.png', '$k.lo.png']) {
      final f = File('${d.path}/$name');
      if (f.existsSync() && f.lengthSync() > 0) return f;
    }
    return null;
  }

  /// True when [f] is a full-size picture (not a stand-in made offline).
  static bool isFull(File f) => !f.path.endsWith('.lo.png');

  /// The places to get [it]'s picture from, best first.
  static List<String> sources(Item it) {
    final t = it.thumb;
    if (t == null || t.isEmpty) return const [];
    if (t.contains('i.ytimg.com/vi')) {
      // maxres and hq720 are 1280×720 (a 720 px square from the middle);
      // sd and hq are 4:3 with black bars (360 and 270 px squares).
      return [for (final f in const ['maxresdefault', 'hq720', 'sddefault', 'hqdefault']) ytThumbVariant(t, f)!];
    }
    if (t.contains('googleusercontent.com') || t.contains('ggpht.com')) {
      return {resizeThumb(t, side)!, resizeThumb(t, 544)!, t}.toList();
    }
    return [t];
  }

  /// Makes (once) the square lock-screen picture for [it]. Returns the file,
  /// or null when no picture could be read at all.
  static Future<File?> make(Item it) {
    final key = it.id;
    final running = _inflight[key];
    if (running != null) return running;
    final fut = _make(it);
    _inflight[key] = fut;
    fut.whenComplete(() => _inflight.remove(key));
    return fut;
  }

  static Future<File?> _make(Item it) async {
    final d = dir;
    if (d == null) return null;
    final have = existing(it);
    if (have != null && isFull(have)) return have;
    try {
      await d.create(recursive: true);
    } catch (_) {
      return have;
    }
    final k = _key(it.id);
    for (final url in sources(it)) {
      try {
        final b = await read(url);
        if (b == null || b.isEmpty) continue;
        final codec = await ui.instantiateImageCodec(b);
        final img = (await codec.getNextFrame()).image;
        codec.dispose();
        final w = img.width, h = img.height;
        final square = (w - h).abs() <= 2;
        final full = (square ? w : CoverCache.squareCrop(w, h, letterboxed: isLetterboxedThumb(url)).width) >= minSide;
        File out;
        if (square && w >= minSide) {
          // Already what the lock screen wants: keep the original file.
          img.dispose();
          out = File('${d.path}/$k.${_isPng(b) ? 'png' : 'jpg'}');
          await _writeAtomic(out, b);
        } else {
          final src = CoverCache.squareCrop(w, h, letterboxed: isLetterboxedThumb(url));
          final rec = ui.PictureRecorder();
          ui.Canvas(rec).drawImageRect(img, src, ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.high);
          final sq = await rec.endRecording().toImage(side, side);
          final png = await sq.toByteData(format: ui.ImageByteFormat.png);
          img.dispose();
          sq.dispose();
          if (png == null) continue;
          out = File('${d.path}/$k.${full ? 'png' : 'lo.png'}');
          await _writeAtomic(out, png.buffer.asUint8List());
        }
        if (full && have != null && have.path != out.path && !pinned.contains(have.path)) {
          try {
            await have.delete();
          } catch (_) {}
        }
        unawaited(prune());
        return out;
      } catch (_) {}
    }
    return have;
  }

  static bool _isPng(Uint8List b) => b.length > 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

  /// Written beside, then moved in: the system never reads half a picture.
  static Future<void> _writeAtomic(File out, Uint8List bytes) async {
    final tmp = File('${out.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(out.path);
  }

  /// [path] is what the lock screen shows now; [previous] may still be loading.
  static void use(String path, {String? previous}) {
    pinned
      ..clear()
      ..add(path);
    if (previous != null && previous != path) pinned.add(previous);
    try {
      File(path).setLastModifiedSync(DateTime.now());
    } catch (_) {}
  }

  /// Keeps the [keep] most recently used pictures (and every pinned one).
  static Future<void> prune() async {
    final d = dir;
    if (d == null) return;
    try {
      if (!await d.exists()) return;
      final files = <(File, DateTime)>[];
      await for (final e in d.list()) {
        if (e is! File) continue;
        if (e.path.endsWith('.tmp')) {
          // a write that never finished (older than a minute)
          try {
            if (DateTime.now().difference((await e.stat()).modified) > const Duration(minutes: 1)) await e.delete();
          } catch (_) {}
          continue;
        }
        files.add((e, (await e.stat()).modified));
      }
      files.sort((a, b) => b.$2.compareTo(a.$2));
      var kept = 0;
      for (final (f, _) in files) {
        if (pinned.contains(f.path)) continue;
        if (kept < keep) {
          kept++;
          continue;
        }
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<Uint8List?> _read(String url) async {
    if (url.startsWith('file:') || url.startsWith('/')) {
      try {
        final f = url.startsWith('/') ? File(url) : File(Uri.parse(url).toFilePath());
        return await f.readAsBytes();
      } catch (_) {
        return null;
      }
    }
    return CoverCache.bytes(url);
  }
}
