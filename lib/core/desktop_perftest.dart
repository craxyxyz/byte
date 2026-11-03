import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../lyrics/lrc.dart';
import '../services.dart';
import '../ui/now_playing.dart';
import 'models.dart';

// Byte © 2026 Apurba Laskar.
//
// 1.4.5.2 desktop smoothness check (BYTE_PERFTEST=1, CI only; does nothing
// otherwise). Plays local songs with synced lyrics and a cover, then spends
// [secs] seconds in each of: Home playing, player open playing, player open
// paused, Home paused — writing frames drawn per second and the phase to
// BYTE_PERFTEST_OUT (the CI samples the app's CPU meanwhile). A screen where
// nothing moves must draw (almost) nothing.
class DesktopPerfTest {
  static Future<void> run() async {
    final env = Platform.environment;
    final f = File(env['BYTE_PERFTEST_OUT'] ?? 'perftest.jsonl');
    final secs = int.tryParse(env['BYTE_PERFTEST_SECS'] ?? '') ?? 15;
    void log(Map<String, Object?> m) => f.writeAsStringSync('${jsonEncode({'epoch': DateTime.now().millisecondsSinceEpoch, ...m})}\n', mode: FileMode.append);
    var phase = 'start';
    var frames = 0, rasterUs = 0, buildUs = 0;
    SchedulerBinding.instance.addTimingsCallback((ts) {
      frames += ts.length;
      for (final t in ts) {
        rasterUs += t.rasterDuration.inMicroseconds;
        buildUs += t.buildDuration.inMicroseconds;
      }
    });
    final tick = Timer.periodic(const Duration(seconds: 1), (_) {
      log({'phase': phase, 'frames': frames, 'rasterMs': frames == 0 ? 0 : rasterUs / frames / 1000, 'buildMs': frames == 0 ? 0 : buildUs / frames / 1000});
      frames = rasterUs = buildUs = 0;
    });
    try {
      await Future<void>.delayed(const Duration(seconds: 5));
      final files = (env['BYTE_SELFTEST_FILES'] ?? '').split(';').where((e) => e.isNotEmpty).toList();
      final cover = env['BYTE_PERFTEST_COVER'];
      final thumb = cover == null || cover.isEmpty ? null : Uri.file(cover).toString();
      final items = [
        for (final (i, path) in files.indexed)
          Item(kind: ItemKind.song, id: 'local:$path', title: 'Smoothness check song number ${i + 1} with a long title', artists: const [ArtistRef('Byte')], durationSec: 600, thumb: thumb),
      ];
      // synced lyrics with word timings, a line every 3 s
      for (final it in items) {
        Services.i.lyrics.choose(
          it,
          Lyrics.synced([
            for (var l = 0; l < 200; l++)
              LyricLine(l * 3000, 'Line $l of the smoothness check lyrics', [
                for (var w = 0; w < 7; w++) LyricWord(['Line ', '$l ', 'of ', 'the ', 'smoothness ', 'check ', 'lyrics'][w], l * 3000 + w * 400, l * 3000 + w * 400 + 380),
              ]),
          ], 'Self-test'),
        );
      }
      final p = Services.i.player;
      if (items.isNotEmpty) await p.playItems(items);
      await Future<void>.delayed(const Duration(seconds: 3));
      phase = 'home_playing';
      log({'phase': phase});
      await Future<void>.delayed(Duration(seconds: secs));
      log({'song': p.current.value?.title, 'playing': p.playing, 'error': p.error.value});
      final mini = _find(const ValueKey('mini'));
      if (mini != null) unawaited(NowPlayingScreen.open(mini));
      phase = 'player_playing';
      log({'phase': phase, 'opened': mini != null});
      await Future<void>.delayed(Duration(seconds: secs));
      await p.pause();
      phase = 'player_paused';
      log({'phase': phase});
      await Future<void>.delayed(Duration(seconds: secs));
      final np = _find(null, type: NowPlayingScreen);
      if (np != null) Navigator.of(np).maybePop();
      phase = 'home_paused';
      log({'phase': phase});
      await Future<void>.delayed(Duration(seconds: secs));
      phase = 'done';
      log({'phase': phase});
    } catch (e) {
      log({'perftest_error': '$e'});
    }
    tick.cancel();
    if (env['BYTE_PERFTEST_EXIT'] == '1') exit(0);
  }

  static Element? _find(Key? key, {Type? type}) {
    Element? hit;
    void visit(Element e) {
      if (hit != null) return;
      if ((key != null && e.widget.key == key) || (type != null && e.widget.runtimeType == type)) {
        hit = e;
        return;
      }
      e.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return hit;
  }
}
