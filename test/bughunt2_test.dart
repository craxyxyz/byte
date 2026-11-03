import 'dart:typed_data';

import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/lyrics/lrc.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/import_sheet.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Bug hunt, part 2: no lyrics / offline lyrics, long Hindi & Bengali lyric
/// lines, importing with no internet, your own server's songs in the player.
void main() {
  const song = Item(kind: ItemKind.song, id: 'nolyr1', title: 'A song nobody wrote lyrics for', artists: [ArtistRef('Nobody')], durationSec: 200);

  Future<void> pumpPane(WidgetTester tester, double w, bool dark) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(w, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: ByteTheme.build(dark ? Brightness.dark : Brightness.light), home: const Scaffold(backgroundColor: Colors.black, body: LyricsPane())));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('a song with no lyrics anywhere shows "No lyrics for this song"', (tester) async {
    await tester.runAsync(() async {
      await makeServices(net: FakeNet((r, b) => NetResponse(404, const {}, Uint8List(0))));
    });
    Services.i.player.current.value = song;
    await pumpPane(tester, 360, true);
    expect(find.text('No lyrics for this song'), findsOneWidget);
    expect(tester.takeException(), isNull);
    Services.i.player.current.value = null;
    await done(tester);
  });

  testWidgets('no internet: lyrics fall back to "No lyrics", nothing throws', (tester) async {
    await tester.runAsync(() async {
      await makeServices(net: FakeNet((r, b) => throw Exception('SocketException: Failed host lookup')));
    });
    Services.i.player.current.value = const Item(kind: ItemKind.song, id: 'offline1', title: 'Offline', artists: [ArtistRef('X')], durationSec: 100);
    await pumpPane(tester, 390, false);
    expect(find.text('No lyrics for this song'), findsOneWidget);
    expect(tester.takeException(), isNull);
    Services.i.player.current.value = null;
    await done(tester);
  });

  for (final w in [360.0, 390.0, 820.0]) {
    for (final dark in [false, true]) {
      testWidgets('synced lyrics with very long Hindi / Bengali lines, ${w.toInt()}px ${dark ? 'dark' : 'light'}; tap a line seeks', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(w, 800);
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          await makeServices();
        });
        var now = 0;
        int? seekTo;
        final l = Lyrics.synced([
          const LyricLine(1000, 'तुम ही हो, अब तुम ही हो, ज़िंदगी अब तुम ही हो, चैन भी, मेरा दर्द भी, मेरी आशिक़ी अब तुम ही हो'),
          const LyricLine(6000, ''),
          const LyricLine(12000, 'আমি তোমার সঙ্গে বেঁধেছি আমার প্রাণ সুরের বাঁধনে — তুমি জানো না, আমি তোমারে পেয়েছি অজানা সাধনে'),
          const LyricLine(18000, 'Supercalifragilisticexpialidocious-without-any-spaces-at-all-to-wrap-on-a-narrow-phone'),
          const LyricLine(24000, 'End'),
        ], 'test');
        await tester.pumpWidget(MaterialApp(
          theme: ByteTheme.build(dark ? Brightness.dark : Brightness.light),
          home: Scaffold(backgroundColor: Colors.black, body: SyncedLyricsView(lyrics: l, now: () => now, onSeek: (ms) => seekTo = ms)),
        ));
        for (final t in [0, 2000, 7000, 13000, 19000, 25000]) {
          now = t;
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(tester.takeException(), isNull);
        now = 19000;
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await tester.tap(find.text('End'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(seekTo, 24000);
        // A tap while the view is still gliding to a new line works too.
        seekTo = null;
        now = 25000;
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.textContaining('Supercalifragilistic'), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 100));
        expect(seekTo, 18000);
        await done(tester);
      });
    }
  }

  testWidgets('importing a link with no internet shows a clear message, not a crash', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await makeServices(net: FakeNet((r, b) => throw Exception('SocketException: Failed host lookup')));
    });
    await tester.pumpWidget(MaterialApp(theme: ByteTheme.build(Brightness.light), home: const ImportScreen(initial: 'https://open.spotify.com/playlist/6WgaVgtRZgtmDrWVUWU1R5')));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('internet'), findsWidgets);
    expect(tester.takeException(), isNull);
    await done(tester);
  });

  test('a song on your own server plays from your server, with your login', () async {
    final s = await makeServices();
    s.settings.autoplay = false;
    await s.webdav.connect('https://nas.local/music/', 'me', 'secret');
    final it = Item(kind: ItemKind.song, id: 'dav:https://nas.local/music/Kesariya.m4a', title: 'Kesariya');
    await s.player.playItems([it]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final deck = fakeAudio.players.values.firstWhere((x) => x.uri == 'https://nas.local/music/Kesariya.m4a');
    expect(deck.headers?['Authorization'], startsWith('Basic '));
    expect(s.player.current.value?.id, it.id);
    await s.player.stop();
  });
}
