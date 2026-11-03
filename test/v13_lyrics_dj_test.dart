import 'dart:convert';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/data/genres.dart';
import 'package:byte/dj/for_you.dart';
import 'package:byte/lyrics/lrc.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/lyrics/translate.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/player_parts.dart';
import 'package:byte/ui/screens/dj_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

const tamil = Item(kind: ItemKind.song, id: 'thuli1', title: 'Thuli Thuli (From "Paiya")', artists: [ArtistRef('Yuvan Shankar Raja')], durationSec: 284);

const lrc = '[ti:Thuli Thuli]\n[00:00.00]Thuli Thuli (From "Paiya") - Yuvan Shankar Raja\n[00:00.50]作词：Na. Muthukumar\n'
    '[00:33.70]Thuli thuli thuli mazhaiyai vanthaley heyyy\n[00:38.88]Chuda chuda chuda marainthey ponnaley eyy\n'
    '[00:43.78]Paarthal paarka thondrum\n[00:46.34]Peyrai kerka thondrum\n[00:56.74]Yendrey kaazhgal sozhuthada';

/// KuGou's song search, lyric candidates and LRC download, as the phone sees them.
FakeNet kugouNet({bool webEmpty = false, List<Uri>? log}) => FakeNet((r, b) => kugouHandler(r, b, webEmpty: webEmpty, log: log));

