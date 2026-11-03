// Byte © 2026 Apurba Laskar
// 1.4.4 (Apurba, 6:40 PM: "By default romanized open lyrics rahega"):
// lyrics in another script (Tamil, Urdu…) open in Roman letters only, one
// column, same words and word fill; Both and Song's own stay as picks and a
// hand pick is remembered. 1.4.3's automatic dual look is not a pick.
import 'package:byte/app.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/settings.dart';
import 'package:byte/lyrics/dual.dart';
import 'package:byte/lyrics/lrc.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/now_playing.dart' show SeekBar;
import 'package:byte/ui/player_parts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

const _tamilLrc = '[00:01.00]நான் உன்னை பார்த்தேன்\n[00:05.00]வானம் நீலமாக இருக்கிறது\n[00:09.00]என் இதயம் பாடுகிறது\n[00:13.00]நீ என் அருகில் வா\n';
const _urduLrc = '[00:01.00]دل کی بات سنو\n[00:05.00]آسمان نیلا ہے\n[00:09.00]میں تمہیں دیکھتا ہوں\n[00:13.00]تم میرے پاس آؤ\n';

Item _song(String id, String title) => Item(kind: ItemKind.song, id: id, title: title, artists: const [ArtistRef('Test Artist')], durationSec: 200);

Lyrics _lyr(String lrc) => Lyrics.synced(parseLrc(lrc), 'Open lyrics');

