// Byte © 2026 Apurba Laskar.
//
// 1.4.5 QA pass (Apurba, 8:45 PM: "baki sare possible bug fix karna test
// karke"): bugs found by running the app and reading the code, each with a
// test that fails on the old code.
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/core/net_proxy.dart';
import 'package:byte/dj/up_next.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;

Item s(String id, String title, String artist) => Item(kind: ItemKind.song, id: id, title: title, artists: [ArtistRef(artist)], durationSec: 240);

Future<void> until(bool Function() ok, {int ms = 4000, String? why}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out${why == null ? '' : ': $why'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('Next on an artist radio', () {
    late Services sv;
    late ByteAudioHandler p;
    setUp(() async {
      sv = await makeServices();
      p = sv.player;
      sv.settings.autoplay = true;
      sv.settings.crossfadeSeconds = 0;
      sv.settings.automix = false;
      fakeAudio.durationFor = (_) => const Duration(minutes: 4);
    });
    tearDown(() async {
      await p.stop();
      PersonalRadio.feedback.clear();
    });

    // Seen in the web build: "kesariya" → Arijit Singh Radio, every song next
    // is Arijit's; Next within 30 s emptied the whole list ("Finding similar
    // songs…") and stayed on the same song.
    test('a quick Next goes to the next song and keeps the list (every song by the same artist)', () async {
      p.personalRadio = (seed, exclude) async => [
        for (var i = 0; i < 15; i++)
          if (!exclude.contains('arjRadio${i.toString().padLeft(4, '0')}')) s('arjRadio${i.toString().padLeft(4, '0')}', 'Arijit song $i', 'Arijit Singh'),
      ];
      await p.playItems([s('arjSeed0001', 'Kesariya', 'Arijit Singh')]);
      await until(() => p.upcomingCount >= 10);
      final next = p.queueModel.nextItem!.id;
      await p.skipToNext();
      expect(p.current.value!.id, next, reason: 'Next plays the song that was next');
      expect(p.upcomingCount, greaterThanOrEqualTo(9), reason: 'the up-next list is not wiped');
    });

    test('mixed list: the next song stays even when it is by the skipped artist', () async {
      p.personalRadio = (seed, exclude) async => [
        for (final x in [
          s('mixSkip0001', 'A1', 'Skipped Artist'),
          s('mixSkip0002', 'A2', 'Skipped Artist'),
          for (var i = 0; i < 12; i++) s('mixMore${i.toString().padLeft(4, '0')}', 'More $i', 'Other $i'),
        ])
          if (!exclude.contains(x.id)) x,
      ];
      await p.playItems([s('mixSeed0001', 'Seed', 'Skipped Artist')]);
      await until(() => p.upcomingCount >= 10);
      expect(p.queueModel.nextItem!.id, 'mixSkip0001');
      await p.skipToNext(); // skipping the seed (Skipped Artist) at once
      expect(p.current.value!.id, 'mixSkip0001', reason: 'Next goes where the list said');
      final upcoming = p.queueModel.playOrder.skip(p.queueModel.position + 1).map((e) => e.id).toList();
      expect(upcoming, isNot(contains('mixSkip0002')), reason: 'the artist\'s later picks still leave');
    });
  });

  // Seen in the web build with the network cut: the page said "Online songs
  // need the Byte web server switched on — 1 step for the owner".
  group('web: no internet is not "server switched off"', () {
    final ep = Uri.parse('https://proj.supabase.co/functions/v1/byte-proxy');
    MockClient down() => MockClient((_) async => throw http.ClientException('XMLHttpRequest error.'));

    test('device offline: honest message, the server state is left alone', () async {
      final n = WebProxyNet(ep, client: down(), deviceOnline: () => false);
      await expectLater(n.get(Uri.parse('https://music.youtube.com/sw.js_data')), throwsA(isA<NetException>().having((e) => e.message, 'm', WebProxyNet.noInternetMessage)));
      expect(n.state.value, isNot(WebProxyState.offline));
      expect(await n.ping(), isFalse);
      expect(n.state.value, isNot(WebProxyState.offline), reason: 'no banner asking the owner to switch the server on');
    });

    test('device online and the server missing: still says so', () async {
      final n = WebProxyNet(ep, client: down(), deviceOnline: () => true);
      await expectLater(n.get(Uri.parse('https://music.youtube.com/sw.js_data')), throwsA(isA<NetException>().having((e) => e.message, 'm', WebProxyNet.offlineMessage)));
      expect(n.state.value, WebProxyState.offline);
    });
  });

  // Seen in the web build at 1440 px: Space scrolled the page (and in the
  // lyrics scrolled them, which sent them full screen again); nothing paused.
  group('keys on a computer / the web', () {
    late Services sv;
    setUp(() async {
      sv = await makeServices();
      sv.settings.autoplay = false;
    });

    Future<void> start(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      await tester.runAsync(() async {
        final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
        await sv.player.playItems(album.tracks, from: 'Test Album');
      });
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
    }

    Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {bool control = false}) async {
      if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(k);
      if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('Space pauses and plays; Ctrl+→ goes to the next song', (tester) async {
      addTearDown(tester.view.reset);
      await start(tester);
      expect(sv.player.playing, isTrue);
      await key(tester, LogicalKeyboardKey.space);
      expect(sv.player.playing, isFalse);
      await key(tester, LogicalKeyboardKey.space);
      expect(sv.player.playing, isTrue);
      final first = sv.player.current.value!.id;
      await key(tester, LogicalKeyboardKey.arrowRight, control: true);
      expect(sv.player.current.value!.id, isNot(first));
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    });

    testWidgets('typing a space in a text field types, it does not pause', (tester) async {
      addTearDown(tester.view.reset);
      await start(tester);
      await tester.pumpWidget(
        MaterialApp(
          shortcuts: (tester.widget(find.byType(MaterialApp).first) as MaterialApp).shortcuts,
          actions: (tester.widget(find.byType(MaterialApp).first) as MaterialApp).actions,
          home: const Scaffold(body: TextField(autofocus: true)),
        ),
      );
      await tester.pump();
      expect(sv.player.playing, isTrue);
      await key(tester, LogicalKeyboardKey.space);
      expect(sv.player.playing, isTrue, reason: 'the text field keeps its Space');
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  // Seen on the Library screen after one like: "Liked Songs · 1 songs".
  test('song counts read "1 song", "2 songs", "0 songs"', () {
    expect(songCount(1), '1 song');
    expect(songCount(2), '2 songs');
    expect(songCount(0), '0 songs');
  });

  // Seen in the web build: the player open on a phone turned sideways
  // (844×390) threw "Invalid argument(s): 120.0" from the cover's size and
  // drew an error box instead of the cover.
  group('player sizes', () {
    late Services sv;
    setUp(() async {
      sv = await makeServices();
      sv.settings.autoplay = false;
    });
    testWidgets('the open player survives turning sideways and back, and big windows', (tester) async {
      addTearDown(tester.view.reset);
      await openPlayer(tester, sv);
      for (final full in [true, false]) {
        sv.settings.fullScreenCover = full;
        for (final sz in const [Size(844, 390), Size(390, 844), Size(1440, 900), Size(390, 844)]) {
          tester.view.physicalSize = sz;
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'cover ${full ? 'full' : 'square'} at $sz');
        }
      }
      await closeAll(tester, sv);
    });
  });
}
