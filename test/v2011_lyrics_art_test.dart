// Byte © 2026 Apurba Laskar.
//
// 2.0.11 (Apurba, Nov 12): on a tablet or a laptop (a wide screen, 820 px and
// up) the lyrics page keeps the song's cover beside the lyrics, also in
// full-screen lyrics, where only the controls fold away. A phone keeps the
// layout it had.
import 'package:byte/services.dart';
import 'package:byte/ui/app_fullscreen.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/now_playing.dart' show SeekBar;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;

class _NoWindow implements WindowFullscreen {
  @override
  Future<void> set(bool on) async {}
}

const _art = ValueKey('np-wide-art');
const _folded = ValueKey('np-wide-controls-folded');

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });
  setUp(() {
    LyricsPane.idle.value = false;
    AppFullscreen.window = _NoWindow();
    AppFullscreen.active.value = false;
    sv.settings.lyricsAutoFullScreen = true;
  });

  // Five quiet seconds: the lyrics go full screen (4.5 s idle).
  Future<void> quietFiveSeconds(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('tablet landscape: the cover sits beside the lyrics, controls on', (tester) async {
    addTearDown(tester.view.reset);
    await openPlayer(tester, sv, size: const Size(1280, 800));
    expect(LyricsPane.idle.value, isFalse);
    final art = tester.getRect(find.byKey(_art));
    final lyrics = tester.getRect(find.byType(LyricsPane));
    expect(art.width, greaterThan(250), reason: 'a real cover, not a sliver');
    expect(art.right, lessThanOrEqualTo(lyrics.left + 1), reason: 'the cover is left of the lyrics');
    expect(find.byType(SeekBar), findsOneWidget);
    await closeAll(tester, sv);
  });

  testWidgets('tablet landscape: full-screen lyrics keep the cover beside them and fold only the controls', (tester) async {
    addTearDown(tester.view.reset);
    await openPlayer(tester, sv, size: const Size(1280, 800));
    await quietFiveSeconds(tester);
    expect(LyricsPane.idle.value, isTrue);
    expect(find.byType(SeekBar), findsNothing, reason: 'controls folded');
    expect(find.byKey(_folded), findsOneWidget);
    expect(find.byKey(_art), findsOneWidget, reason: 'the picture stays on the lyrics page');
    final art = tester.getRect(find.byKey(_art));
    final lyrics = tester.getRect(find.byType(LyricsPane));
    expect(art.width, greaterThan(250));
    expect(art.right, lessThanOrEqualTo(lyrics.left + 1), reason: 'picture beside the lyrics');
    expect(lyrics.width, greaterThan(300), reason: 'the lyrics keep their column');
    // a touch brings the controls back, the picture never leaves
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(LyricsPane.idle.value, isFalse);
    expect(find.byType(SeekBar), findsOneWidget);
    expect(find.byKey(_art), findsOneWidget);
    await closeAll(tester, sv);
  });

  testWidgets('a portrait tablet (820 px wide) gets the same wide layout', (tester) async {
    addTearDown(tester.view.reset);
    await openPlayer(tester, sv, size: const Size(820, 1180));
    await quietFiveSeconds(tester);
    expect(find.byKey(_folded), findsOneWidget);
    final art = tester.getRect(find.byKey(_art));
    expect(art.right, lessThanOrEqualTo(tester.getRect(find.byType(LyricsPane)).left + 1));
    await closeAll(tester, sv);
  });

  testWidgets('phone (390 px): the lyrics page is unchanged, full width, no side picture', (tester) async {
    addTearDown(tester.view.reset);
    await openPlayer(tester, sv, size: const Size(390, 844));
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_art), findsNothing);
    expect(find.byKey(_folded), findsNothing);
    expect(tester.getSize(find.byType(LyricsPane)).width, closeTo(390, 1));
    await quietFiveSeconds(tester);
    expect(LyricsPane.idle.value, isTrue);
    expect(find.byKey(_art), findsNothing);
    expect(tester.getSize(find.byType(LyricsPane)).width, closeTo(390, 1));
    await closeAll(tester, sv);
  });

  testWidgets('just under the wide breakpoint (819 px) is still the phone layout', (tester) async {
    addTearDown(tester.view.reset);
    await openPlayer(tester, sv, size: const Size(819, 1000));
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_art), findsNothing);
    await closeAll(tester, sv);
  });
}
