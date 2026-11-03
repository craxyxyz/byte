// Byte © 2026 Apurba Laskar.
//
// 1.4.6 QA, round 2 (Apurba, 10:14 PM: "or bhi aise bug hunt karke bug
// dundo"): the bugs the first hunt only noted, each with a test that fails on
// 1.4.5.
import 'dart:typed_data';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/core/search_rank.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/now_playing.dart' show Marquee, lyricsMayGoFullScreen;
import 'package:byte/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;

Item s(String id, String title, [String artist = 'Arijit Singh']) =>
    Item(kind: ItemKind.song, id: id, title: title, artists: [ArtistRef(artist)], durationSec: 260);

void main() {
  group('search: the original song comes before its edits', () {
    final results = [
      s('a', 'Tum Hi Ho (Slowed + Reverb)', 'Lofi Edits'),
      s('b', 'Tum Hi Ho - Lofi Flip', 'Chill Beats'),
      s('c', 'Tum Hi Ho'),
      s('d', 'Tum Hi Ho (Female Cover)', 'Someone'),
      s('e', 'Tum Hi Ho (8D Audio)', '8D Tunes'),
      s('f', 'Tum Hi Ho (From "Aashiqui 2")'),
    ];

    test('"tum hi ho": the original first, then other takes, edits last', () {
      final r = rankSearchItems('tum hi ho', results).map((i) => i.id).toList();
      expect(r.take(2), ['c', 'f']);
      expect(r[2], 'd', reason: 'a cover is a softer demotion than a slowed edit');
      expect(r.skip(3), ['a', 'b', 'e'], reason: 'the catalogue order is kept among edits');
    });

    test('asking for the edit still finds it first', () {
      expect(rankSearchItems('tum hi ho slowed reverb', results).first.id, 'a');
      expect(rankSearchItems('tum hi ho lofi', results).first.id, 'b');
      final eight = rankSearchItems('tum hi ho 8d', results).map((i) => i.id).toList();
      expect(eight.indexOf('e'), lessThan(eight.indexOf('a')), reason: 'the 8D edit is not pushed down when asked for');
    });

    test('albums, artists and playlists keep their place', () {
      const album = Item(kind: ItemKind.album, id: 'MPRE1', title: 'Lofi Nights');
      final r = rankSearchItems('tum hi ho', [album, results[0], results[2]]);
      expect(r.map((i) => i.id), ['MPRE1', 'c', 'a']);
    });

    test('a "Top result" that is only an edit moves below the songs that hold the original', () {
      final shelves = rankSearchShelves('tum hi ho', [
        Shelf('Top result', [results[0]]),
        Shelf('Songs', [results[1], results[2]]),
        const Shelf('Albums', [Item(kind: ItemKind.album, id: 'MPRE2', title: 'Aashiqui 2')]),
      ]);
      expect(shelves.map((s) => s.title), ['Songs', 'Top result', 'Albums']);
      expect(shelves.first.items.first.id, 'c');
    });
  });

  group('import: a link Byte can\'t read', () {
    test('a site that refuses (403) says "not a supported link", not "the server answered 403"', () async {
      final net = FakeNet((r, body) => NetResponse(403, const {}, Uint8List(0)));
      final reader = PlaylistReader(net, InnerTube(net));
      await expectLater(
        reader.read('https://www.example-music-site.com/playlist/123'),
        throwsA(isA<ImportProblem>().having((e) => e.message, 'message', unsupportedLinkMessage)),
      );
    });

    test('a site that throws a 404 the same way', () async {
      final net = FakeNet((r, body) => throw NetException('The server answered 404', 404));
      final reader = PlaylistReader(net, InnerTube(net));
      await expectLater(
        reader.read('https://www.example-music-site.com/list'),
        throwsA(isA<ImportProblem>().having((e) => e.message, 'message', contains('not a supported playlist link'))),
      );
    });

    test('no answer at all (offline) is still a connection problem, not "unsupported"', () async {
      final net = FakeNet((r, body) => throw NetException('No internet'));
      final reader = PlaylistReader(net, InnerTube(net));
      await expectLater(reader.read('https://www.example-music-site.com/list'), throwsA(isA<NetException>()));
    });
  });

  group('full-screen lyrics only while music plays', () {
    late Services sv;
    setUpAll(() async {
      sv = await makeServices();
      sv.settings.autoplay = false;
    });

    test('nothing loaded → no full screen', () {
      expect(lyricsMayGoFullScreen(sv.player), isFalse);
    });

    testWidgets('stopped (or failed to load): the lyrics stay put; paused by hand still goes full screen', (tester) async {
      addTearDown(tester.view.reset);
      sv.settings.lyricsAutoFullScreen = true;
      await openPlayer(tester, sv);
      await tester.runAsync(() => sv.player.stop());
      await tester.pump(const Duration(milliseconds: 200));
      expect(lyricsMayGoFullScreen(sv.player), isFalse);
      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(LyricsPane.idle.value, isFalse, reason: '1.4.5 went full screen with nothing playing');
      await closeAll(tester, sv);
    });

    testWidgets('paused by hand: full screen as before (1.4.4)', (tester) async {
      addTearDown(tester.view.reset);
      await openPlayer(tester, sv);
      await tester.runAsync(() async {
        await sv.player.pause();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(lyricsMayGoFullScreen(sv.player), isTrue);
      await closeAll(tester, sv);
    });
  });

  group('playlists', () {
    Future<void> pumpPrompt(WidgetTester tester, void Function(String?) got, {String? hint = 'Playlist name'}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(onPressed: () async => got(await promptText(c, title: 'New playlist', hint: hint)), child: const Text('open')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Save with an empty name keeps the dialog open and says why', (tester) async {
      String? result = 'unset';
      await pumpPrompt(tester, (v) => result = v);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('New playlist'), findsOneWidget, reason: 'the dialog is still open');
      expect(find.text('Type a playlist name first'), findsOneWidget);
      expect(result, 'unset');
      // typing clears the message, Save works
      await tester.enterText(find.byType(TextField), 'Road trip');
      await tester.pump();
      expect(find.text('Type a playlist name first'), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, 'Road trip');
    });

    testWidgets('the keyboard\'s done key with an empty name says why too; Cancel still closes', (tester) async {
      String? result = 'unset';
      await pumpPrompt(tester, (v) => result = v, hint: null);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Type a name first'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(TextField), findsNothing);
    });

  });

  group('long titles show "…" instead of being cut', () {
    const title = 'Tum Hi Ho (From "Aashiqui 2") — the very long title of a song that does not fit';
    Future<void> pump(WidgetTester tester, double width, {double scale = 1}) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: SizedBox(width: width, child: const Marquee(text: title, style: TextStyle(fontSize: 21)))),
          ),
        ),
      );
    }

    testWidgets('while the scroll waits at the start the title ends with "…"', (tester) async {
      await pump(tester, 300);
      final t = tester.widget<Text>(find.text(title));
      expect(t.overflow, TextOverflow.ellipsis);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a title that fits at 1× but not at 1.6× text size still gets "…" / scrolls', (tester) async {
      const short = 'Kesariya (Brahmastra)';
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: SizedBox(width: 260, child: const Marquee(text: short, style: TextStyle(fontSize: 21)))),
          ),
        ),
      );
      final t = tester.widget<Text>(find.text(short));
      expect(t.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
