// Byte © 2026 Apurba Laskar.
//
// 2.0.8 (desktop quality pass): plain arrow keys on a computer. With a song
// playing, ← / → seek 5 s and ↑ / ↓ turn the volume 5 %; with nothing playing
// the arrows keep moving the keyboard focus. Text fields keep their arrows.
import 'package:byte/services.dart';
import 'package:byte/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

void main() {
  group('plain arrow keys on a computer', () {
    late Services sv;
    setUp(() async {
      sv = await makeServices();
      sv.settings.autoplay = false;
    });

    Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
      await tester.sendKeyEvent(k);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('with nothing playing, the arrows do not touch the player', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
      expect(sv.player.current.value, isNull);
      final before = sv.route.volume;
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(sv.route.volume, before);
      expect(sv.player.current.value, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('with a song playing: → / ← seek 5 s, ↑ / ↓ move the volume 5 %', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      await tester.runAsync(() async {
        final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
        await sv.player.playItems(album.tracks, from: 'Test Album');
      });
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
      expect(sv.player.current.value, isNotNull);
      // from full volume: ↓ takes 5 % off, ↑ gives it back (never past 100 %)
      expect(sv.route.volume, 1.0);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(sv.route.volume, closeTo(0.95, 0.001));
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(sv.route.volume, closeTo(1.0, 0.001));
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(sv.route.volume, closeTo(1.0, 0.001), reason: 'the volume stops at 100 %');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(sv.route.volume, closeTo(0.90, 0.001));
      // ← / → move the song by 5 s
      final p0 = sv.player.position;
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(sv.player.position - p0, greaterThanOrEqualTo(const Duration(seconds: 4)));
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(sv.player.position, lessThan(p0 + const Duration(seconds: 2)));
      await tester.runAsync(() => sv.route.setVolume(1.0, playerVolume: sv.player.setAppVolume));
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    });
  });
}
