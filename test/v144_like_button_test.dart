// Byte © 2026 Apurba Laskar
// 1.4.4 (Apurba, 6:26 PM): a Like heart just left of ⋯ on Now Playing.
import 'package:byte/services.dart';
import 'package:byte/ui/now_playing.dart';
import 'package:byte/app.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/library_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.lyricsAutoFullScreen = false;
  });

  Finder heart() => find.byKey(const ValueKey('np-like'));
  Finder more() => find.byKey(const ValueKey('np-more'));
  Future<void> pumps(WidgetTester tester, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    testWidgets('heart sits just left of ⋯, same size, toggles the liked state, follows the song (${size.width.toInt()} px)', (tester) async {
      addTearDown(tester.view.reset);
      await openPlayer(tester, sv, size: size);
      final first = sv.player.current.value!;
      for (final it in sv.library.likes.toList()) {
        await tester.runAsync(() => sv.library.setLiked(it, false));
      }
      await pumps(tester);

      expect(heart(), findsOneWidget);
      expect(more(), findsOneWidget);
      final h = tester.getRect(heart()), m = tester.getRect(more());
      expect(h.right, lessThanOrEqualTo(m.left), reason: 'heart is left of ⋯');
      expect(m.left - h.right, lessThan(16), reason: 'right beside it');
      expect((h.center.dy - m.center.dy).abs(), lessThan(0.5), reason: 'same row, same centre');
      expect(h.size, m.size, reason: 'same size as ⋯');
      expect(tester.takeException(), isNull, reason: 'no overflow in the title row');

      // not liked: outline + "Like"
      expect(find.descendant(of: heart(), matching: find.byIcon(Icons.favorite_border_rounded)), findsOneWidget);
      expect(find.byTooltip(likeLabel), findsWidgets);
      expect(sv.library.isLiked(first.id), isFalse);

      await tester.tap(heart());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await pumps(tester);
      expect(sv.library.isLiked(first.id), isTrue);
      expect(sv.library.likes.map((i) => i.id), contains(first.id), reason: 'Liked Songs list has it');
      final filled = tester.widget<Icon>(find.descendant(of: heart(), matching: find.byIcon(Icons.favorite_rounded)));
      expect(filled.color, isNotNull);
      expect(find.byTooltip(unlikeLabel), findsWidgets);

      // next song: the heart shows that song's own state (not liked)
      await tester.runAsync(() => sv.player.skipToNext());
      await pumps(tester);
      final second = sv.player.current.value!;
      expect(second.id, isNot(first.id));
      expect(find.descendant(of: heart(), matching: find.byIcon(Icons.favorite_border_rounded)), findsOneWidget);

      // liked elsewhere (⋯ menu / mini player / another screen): the heart fills at once
      await tester.runAsync(() => sv.library.setLiked(second, true));
      await pumps(tester, 2);
      expect(find.descendant(of: heart(), matching: find.byIcon(Icons.favorite_rounded)), findsOneWidget);

      // back to the first: still liked; unlike it from the heart, the list drops it
      await tester.runAsync(() => sv.player.skipToPrevious());
      await pumps(tester);
      if (sv.player.current.value!.id == first.id) {
        expect(find.descendant(of: heart(), matching: find.byIcon(Icons.favorite_rounded)), findsOneWidget);
        await tester.tap(heart());
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await pumps(tester);
        expect(sv.library.isLiked(first.id), isFalse);
        expect(sv.library.likes.map((i) => i.id), isNot(contains(first.id)));
      }
      await tester.runAsync(() => sv.library.setLiked(second, false));
      await closeAll(tester, sv);
    });
  }

  testWidgets('a long title ellipsizes/scrolls inside its space; the heart and ⋯ stay on screen', (tester) async {
    addTearDown(tester.view.reset);
    await openPlayer(tester, sv, size: const Size(320, 700));
    await pumps(tester);
    expect(tester.takeException(), isNull);
    final m = tester.getRect(more());
    expect(m.right, lessThanOrEqualTo(320));
    expect(tester.getRect(heart()).left, greaterThan(100));
    await closeAll(tester, sv);
  });

  testWidgets('Liked Songs page lists a song liked with the heart', (tester) async {
    addTearDown(tester.view.reset);
    await openPlayer(tester, sv);
    final it = sv.player.current.value!;
    if (sv.library.isLiked(it.id)) await tester.runAsync(() => sv.library.setLiked(it, false));
    await pumps(tester);
    await tester.tap(heart());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await pumps(tester);
    expect(sv.library.likes.first.id, it.id, reason: 'newest on top of Liked Songs');
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const ByteApp());
    await pumps(tester);
    pushInCurrentTab!(const LikedScreen());
    await pumps(tester, 8);
    expect(find.text('Liked Songs'), findsWidgets);
    expect(find.text(it.title), findsWidgets);
    await tester.runAsync(() => sv.library.setLiked(it, false));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