dynamic kugouHandler(NetRequest r, String body, {bool webEmpty = false, List<Uri>? log}) {
  log?.add(r.url);
  final h = r.url.host;
  if (h == 'songsearch.kugou.com') {
    return jsonRes({
      'data': {
        'lists': webEmpty
            ? []
            : [
                {'SongName': '<em>Thuli Thuli</em> Mazhaiyaai', 'Duration': 340, 'FileHash': 'FAR'},
                {'SongName': '<em>Thuli Thuli</em> (From "Paiya")', 'Duration': 283, 'FileHash': 'NEAR'},
              ],
      },
    });
  }
  if (h == 'mobilecdn.kugou.com') {
    return jsonRes({
      'data': {
        'info': [
          {'songname': 'Thuli Thuli', 'duration': 283, 'hash': 'NEAR'},
        ],
      },
    });
  }
  if (h == 'krcs.kugou.com') {
    if (r.url.queryParameters['hash'] != 'NEAR') return jsonRes({'candidates': []});
    return jsonRes({
      'candidates': [
        {'id': '676625099', 'accesskey': 'KEY', 'duration': 283000},
      ],
    });
  }
  if (h == 'lyrics.kugou.com') {
    expect(r.url.queryParameters['accesskey'], 'KEY');
    return jsonRes({'content': base64.encode(utf8.encode(lrc))});
  }
  if (h == 'lrclib.net') return jsonRes(r.url.path == '/api/search' ? [] : {'message': 'nf'}, r.url.path == '/api/search' ? 200 : 404);
  return catalogue(r, body);
}

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices(net: FakeNet((r, b) => kugouHandler(r, b)));
    sv.settings.autoplay = false;
  });

  group('KuGou lyrics', () {
    test('finds the closest-length song, downloads its synced LRC, drops credit lines', () async {
      final log = <Uri>[];
      final net = kugouNet(log: log);
      final svc = LyricsService(net, InnerTube(net))
        ..order = (() => ['kugou'])
        ..off = (() => {'lrclib', 'ytm', 'ytcaptions', 'files', 'addons', 'musixmatch'});
      final l = await svc.fromProvider('kugou', tamil);
      expect(l.kind, LyricsKind.synced);
      expect(l.source, 'Lyrics library');
      expect(l.lines.any((x) => x.text.contains('作词')), isFalse);
      expect(l.lines.first.text, startsWith('Thuli Thuli (From'));
      expect(l.lines.last.text, 'Yendrey kaazhgal sozhuthada');
      expect(l.lines.last.startMs, 56740);
      final krcs = log.firstWhere((u) => u.host == 'krcs.kugou.com');
      expect(krcs.queryParameters['hash'], 'NEAR', reason: '283 s beats 340 s for a 284 s song');
    });

    test('the https search is empty → the mobile search still finds it', () async {
      final net = kugouNet(webEmpty: true);
      final l = await LyricsService(net, InnerTube(net)).fromProvider('kugou', tamil);
      expect(l.kind, LyricsKind.synced);
    });

    test('in the default order, a Tamil song LRCLIB lacks gets KuGou\'s synced lyrics', () async {
      final net = kugouNet();
      final svc = LyricsService(net, InnerTube(net))
        ..order = (() => ['lrclib', 'kugou', 'ytm'])
        ..off = (() => {'ytcaptions', 'files', 'addons', 'musixmatch'});
      final l = await svc.forItem(tamil);
      expect(l.source, 'Lyrics library');
      expect(LyricsProvider.all.map((p) => p.name), containsAll(['Open lyrics', 'Lyrics library', 'Song page']));
    });

    test('nothing close in length → no KuGou lyrics (no wrong song)', () {
      final hits = [
        {'songname': 'Thuli Thuli', 'duration': 200, 'hash': 'A'},
        {'songname': 'Other', 'duration': 284, 'hash': 'B'},
      ];
      expect(pickBestKugou(hits, 'Thuli Thuli', 284), isNull);
      expect(pickBestKugou(hits, 'Thuli Thuli', 205)?['hash'], 'A');
    });

    test('an old saved order gets KuGou right after LRCLIB', () async {
      sv.settings.lyricsOrder = ['lrclib', 'ytm', 'files'];
      expect(sv.settings.lyricsOrder, ['lrclib', 'kugou', 'ytm', 'files']);
    });
  });

  group('translation of lyrics written in English letters', () {
    test('Tamil in English letters → Tamil script → real English (not the same words back)', () async {
      final asked = <String>[];
      final t = LyricsTranslator(
        FakeNet((r, b) {
          asked.add('${r.url.host} ${r.url.queryParameters['sl'] ?? r.url.queryParameters['itc'] ?? ''}');
          if (r.url.host == 'clients5.google.com' && r.url.queryParameters['sl'] == 'auto') {
            final qs = b.split('&').map((x) => Uri.decodeQueryComponent(x.substring(2))).toList();
            return jsonRes([for (final q in qs) [q, 'ta']]);
          }
          if (r.url.host == 'inputtools.google.com') {
            final rows = r.url.queryParameters['text']!.split('\n');
            return jsonRes([
              'SUCCESS',
              [
                [r.url.queryParameters['text'], [rows.map((x) => x.startsWith('Thuli') ? 'துளி துளி மழையாய் வந்தாலே' : 'பார்த்தால் பார்க்க தோன்றும்').join('\n')], [], {}],
              ],
            ]);
          }
          if (r.url.host == 'clients5.google.com' && r.url.queryParameters['sl'] == 'ta') {
            final qs = b.split('&').map((x) => Uri.decodeQueryComponent(x.substring(2))).toList();
            return jsonRes([for (final q in qs) q.startsWith('துளி') ? 'If it rains drop by drop' : 'When I see you I want to see more']);
          }
          return null;
        }),
      );
      final out = await t.lines(['Thuli thuli mazhaiyai vanthaley', '', 'Paarthal paarka thondrum'], 'en');
      expect(out, ['If it rains drop by drop', '', 'When I see you I want to see more']);
      expect(asked, ['clients5.google.com auto', 'inputtools.google.com ta-t-i0-und', 'inputtools.google.com ta-t-i0-und', 'clients5.google.com ta']);
      expect(LyricsTranslator.echoed('Tum hi ho ab tum hi ho', 'Tum hi ho, ab tum hi ho'), isTrue);
      expect(LyricsTranslator.echoed('Tum hi ho', 'You are the one'), isFalse);
    });
  });

  group('lyrics look (same as the reference video)', () {
    test('caption: source, translating, translated', () {
      expect(lyricsCaption('Lyrics library', look: LyricsLook.original, working: false, language: 'English'), 'Lyrics · Lyrics library');
      expect(lyricsCaption('Lyrics library', look: LyricsLook.original, working: true, language: 'English'), 'Translating to English…');
      expect(lyricsCaption('Lyrics library', look: LyricsLook.translated, working: false, language: 'English'), 'Translated to English');
    });

    testWidgets('lyrics pane: big lines, "Lyrics · Lyrics library", translate → caption + small grey line under each line, romanize on Latin → toast',
        (tester) async {
      sv.lyrics
        ..order = (() => ['kugou'])
        ..off = (() => {'lrclib', 'ytm', 'ytcaptions', 'files', 'addons', 'musixmatch'});
      final translated = <String>[];
      sv.translator.override = (lines, to) async {
        translated.addAll(lines);
        return [for (final l in lines) l.isEmpty ? '' : 'EN: $l'];
      };
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.runAsync(() => sv.player.playItems([tamil]));
      await tester.runAsync(() => sv.player.seek(const Duration(milliseconds: 57000)));
      await tester.runAsync(() => sv.player.pause());
      await tester.pumpWidget(const MaterialApp(home: Scaffold(backgroundColor: Colors.black, body: LyricsPane())));
      await settle(tester);
      await settle(tester);
      expect(find.text('Lyrics · Lyrics library'), findsOneWidget);
      final big = tester.widget<Text>(find.text('Paarthal paarka thondrum'));
      expect(big.style!.fontSize, greaterThanOrEqualTo(26));
      expect(big.style!.fontWeight, FontWeight.w800);
      // translate
      await tester.tap(find.byTooltip('Translate'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Translated to English'), findsOneWidget);
      expect(translated, contains('Paarthal paarka thondrum'));
      final sub = tester.widget<Text>(find.text('EN: Paarthal paarka thondrum'));
      expect(sub.style!.fontSize!, lessThan(big.style!.fontSize!));
      expect(sub.style!.color!.a, lessThan(0.8));
      // translate again → back to the original
      await tester.tap(find.byTooltip('Translate'));
      await settle(tester);
      expect(find.text('EN: Paarthal paarka thondrum'), findsNothing);
      expect(find.text('Lyrics · Lyrics library'), findsOneWidget);
      // romanize on lyrics already in Latin letters
      await tester.tap(find.byTooltip('Romanize'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('These lyrics already use Latin letters'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      sv.translator.override = null;
      sv.wireSources();
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('song mode: the line being sung under the title, with ›; tap opens lyrics; "Loading lyrics…" first', (tester) async {
      sv.lyrics
        ..order = (() => ['kugou'])
        ..off = (() => {'lrclib', 'ytm', 'ytcaptions', 'files', 'addons', 'musixmatch'});
      await tester.runAsync(() => sv.player.playItems([const Item(kind: ItemKind.song, id: 'thuli2', title: 'Thuli Thuli (From "Paiya")', artists: [ArtistRef('Yuvan Shankar Raja')], durationSec: 284)]));
      await tester.runAsync(() => sv.player.seek(const Duration(milliseconds: 57000)));
      await tester.runAsync(() => sv.player.pause());
      var tapped = 0;
      await tester.pumpWidget(MaterialApp(home: Scaffold(backgroundColor: Colors.black, body: Center(child: NextLyricLine(onTap: () => tapped++)))));
      expect(find.text('Loading lyrics…'), findsOneWidget);
      await settle(tester);
      await settle(tester);
      expect(find.text('Yendrey kaazhgal sozhuthada'), findsOneWidget, reason: 'the current line (56.7 s), not the next one');
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      await tester.tap(find.text('Yendrey kaazhgal sozhuthada'));
      expect(tapped, 1);
      sv.wireSources();
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('DJ: For you', () {
    Item s(String id, String title, String artist) => Item(kind: ItemKind.song, id: id, title: title, artists: [ArtistRef(artist)], durationSec: 200);
    test('songs both favourites point at rank first; known songs never come back; reasons say why', () {
      final seeds = [TasteSeed(s('a', 'Kesariya', 'Arijit Singh'), 12), TasteSeed(s('b', 'Tum Hi Ho', 'Arijit Singh'), 4)];
      final radios = [
        [s('x', 'Apna Bana Le', 'Arijit Singh'), s('y', 'Raataan Lambiyan', 'Jubin Nautiyal'), s('k', 'Known song', 'Z')],
        [s('y', 'Raataan Lambiyan', 'Jubin Nautiyal'), s('z', 'Pal', 'Arijit Singh')],
      ];
      final picks = ForYou.rank(seeds, radios, {'k'}, {'arijit singh': 5});
      expect(picks.map((p) => p.item.id), isNot(contains('k')));
      expect(picks.map((p) => p.item.id), isNot(contains('a')));
      final y = picks.firstWhere((p) => p.item.id == 'y');
      expect(y.reason, 'Because you play Kesariya and Tum Hi Ho');
      final x = picks.firstWhere((p) => p.item.id == 'x');
      expect(x.reason, 'Because you play Kesariya a lot');
      final z = picks.firstWhere((p) => p.item.id == 'z');
      expect(z.reason, 'Because you played Tum Hi Ho');
      expect(picks.length, 3);
    });

    test('a loved artist reached through another artist\'s song says so', () {
      final seeds = [TasteSeed(s('a', 'Thuli Thuli', 'Yuvan Shankar Raja'), 3)];
      final picks = ForYou.rank(seeds, [
        [s('n', 'New one', 'Anirudh')],
      ], {}, {'anirudh': 4});
      expect(picks.single.reason, 'More from Anirudh, one of your top artists');
    });

    test('one favourite\'s radio can\'t fill the whole list; reasons use short titles', () {
      final seeds = [TasteSeed(s('a', 'Apna Bana Le (From "Bhediya")', 'Arijit Singh'), 9), TasteSeed(s('b', 'Tum Hi Ho', 'Arijit Singh'), 3)];
      final picks = ForYou.rank(seeds, [
        [for (var i = 0; i < 12; i++) s('r$i', 'Song $i', 'Artist $i')],
        [for (var i = 0; i < 4; i++) s('q$i', 'Other $i', 'Other $i')],
      ], {}, {}, count: 8);
      expect(picks.length, 8);
      expect(picks.where((p) => p.item.id.startsWith('r')).length, lessThanOrEqualTo(6));
      expect(picks.where((p) => p.item.id.startsWith('q')).length, greaterThanOrEqualTo(2));
      expect(picks.first.reason, 'Because you play Apna Bana Le a lot');
    });

    test('at most 3 songs by one artist, so the list stays varied', () {
      final seeds = [TasteSeed(s('a', 'Seed', 'Q'), 1)];
      final picks = ForYou.rank(seeds, [
        [for (var i = 0; i < 6; i++) s('r$i', 'Song $i', 'Same Artist'), s('o', 'Other', 'Another')],
      ], {}, {});
      expect(picks.where((p) => p.item.artists.first.name == 'Same Artist').length, 3);
      expect(picks.any((p) => p.item.id == 'o'), isTrue);
    });

    testWidgets('DJ tab shows For you with reasons from real history, Play all plays them', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1600);
      addTearDown(tester.view.reset);
      final album = await tester.runAsync(() => sv.yt.album('MPREb_E4GfUXfDfhy'));
      for (final t in album!.tracks.take(3)) {
        await tester.runAsync(() => sv.library.addHistory(t));
      }
      ForYouSection.cached = null;
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CustomScrollView(slivers: [SliverToBoxAdapter(child: ForYouSection())]))));
      await settle(tester);
      await settle(tester);
      expect(find.text('For you'), findsOneWidget);
      expect(find.textContaining('Because you'), findsWidgets);
      await tester.tap(find.text('Play all'));
      await settle(tester);
      expect(sv.player.current.value, isNotNull);
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('Your data: genres via Last.fm', () {
    test('top artists\' tags, weighted by minutes, noise tags dropped', () async {
      final net = FakeNet((r, _) {
        expect(r.url.queryParameters['api_key'], 'k');
        final a = r.url.queryParameters['artist'];
        final tags = a == 'Arijit Singh'
            ? [
                {'name': 'bollywood', 'count': 100},
                {'name': 'seen live', 'count': 90},
                {'name': 'romantic', 'count': 40},
              ]
            : [
                {'name': 'tamil', 'count': 100},
                {'name': 'bollywood', 'count': 20},
              ];
        return jsonRes({
          'toptags': {'tag': tags},
        });
      });
      final g = await GenreGuesser(net).topGenres([('Arijit Singh', 300), ('Anirudh', 100)], 'k');
      expect(g.first.$1, 'Bollywood');
      expect(g.map((x) => x.$1), isNot(contains('Seen live')));
      expect(g.map((x) => x.$1), containsAll(['Tamil', 'Romantic']));
      expect(g.fold<double>(0, (a, b) => a + b.$2), closeTo(1, 0.001));
      await expectLater(GenreGuesser(net).topGenres([('X', 1)], ''), throwsStateError);
    });
  });
}
