import 'dart:async';

import 'package:byte/app.dart';
import 'package:byte/cast/cast_session.dart';
import 'package:byte/core/models.dart';
import 'package:byte/lyrics/lrc.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/lyrics/romanize.dart';
import 'package:byte/lyrics/translate.dart';
import 'package:byte/player/audio_route.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/now_playing.dart';
import 'package:byte/ui/player_parts.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:byte/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

const song = Item(kind: ItemKind.song, id: 'abc123', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], durationSec: 262);

Future<void> openPlayer(WidgetTester tester, Services sv, {Size size = const Size(390, 844)}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.runAsync(() async {
    final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
    await sv.player.playItems(album.tracks, from: 'Test Album');
  });
  await tester.pumpWidget(const ByteApp());
  await settle(tester);
  await tester.tap(find.byKey(const ValueKey('mini')));
  await settle(tester);
}

Future<void> closeAll(WidgetTester tester, Services sv) async {
  await tester.runAsync(() => sv.player.stop());
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  group('lyrics: romanize, translate, providers', () {
    test('romanize Indian scripts, keep other text', () {
      expect(romanizeLyric('तुम ही हो'), 'Tum hi ho');
      expect(romanizeLyric('कल्याणी'), 'Kalyani');
      expect(romanizeLyric('কল্যাণী'), 'Kolyani');
      expect(romanizeLyric('കല്യാണി'), 'Kalyani');
      expect(romanizeLyric('Hello, world'), 'Hello, world');
      expect(hasIndicLetters('ਪੰਜਾਬੀ'), isTrue);
      expect(romanizeLyric('ਪੰਜਾਬੀ'), 'Panjabi');
      expect(romanizeLyric('நான்'), 'Naan');
    });

    test('romanized lyrics keep their timings', () {
      final l = Lyrics.synced(const [LyricLine(1000, 'तुम ही हो'), LyricLine(5000, '')], 'LRCLIB');
      final r = romanizeLyrics(l);
      expect(r.lines.first.startMs, 1000);
      expect(r.lines.first.text, 'Tum hi ho');
      expect(r.source, 'LRCLIB');
    });

    test('translation: script → language guess, batched request, one line per line', () async {
      expect(LyricsTranslator.guessSource('तुम ही हो'), 'hi');
      expect(LyricsTranslator.guessSource('കല്യാണി'), 'ml');
      expect(LyricsTranslator.guessSource('Tum hi ho, ab tum hi ho, dil mera'), 'hi');
      expect(LyricsTranslator.guessSource('You are the one'), 'en');
      final asked = <Uri>[];
      // 1) the auto-detecting translator: one POST with every line, language detected
      final bodies = <String>[];
      final t = LyricsTranslator(
        FakeNet((r, b) {
          asked.add(r.url);
          bodies.add(b);
          return jsonRes([
            ['You are the one', 'hi'],
            ['Now only you', 'hi'],
          ]);
        }),
      );
      final out = await t.lines(['तुम ही हो', '', 'अब तुम ही हो'], 'en');
      expect(out, ['You are the one', '', 'Now only you']);
      expect(asked.single.queryParameters['sl'], 'auto');
      expect(bodies.single.split('&').length, 2);
      expect(t.detected, 'hi');
      await t.lines(['तुम ही हो'], 'en');
      expect(asked.length, 1, reason: 'cached: no second request');
      // 2) when that one is unreachable: the free fallback, batched, script → language
      asked.clear();
      final t2 = LyricsTranslator(
        FakeNet((r, _) {
          asked.add(r.url);
          if (r.url.host.contains('google')) return jsonRes({'error': 'blocked'}, 429);
          return jsonRes({
            'responseData': {'translatedText': 'You are the one\nNow only you'},
          });
        }),
      );
      final out2 = await t2.lines(['तुम ही हो', '', 'अब तुम ही हो'], 'en');
      expect(out2, ['You are the one', '', 'Now only you']);
      expect(asked.last.queryParameters['langpair'], 'hi|en');
      final both = combineTranslation(Lyrics.synced(const [LyricLine(0, 'तुम ही हो')], 'x'), ['You are the one']);
      expect(both.lines.single.text, 'तुम ही हो\nYou are the one');
    });

    test('YouTube captions (json3) become synced lines; music-only lines dropped', () {
      final lines = parseJson3Captions({
        'events': [
          {'tStartMs': 0, 'segs': [{'utf8': '[Music]'}]},
          {'tStartMs': 12000, 'segs': [{'utf8': 'Hum tere bin'}, {'utf8': ' ab reh nahi sakte'}]},
          {'tStartMs': 8000, 'segs': [{'utf8': '♪'}]},
          {'tStartMs': 16000, 'segs': [{'utf8': 'Tere bina\nkya wajood mera'}]},
        ],
      });
      expect(lines.map((l) => l.startMs), [12000, 16000]);
      expect(lines.first.text, 'Hum tere bin ab reh nahi sakte');
      expect(lines.last.text, 'Tere bina kya wajood mera');
    });

    test('provider order, off switch, addons, lyrics files and the user\'s Musixmatch key', () async {
      final net = FakeNet((r, _) {
        final u = r.url.toString();
        if (u.contains('lrclib')) return jsonRes(<dynamic>[]);
        if (u.contains('musixmatch') && u.contains('subtitle')) {
          return jsonRes({
            'message': {
              'body': {
                'subtitle': {'subtitle_body': '[00:01.00] Tum hi ho\n[00:05.00] Ab tum hi ho'},
              },
            },
          });
        }
        return null;
      });
      final svc = LyricsService(net, sv.yt)
        ..order = (() => ['lrclib', 'addons', 'musixmatch'])
        ..off = (() => {'musixmatch'})
        ..musixmatchKey = (() => 'k');
      expect(svc.activeOrder.take(2), ['lrclib', 'addons']);
      expect(svc.activeOrder.contains('musixmatch'), isFalse);
      svc.addonLyrics = (_) async => (null, 'plain words', 'Home addon');
      final a = await svc.forItem(song);
      expect(a.kind, LyricsKind.plain);
      expect(a.source, 'Home addon');
      // turned on, Musixmatch's synced lyrics beat the addon's plain ones
      final svc2 = LyricsService(net, sv.yt)
        ..order = (() => ['addons', 'musixmatch'])
        ..off = (() => <String>{})
        ..musixmatchKey = (() => 'k')
        ..addonLyrics = ((_) async => (null, 'plain words', 'Home addon'));
      final m = await svc2.forItem(song);
      expect(m.kind, LyricsKind.synced);
      expect(m.source, 'Lyrics service');
      expect(net.log.any((r) => r.url.queryParameters['apikey'] == 'k'), isTrue);
      // no key: nothing asked
      final svc3 = LyricsService(net, sv.yt)..musixmatchKey = (() => '');
      expect((await svc3.fromProvider('musixmatch', song)).kind, LyricsKind.none);
      // picking a provider sticks for the song
      svc.choose(song, Lyrics.plain('mine', 'YouTube Music'));
      expect((await svc.forItem(song)).source, 'YouTube Music');
    });
  });

  group('player: one screen with song / lyrics / queue', () {
    testWidgets('modes, bottom row, ∞ pill, volume, output sheet, pipeline and Cast dialog', (tester) async {
      sv.route.setForTest(const AudioRouteInfo(deviceName: 'Apurba\'s Phone', outputType: 'speaker', sampleRate: 48000, framesPerBuffer: 192, volume: 0.5));
      sv.lyrics.addonLyrics = null;
      await openPlayer(tester, sv);
      addTearDown(tester.view.reset);
      // song mode
      expect(find.byType(PlayerVolume), findsOneWidget);
      expect(find.text('Apurba\'s Phone'), findsWidgets);
      // song mode: the line being sung sits under the title (it replaces the "playing from" line)
      expect(find.byType(NextLyricLine), findsOneWidget);
      expect(find.byTooltip('Shuffle'), findsNothing); // not on the main controls any more
      // lyrics mode (1.4's quiet-seconds full screen has its own test)
      sv.settings.lyricsAutoFullScreen = false;
      addTearDown(() => sv.settings.lyricsAutoFullScreen = true);
      await tester.tap(find.byTooltip('Lyrics'));
      await settle(tester);
      expect(find.byType(LyricsPane), findsOneWidget);
      // scrolling the lyrics hides the controls (full-height lyrics)
      LyricsPane.browsing.value = true;
      await settle(tester);
      expect(find.byType(SeekBar), findsNothing);
      expect(find.byTooltip('Back to the live line'), findsOneWidget);
      expect(find.byTooltip('Share lines'), findsOneWidget);
      LyricsPane.resync.value++;
      LyricsPane.browsing.value = false;
      await settle(tester);
      expect(find.byType(SeekBar), findsOneWidget);
      // queue mode: heading, now playing, next from, and the pill instead of the output button
      await tester.tap(find.byTooltip('Queue'));
      await settle(tester);
      expect(find.text('Queue'), findsWidgets);
      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('Next from: Test Album'), findsOneWidget);
      expect(find.byType(QueueModesPill), findsOneWidget);
      expect(find.byTooltip('Audio output'), findsNothing);
      final before = sv.settings.autoplay;
      await tester.tap(find.byTooltip('Autoplay similar songs'));
      await settle(tester);
      expect(sv.settings.autoplay, !before);
      sv.settings.autoplay = false;
      final n = sv.player.queueModel.playOrder.length;
      await tester.tap(find.byTooltip('Remove from queue').first);
      await settle(tester);
      expect(sv.player.queueModel.playOrder.length, n - 1);
      await tester.tap(find.byTooltip('Queue'));
      await settle(tester);
      // output sheet → pipeline
      await tester.tap(find.byTooltip('Audio output'));
      await settle(tester);
      expect(find.text('Audio output'), findsOneWidget);
      expect(find.text('Cast'), findsOneWidget);
      expect(find.text('Audio Pipeline'), findsOneWidget);
      await tester.tap(find.text('Audio Pipeline'));
      await settle(tester);
      for (final s in ['TRACK INFO', 'DECODER', 'RESAMPLER', 'DSP', 'OUTPUT']) {
        expect(find.text(s, skipOffstage: false), findsOneWidget, reason: s);
      }
      expect(find.text('Sample Rate'), findsWidgets);
      await tester.tap(find.text('Done'));
      await settle(tester);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await settle(tester);
      // hide volume bar
      sv.settings.hideVolumeBar = true;
      await settle(tester);
      expect(find.byType(PlayerVolume), findsNothing);
      sv.settings.hideVolumeBar = false;
      await closeAll(tester, sv);
    });

    testWidgets('Cast dialog: searching, then the speakers on the Wi-Fi', (tester) async {
      final found = Completer<List<CastDevice>>();
      sv.cast.scannerForTest = () => found.future;
      await openPlayer(tester, sv);
      addTearDown(tester.view.reset);
      await tester.tap(find.byTooltip('Audio output'));
      await settle(tester);
      await tester.tap(find.text('Cast'));
      await settle(tester);
      expect(find.text('Looking for devices…'), findsOneWidget);
      found.complete(const [CastDevice(id: 'k1', name: 'Living Room speaker', host: '192.168.1.20')]);
      await settle(tester);
      expect(find.text('Living Room speaker'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await settle(tester);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await settle(tester);
      sv.cast.scannerForTest = null;
      await closeAll(tester, sv);
    });

    for (final w in [360.0, 390.0, 820.0]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('player fits at ${w.toInt()} px ${mode.name} in every mode', (tester) async {
          sv.settings.themeMode = mode;
          await openPlayer(tester, sv, size: Size(w, w >= 820 ? 1180 : 760));
          addTearDown(tester.view.reset);
          if (w < 820) {
            for (final tip in ['Lyrics', 'Queue', 'Queue']) {
              await tester.tap(find.byTooltip(tip).first);
              await settle(tester);
            }
          }
          expect(tester.takeException(), isNull);
          await closeAll(tester, sv);
        });
      }
    }
  });

  group('bars and padding (v1.2.1 phone video)', () {
    testWidgets('opening a page keeps all tabs; scrolling folds and unfolds; tapping the folded tab unfolds', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
        await sv.player.playItems(album.tracks);
      });
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
      final shell = tester.state<ShellState>(find.byType(Shell));
      pushInCurrentTab!(const SettingsScreen());
      await settle(tester);
      expect(shell.bar.value, 0, reason: 'a page opened: Home, Explore and Library stay');
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -500));
      await settle(tester);
      expect(shell.bar.value, 1, reason: 'scrolling down folds the bar');
      await tester.drag(find.byType(Scrollable).last, const Offset(0, 120));
      await settle(tester);
      expect(shell.bar.value, 0, reason: 'scrolling up brings the tabs back');
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -500));
      await settle(tester);
      shell.tapCompactTab();
      await settle(tester);
      expect(shell.bar.value, 0);
      expect(find.byType(SettingsScreen), findsOneWidget, reason: 'the page stays open');
      await closeAll(tester, sv);
    });

    final pages = <String, Widget Function()>{
      'Settings': () => const SettingsScreen(),
      'Playback': () => const PlaybackScreen(),
      'Appearance': () => const AppearanceScreen(),
      'Misc': () => const MiscScreen(),
      'Downloads': () => const DownloadSettingsScreen(),
    };
    for (final e in pages.entries) {
      testWidgets('${e.key}: the last row scrolls clear of the mini player and bar', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 700);
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
          await sv.player.playItems(album.tracks);
        });
        await tester.pumpWidget(const ByteApp());
        await settle(tester);
        pushInCurrentTab!(e.value());
        await settle(tester);
        for (var i = 0; i < 12; i++) {
          await tester.drag(find.byType(Scrollable).last, const Offset(0, -900));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await settle(tester);
        // unfold the bar (the worst case: it is at its tallest)
        tester.state<ShellState>(find.byType(Shell)).tapCompactTab();
        await settle(tester);
        final barTop = tester.getTopLeft(find.byType(FloatingBar)).dy + (tester.getSize(find.byType(FloatingBar)).height - 138 - 0);
        final texts = find.descendant(of: find.byType(Scrollable).last, matching: find.byType(Text));
        final lastBottom = texts.evaluate().map((el) => tester.getBottomLeft(find.byWidget(el.widget)).dy).reduce((a, b) => a > b ? a : b);
        expect(lastBottom, lessThan(barTop), reason: '${e.key}: last text ends at $lastBottom, bar starts at $barTop');
        await closeAll(tester, sv);
      });
    }
  });

  group('lyrics pane states', () {
    testWidgets('no lyrics anywhere → a clear message and "Try another source"', (tester) async {
      sv.lyrics
        ..order = (() => ['addons'])
        ..off = (() => {'lrclib', 'ytm', 'ytcaptions', 'files', 'musixmatch'})
        ..addonLyrics = ((_) async => null);
      await tester.runAsync(() => sv.player.playItems([song.copyWithId('nolyr1')]));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(backgroundColor: Colors.black, body: LyricsPane())));
      await settle(tester);
      expect(find.text('No lyrics for this song'), findsOneWidget);
      expect(find.text('Try another source'), findsOneWidget);
      await closeAll(tester, sv);
    });

    testWidgets('a source that never answers: the pane gives up after 25 s instead of spinning forever', (tester) async {
      sv.lyrics
        ..order = (() => ['addons'])
        ..off = (() => {'lrclib', 'kugou', 'ytm', 'ytcaptions', 'files', 'musixmatch'})
        ..addonLyrics = ((_) => Completer<(List<LyricLine>?, String?, String)?>().future);
      await tester.runAsync(() => sv.player.playItems([song.copyWithId('hang1')]));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(backgroundColor: Colors.black, body: LyricsPane())));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('No lyrics for this song'), findsNothing);
      await tester.pump(const Duration(seconds: 26));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('No lyrics for this song'), findsOneWidget);
      sv.wireSources();
      await closeAll(tester, sv);
    });

    testWidgets('provider picker lists every source with found / not found, and picking one uses it', (tester) async {
      sv.lyrics
        ..order = (() => ['addons', 'lrclib'])
        // 1.4.1 added the upload's own timed lyrics / captions as sources; this test is about the addon pick
        ..off = (() => {'musixmatch', 'ytm', 'ytcaptions'})
        ..addonLyrics = ((_) async => (const [LyricLine(0, 'line one'), LyricLine(3000, 'line two')], null, 'Home addon'));
      await tester.runAsync(() => sv.player.playItems([song.copyWithId('pick1')]));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(backgroundColor: Colors.black, body: LyricsPane())));
      await settle(tester);
      // 1.4.1: a source whose length matches the playing version (the open
      // lyrics site here) wins over plain source order; the addon gives no length
      expect(find.textContaining('Lyrics · Open lyrics'), findsOneWidget);
      await tester.tap(find.textContaining('Lyrics ·'));
      await settle(tester);
      expect(find.text('Choose lyrics provider'), findsOneWidget);
      expect(find.text('Synced · 2 lines'), findsOneWidget);
      expect(find.text('Lyrics not found'), findsWidgets);
      expect(find.textContaining('Turned off'), findsWidgets);
      // picking one uses it
      await tester.tap(find.text('Synced · 2 lines'));
      await settle(tester);
      if (find.byType(BottomSheet).evaluate().isNotEmpty) {
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await settle(tester);
      }
      expect(find.textContaining('Lyrics · Home addon'), findsOneWidget);
      // (the line being sung is drawn word by word, so find it by a word)
      await tester.longPress(find.textContaining('two').first);
      await settle(tester);
      expect(find.text('Share 1 line'), findsOneWidget);
      expect(selectedLyricsText(), startsWith('line two\n\n— Tum Hi Ho'));
      LyricsPane.selection.value = null;
      sv.wireSources();
      await closeAll(tester, sv);
    });
  });
}

extension on Item {
  Item copyWithId(String id) => Item(kind: kind, id: id, title: title, artists: artists, durationSec: durationSec);
}
