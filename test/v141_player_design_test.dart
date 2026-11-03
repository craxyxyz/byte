import 'package:byte/lyrics/lrc.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/glass.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/now_playing.dart';
import 'package:byte/ui/player_parts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;

// Byte 1.4.1: Apurba's reference video (2:39 PM) — mini lyric line with word
// fill, reference lyrics view, poster, and readable mini player / tab bar.
void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  List<LyricLine> lines(String lrc) => parseLrc(lrc);

  group('mini lyric line', () {
    const lrc = '[00:02.00] Raat ki roshni mein\n[00:06.00] Tera naam likha hai\n[00:10.00] \n[00:20.00] Bas tu hi basa hai\n';

    test('shows the line being sung; an instrumental gap keeps the last sung line; before the first line: the first line, unlit', () {
      final c = LyricsClock(lines(lrc));
      expect(c.lines[2].isBreak, isTrue);
      expect(debugMiniLineFor(c, 500), -1, reason: 'before line 0: shows line 0, nothing lit');
      expect(debugMiniLineFor(c, 2500), 0);
      expect(debugMiniLineFor(c, 7000), 1);
      expect(debugMiniLineFor(c, 15000), 1, reason: 'in the gap the last sung line stays');
      expect(debugMiniLineFor(c, 20500), 3);
    });

    test('fills word by word on the same clock (and lead) as the lyrics screen', () {
      final c = LyricsClock(lines(lrc));
      final f = [for (var ms = 5850; ms <= 9000; ms += 150) miniLineFill(c, 1, ms)];
      for (var i = 1; i < f.length; i++) {
        expect(f[i], greaterThanOrEqualTo(f[i - 1]));
      }
      expect(miniLineFill(c, 1, 5800), 0, reason: 'not lit before the line starts (minus the 150 ms lead)');
      expect(miniLineFill(c, 1, 9900), 1);
      final mid = miniLineFill(c, 1, 7200);
      expect(mid, inInclusiveRange(0.25, 0.75));
      // same as the big screen's word fill at the same moment
      final fills = c.wordFill(1, 7200 + c.leadMs);
      expect(fills.first, 1.0);
      expect(fills.last, lessThan(1.0));
    });

    test('real word timings drive the fill exactly', () {
      final c = LyricsClock(parseLrc('[00:01.00]<00:01.00>Tum <00:02.00>hi <00:03.00>ho<00:04.00>\n[00:06.00]next'));
      expect(c.lines.first.words, isNotNull);
      expect(miniLineFill(c, 0, 2000 - c.leadMs), closeTo(4 / 9, 0.01), reason: '"Tum " done, "hi " starting');
    });

    test('music-note lines are instrumental gaps (shown as dots)', () {
      expect(const LyricLine(1000, '♪').isBreak, isTrue);
      expect(const LyricLine(1000, ' ♫ ♪ ').isBreak, isTrue);
      expect(const LyricLine(1000, '…').isBreak, isTrue);
      expect(const LyricLine(1000, 'Tum hi ho').isBreak, isFalse);
    });

    test('word-by-word fill is on by default', () {
      expect(sv.settings.lyricsWordFill, isTrue);
    });
  });

  group('readable glass (mini player, tab bar)', () {
    test('white text on the mini player tint reads at >= 7:1 over a white page, artist line >= 4.5:1, for any cover colour', () {
      for (final art in const [Color(0xFFFFFF00), Color(0xFFFFFFFF), Color(0xFFFF66AA), Color(0xFF00E5FF), Color(0xFF7CFC00), Color(0xFF000000), Color(0xFF3D2C8D)]) {
        final tint = ReadableGlass.miniTint(art);
        expect(tint.a, closeTo(ReadableGlass.miniAlpha, 0.01));
        for (final page in const [Colors.white, Colors.black, Color(0xFFFFD54F)]) {
          final bg = ReadableGlass.over(tint, page);
          expect(ReadableGlass.contrast(Colors.white, bg), greaterThanOrEqualTo(7.0), reason: '$art over $page');
          final artist = ReadableGlass.over(ReadableGlass.miniSecondary, bg);
          expect(ReadableGlass.contrast(artist, bg), greaterThanOrEqualTo(4.5), reason: 'artist line, $art over $page');
        }
      }
    });

    test('tab bar labels keep >= 4.5:1 over white and black pages, light and dark', () {
      for (final dark in [false, true]) {
        final label = dark ? Colors.white : Colors.black;
        for (final page in const [Colors.white, Colors.black, Color(0xFFE91E63)]) {
          final bg = ReadableGlass.over(ReadableGlass.navTint(dark), page);
          expect(ReadableGlass.contrast(ReadableGlass.navSecondary(dark), bg), greaterThanOrEqualTo(4.5), reason: 'dark=$dark over $page');
          expect(ReadableGlass.contrast(label, bg), greaterThanOrEqualTo(4.5));
        }
      }
    });
  });

  group('poster geometry', () {
    test('390x844: square cover from the top, title just under it, controls get >= 440 px', () {
      const size = Size(390, 844);
      const pad = EdgeInsets.only(top: 44, bottom: 24);
      final g = posterGeometry(size, pad);
      expect(g.cover, 390);
      expect(g.titleTop, lessThanOrEqualTo(g.cover + size.height * 0.03 + 0.1));
      expect(g.titleTop, greaterThan(g.cover - 20));
      expect(size.height - pad.bottom - g.titleTop, greaterThanOrEqualTo(440));
    });
    test('short phone 360x640: the title moves into the fade so the controls still fit', () {
      const size = Size(360, 640);
      const pad = EdgeInsets.only(top: 24, bottom: 0);
      final g = posterGeometry(size, pad);
      expect(size.height - pad.bottom - g.titleTop, greaterThanOrEqualTo(440 - 0.1));
    });
  });

  testWidgets('player: mini lyric line under the title, tap opens the lyrics; mini player keeps white text on its own tint', (tester) async {
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = false;
    addTearDown(() => sv.settings.lyricsAutoFullScreen = true);
    await openPlayer(tester, sv);
    expect(find.byKey(const ValueKey('mini-lyric')), findsOneWidget);
    // it sits between the title and the progress bar
    final lyricY = tester.getCenter(find.byKey(const ValueKey('mini-lyric'))).dy;
    expect(lyricY, lessThan(tester.getTopLeft(find.byType(SeekBar)).dy));
    expect(find.byType(MiniLyricFill), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mini-lyric')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(LyricsPane), findsOneWidget);
    // lyrics header: no star there any more (Like lives in ⋯)
    expect(find.byTooltip('More'), findsWidgets);
    await closeAll(tester, sv);
  });

  testWidgets('glass bars paint their tint (the colour is not lost under the liquid sheen)', (tester) async {
    addTearDown(tester.view.reset);
    sv.settings.liquidGlass = true;
    await openPlayer(tester, sv);
    // back to the shell: close the player
    await tester.tap(find.byTooltip('Close'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final tints = tester.widgetList<DecoratedBox>(find.byKey(const ValueKey('glass-tint')));
    expect(tints, isNotEmpty);
    for (final d in tints) {
      final b = d.decoration as BoxDecoration;
      expect(b.color, isNotNull);
      expect(b.gradient, isNull, reason: 'a gradient in the same decoration would replace the tint');
    }
    expect(find.byKey(const ValueKey('mini-glass')), findsOneWidget);
    await closeAll(tester, sv);
  });
}
