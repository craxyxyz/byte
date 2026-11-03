import 'dart:async';
import 'dart:io' show stdout;

import 'package:flutter/scheduler.dart';

// Byte © 2026 Apurba Laskar.
//
// 1.4.5.1: a tiny frame meter for the computer apps (BYTE_FRAME_LOG=1):
// every 2 s, how many frames were drawn and how long they took. A screen that
// isn't changing should draw (almost) none.
class FrameLog {
  static Timer? _t;
  static int frames = 0;
  static int _buildUs = 0, _rasterUs = 0, _worstUs = 0;

  static void start() {
    if (_t != null) return;
    SchedulerBinding.instance.addTimingsCallback(_on);
    _t = Timer.periodic(const Duration(seconds: 2), (_) {
      final n = frames;
      stdout.writeln('[frames] ${(n / 2).toStringAsFixed(1)}/s'
          ' build ${n == 0 ? 0 : (_buildUs / n / 1000).toStringAsFixed(2)} ms'
          ' raster ${n == 0 ? 0 : (_rasterUs / n / 1000).toStringAsFixed(2)} ms'
          ' worst ${(_worstUs / 1000).toStringAsFixed(1)} ms'
          ' transient ${SchedulerBinding.instance.transientCallbackCount}');
      frames = 0;
      _buildUs = _rasterUs = _worstUs = 0;
    });
  }

  static void _on(List<FrameTiming> ts) {
    for (final t in ts) {
      frames++;
      _buildUs += t.buildDuration.inMicroseconds;
      _rasterUs += t.rasterDuration.inMicroseconds;
      final total = t.totalSpan.inMicroseconds;
      if (total > _worstUs) _worstUs = total;
    }
  }
}
