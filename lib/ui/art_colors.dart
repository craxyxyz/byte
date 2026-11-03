import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/cover_cache.dart';

/// Colours pulled from album art: drives the app accent and the
/// now-playing / lyrics backgrounds.
class ArtPalette {
  final Color primary;
  final Color secondary;
  final Color tertiary;
  const ArtPalette(this.primary, this.secondary, this.tertiary);
  static const fallback = ArtPalette(Color(0xFF3D2C8D), Color(0xFF7C5CFF), Color(0xFFB0306A));
  List<Color> get list => [primary, secondary, tertiary];
}

final Map<String, ArtPalette> _cache = {};

Future<Uint8List?> _bytes(String url) async {
  try {
    if (url.startsWith('file:')) return await File(Uri.parse(url).toFilePath()).readAsBytes();
    if (url.startsWith('/')) return await File(url).readAsBytes();
    // 1.4.1: the same picture cache the covers use (downloaded once, kept)
    return await CoverCache.bytes(url).timeout(const Duration(seconds: 10));
  } catch (_) {
    return null;
  }
}

Future<ArtPalette> paletteFor(String? url) async {
  if (url == null) return ArtPalette.fallback;
  final hit = _cache[url];
  if (hit != null) return hit;
  final data = await _bytes(url);
  if (data == null) return ArtPalette.fallback;
  try {
    final codec = await ui.instantiateImageCodec(data, targetWidth: 24, targetHeight: 24);
    final frame = await codec.getNextFrame();
    final bd = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return ArtPalette.fallback;
    final p = paletteFromPixels(bd.buffer.asUint8List());
    _cache[url] = p;
    return p;
  } catch (_) {
    return ArtPalette.fallback;
  }
}

/// Picks three pleasing colours from raw RGBA pixels (pure, unit-testable).
ArtPalette paletteFromPixels(Uint8List rgba) {
  final buckets = <int, List<int>>{}; // hue bucket -> [count, r, g, b, satSum]
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final c = Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
    final h = HSVColor.fromColor(c);
    if (h.value < 0.12) continue;
    final key = (h.hue / 24).floor() * 4 + (h.saturation * 3.99).floor();
    final b = buckets.putIfAbsent(key, () => [0, 0, 0, 0, 0]);
    b[0]++;
    b[1] += rgba[i];
    b[2] += rgba[i + 1];
    b[3] += rgba[i + 2];
    b[4] += (h.saturation * 100).round();
  }
  if (buckets.isEmpty) return ArtPalette.fallback;
  final scored = buckets.values.map((b) {
    final n = b[0];
    final col = Color.fromARGB(255, b[1] ~/ n, b[2] ~/ n, b[3] ~/ n);
    final sat = b[4] / n / 100;
    return (col, n * (0.35 + sat));
  }).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  Color tune(Color c, double minS, double v) {
    final h = HSVColor.fromColor(c);
    return h.withSaturation(math.max(h.saturation, minS).clamp(0.0, 1.0)).withValue(v).toColor();
  }

  final first = scored[0].$1;
  Color pick(int i, Color fallback) => i < scored.length ? scored[i].$1 : fallback;
  final second = pick(1, HSVColor.fromColor(first).withHue((HSVColor.fromColor(first).hue + 30) % 360).toColor());
  final third = pick(2, HSVColor.fromColor(first).withHue((HSVColor.fromColor(first).hue + 320) % 360).toColor());
  return ArtPalette(tune(first, 0.35, 0.42), tune(second, 0.3, 0.55), tune(third, 0.3, 0.32));
}
