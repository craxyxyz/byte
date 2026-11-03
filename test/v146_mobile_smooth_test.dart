import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

// Byte © 2026 Apurba Laskar.
//
// 1.4.6 (Apurba: "phone and tablet peh bhi laggy"): on phone and tablet
// layouts a screen where nothing moves draws nothing, and a playing song's
// player / lyrics draw ~30 frames a second, not every screen refresh (it was
// 60–120/s nonstop with the player open, playing or paused).

Future<double> framesPerSec(WidgetTester tester, {int ms = 2000}) async {
  var frames = 0;
  for (var t = 0; t < ms; t += 16) {
    if (tester.binding.hasScheduledFrame) {
      frames++;
      await tester.pump(const Duration(milliseconds: 16));
    } else {
      await tester.binding.delayed(const Duration(milliseconds: 16));
    }
  }
  return frames * 1000 / ms;
}

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  test('lyrics move 30×/s while playing on every platform', () {
    expect(LyricsPace.playingStepMs, 40);
  });

  const sizes = {'phone 390x844': Size(390, 844), 'tablet 800x1280': Size(800, 1280), 'tablet 1280x800': Size(1280, 800)};
  for (final e in sizes.entries) {
    testWidgets('${e.key}: player and lyrics idle when paused, ~30 frames/s when playing', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = e.value * 2;
      addTearDown(tester.view.reset);
      final idleBefore = LyricsPane.idleAfter;
      LyricsPane.idleAfter = const Duration(hours: 1);
      addTearDown(() => LyricsPane.idleAfter = idleBefore);
      await tester.runAsync(() async {
        final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
        await sv.player.playItems(album.tracks, from: 'Test Album');
      });
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('mini')));
      await settle(tester);
      Future<void> check(String where) async {
        await tester.runAsync(() => sv.player.play());
        await settle(tester);
        // ~30/s, plus a lyric line's short glide when the line changes (the
        // test screen refreshes 60×/s; before 1.4.6 this was 62.7)
        expect(await framesPerSec(tester), lessThan(48), reason: '$where playing: not every screen refresh');
        await tester.runAsync(() => sv.player.pause());
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(await framesPerSec(tester), lessThan(1), reason: '$where paused: nothing draws');
      }

      await check('player');
      if (find.byTooltip('Lyrics').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('Lyrics').first);
        await settle(tester);
      }
      expect(find.byType(SyncedLyricsView), findsWidgets);
      await check('lyrics');
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  }
}