void main() {
  late Services sv;
  var lrc = _tamilLrc;
  setUpAll(() async {
    // no other versions of these made-up songs on the lyric library: the Roman
    // words are Byte's own reading
    sv = await makeServices(net: FakeNet((r, body) => r.url.toString().contains('lrclib') ? jsonRes({}, 404) : catalogue(r, body)));
    sv.settings.autoplay = false;
  });
  setUp(() {
    sv.settings.lyricsLook = null;
    sv.settings.lyricsScript = 'latin';
    sv.lyrics
      ..order = (() => ['addons'])
      ..off = (() => {'lrclib', 'kugou', 'ytm', 'ytcaptions', 'files', 'musixmatch'})
      ..addonLyrics = ((_) async => (parseLrc(lrc), null, 'Open lyrics'));
  });
  tearDownAll(() => sv.wireSources());

  Future<void> close(WidgetTester tester) async {
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> openPane(WidgetTester tester, Item it, {Size size = const Size(390, 844)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.runAsync(() => sv.player.playItems([it]));
    await tester.runAsync(() => sv.player.seek(const Duration(milliseconds: 5500)));
    await tester.runAsync(() => sv.player.pause());
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(backgroundColor: Colors.black, body: LyricsPane()),
      ),
    );
    await settle(tester);
    await settle(tester);
  }

  Finder txt(String s) => find.textContaining(s, findRichText: true);

  // first: Hive writes made inside a widget test's fake clock queue up
  // behind real ones, so the box is read and written here before any of them
  testWidgets('migration: a look saved without the hand-pick mark (1.4.3 auto dual) → Romanized; a hand pick survives', (tester) async {
    await tester.runAsync(() async {
      final box = await Hive.openBox('settings');
      await box.put('lyricsLook', 'dual');
      await box.put('lyricsLookManual', false);
      await box.delete('lyrLook144');
      final s1 = Settings();
      await s1.open();
      expect(s1.lyricsLook, isNull);
      expect(box.get('lyricsLook'), isNull);
      expect(defaultLookFor(_lyr(_tamilLrc), s1.lyricsScript, picked: s1.lyricsLook), LyricsLook.romanized);
      // and an old "dual" with no mark at all
      await box.put('lyricsLook', 'dual');
      await box.delete('lyricsLookManual');
      await box.delete('lyrLook144');
      final s2 = Settings();
      await s2.open();
      expect(s2.lyricsLook, isNull);
      // a hand pick (marked) survives the migration
      await box.put('lyricsLook', 'dual');
      await box.put('lyricsLookManual', true);
      await box.delete('lyrLook144');
      final s3 = Settings();
      await s3.open();
      expect(s3.lyricsLook, 'dual');
      expect(defaultLookFor(_lyr(_urduLrc), s3.lyricsScript, picked: s3.lyricsLook), LyricsLook.dual);
      s3.lyricsLook = null;
    });
  });

  test('defaultLookFor: Romanized for Tamil and Urdu; a hand pick wins; English stays', () {
    expect(defaultLookFor(_lyr(_tamilLrc), 'latin'), LyricsLook.romanized);
    expect(defaultLookFor(_lyr(_urduLrc), 'latin'), LyricsLook.romanized);
    expect(defaultLookFor(_lyr(_urduLrc), 'hindi'), LyricsLook.romanized);
    expect(defaultLookFor(_lyr(_tamilLrc), 'latin', picked: 'dual'), LyricsLook.dual);
    expect(defaultLookFor(_lyr(_tamilLrc), 'latin', picked: 'original'), LyricsLook.original);
    expect(defaultLookFor(_lyr(_tamilLrc), 'original'), LyricsLook.original);
    expect(defaultLookFor(_lyr('[00:01.00]Baby I love you\n'), 'latin', picked: 'dual'), LyricsLook.original);
    // Romanized = the dual look's Roman words, word timings kept
    final r = lyricsInLook(_lyr(_tamilLrc), LyricsLook.romanized);
    final d = buildDual(_lyr(_tamilLrc)).roman;
    expect(r.lines.map((l) => l.text), d.lines.map((l) => l.text));
    expect(r.lines.first.text, isNot(contains('நான்')));
  });

  for (final c in [('Tamil', _tamilLrc, 'பார்த்தேன்', 'lyrT01'), ('Urdu', _urduLrc, 'بات', 'lyrU01')]) {
    for (final size in const [Size(390, 844), Size(1280, 800)]) {
      testWidgets('${c.$1} opens Romanized by default at ${size.width.toInt()}: one column, Roman shown, original hidden', (tester) async {
        addTearDown(tester.view.reset);
        lrc = c.$2;
        await openPane(tester, _song('${c.$4}${size.width.toInt()}', 'Song'), size: size);
        final roman = buildDual(_lyr(c.$2)).roman.lines;
        // the Roman words (Byte's own reading, or a Roman version of the song when its words match)
        final shown = LyricsPane.shown!;
        expect(shown.kind, LyricsKind.synced);
        expect(shown.lines.every((l) => !needsDualText(l.text)), isTrue, reason: 'Roman letters only: ${shown.lines.map((l) => l.text)}');
        expect(shown.lines.length, roman.length);
        final onScreen = tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).join(' | ');
        expect(onScreen, contains(shown.lines.first.text.split(' ').first), reason: onScreen);
        expect(onScreen, contains(roman[1].words!.first.text.trim()), reason: 'the line being sung, word by word (word fill): $onScreen');
        expect(txt('Romanized · Open lyrics'), findsOneWidget);
        expect(needsDualText(onScreen), isFalse, reason: 'the original script is hidden in the Romanized look: $onScreen');
        expect(txt(c.$3), findsNothing);
        expect(find.byKey(const ValueKey('dual-stack0')), findsNothing);
        expect(find.byKey(const ValueKey('dual-cols0')), findsNothing);
        expect(sv.settings.lyricsLook, isNull, reason: 'the default is not saved as a pick');
        await close(tester);
      });
    }
  }

  testWidgets('the mini line under the cover shows the Roman words', (tester) async {
    addTearDown(tester.view.reset);
    lrc = _tamilLrc;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    await tester.runAsync(() => sv.player.playItems([_song('lyrMini1', 'Song')]));
    await tester.runAsync(() => sv.player.seek(const Duration(milliseconds: 5500)));
    await tester.runAsync(() => sv.player.pause());
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: NextLyricLine()),
        ),
      ),
    );
    await settle(tester);
    await settle(tester);
    final roman = buildDual(_lyr(_tamilLrc)).roman.lines;
    expect(txt(roman[1].text), findsOneWidget);
    expect(txt('வானம்'), findsNothing);
    await close(tester);
  });

  testWidgets('a hand pick of Both, then Song\'s own, is kept for the next song and a fresh launch', (tester) async {
    addTearDown(tester.view.reset);
    lrc = _tamilLrc;
    await openPane(tester, _song('lyrPick1', 'Song'));
    await tester.tap(find.byKey(const ValueKey('lyrics-dual')));
    await settle(tester);
    expect(sv.settings.lyricsLook, 'dual');
    expect(find.byKey(const ValueKey('dual-stack0')), findsOneWidget);
    await close(tester);
    // reopen with another song: Both again
    await openPane(tester, _song('lyrPick2', 'Song'));
    expect(txt('Roman letters + original'), findsOneWidget);
    expect(find.byKey(const ValueKey('dual-stack0')), findsOneWidget);
    // what a fresh launch reads (the same settings box)
    expect(Hive.box('settings').get('lyricsLook'), 'dual');
    expect(Hive.box('settings').get('lyricsLookManual'), isTrue);
    // Song's own: Romanize, then Romanize again turns it off
    await tester.tap(find.byTooltip('Romanize'));
    await settle(tester);
    expect(sv.settings.lyricsLook, 'romanized');
    await tester.tap(find.byTooltip('Romanize'));
    await settle(tester);
    expect(sv.settings.lyricsLook, 'original');
    await close(tester);
    await openPane(tester, _song('lyrPick3', 'Song'));
    expect(txt('Lyrics · Open lyrics'), findsOneWidget);
    expect(txt('வானம்'), findsWidgets, reason: 'Song\'s own script');
    expect(find.byKey(const ValueKey('dual-stack0')), findsNothing);
    await close(tester);
    // the letters picked in Settings clear the pick: back to Romanized
    sv.settings.lyricsLook = null;
    expect(sv.settings.lyricsLook, isNull);
  });

  testWidgets('full-screen lyrics: the type buttons and the "Romanized · …" line go, only lyrics; the pick stays; leaving brings them back', (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(() {
      LyricsPane.idle.value = false;
      LyricsPane.browsing.value = false;
    });
    lrc = _tamilLrc;
    await openPane(tester, _song('lyrFull1', 'Song'));
    expect(find.byTooltip('Romanize'), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-dual')), findsOneWidget);
    expect(find.byTooltip('Translate'), findsOneWidget);
    expect(txt('Romanized · Open lyrics'), findsOneWidget);
    final before = LyricsPane.shown;
    // the player goes full screen (no touch for a few seconds)
    LyricsPane.idle.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Romanize'), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-dual')), findsNothing);
    expect(find.byTooltip('Translate'), findsNothing);
    expect(txt('Romanized · Open lyrics'), findsNothing);
    expect(identical(LyricsPane.shown, before), isTrue, reason: 'same look, same lyrics');
    final onScreen = tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).join(' | ');
    expect(onScreen, contains(before!.lines.first.text.split(' ').first));
    expect(needsDualText(onScreen), isFalse);
    // leaving full screen: back
    LyricsPane.idle.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Romanize'), findsOneWidget);
    expect(txt('Romanized · Open lyrics'), findsOneWidget);
    // scrolling the lyrics (the controls fold too): hidden as well
    LyricsPane.browsing.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Romanize'), findsNothing);
    LyricsPane.browsing.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // a hand pick carries into full screen
    await tester.tap(find.byKey(const ValueKey('lyrics-dual')));
    await settle(tester);
    LyricsPane.idle.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('dual-stack0')), findsWidgets);
    expect(txt('Roman letters + original'), findsNothing);
    LyricsPane.idle.value = false;
    await tester.pump(const Duration(milliseconds: 400));
    await close(tester);
  });

  testWidgets('wide player (tablet / web / desktop): full-screen lyrics fold the cover, controls and switch; only lyrics; a touch brings them back', (tester) async {
    addTearDown(tester.view.reset);
    final idleAfter = LyricsPane.idleAfter;
    addTearDown(() {
      LyricsPane.idleAfter = idleAfter;
      LyricsPane.idle.value = false;
    });
    LyricsPane.idleAfter = const Duration(seconds: 2);
    sv.settings.lyricsAutoFullScreen = true;
    lrc = _tamilLrc;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    await tester.runAsync(() => sv.player.playItems([_song('lyrWide1', 'Song')]));
    await tester.runAsync(() => sv.player.pause());
    await tester.pumpWidget(const ByteApp());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('mini')));
    await settle(tester);
    expect(find.text('Up next'), findsWidgets);
    expect(find.byTooltip('Romanize'), findsOneWidget);
    expect(find.byType(SeekBar), findsOneWidget);
    // no touch for a while: full screen
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(LyricsPane.idle.value, isTrue);
    expect(find.byTooltip('Romanize'), findsNothing);
    expect(txt('Romanized · Open lyrics'), findsNothing);
    expect(find.byType(SeekBar), findsNothing);
    expect(find.text('Up next'), findsNothing);
    final onScreen = tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).join(' | ');
    expect(onScreen, contains(LyricsPane.shown!.lines.first.text.split(' ').first));
    // a touch: back
    await tester.tapAt(const Offset(640, 400));
    await settle(tester);
    expect(LyricsPane.idle.value, isFalse);
    expect(find.byTooltip('Romanize'), findsOneWidget);
    expect(find.byType(SeekBar), findsOneWidget);
    expect(find.text('Up next'), findsWidgets);
    await close(tester);
  });
}
