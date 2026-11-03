// Byte © 2026 Apurba Laskar
import 'package:byte/core/models.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/data/service_library.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/imported_row.dart';
import 'package:byte/ui/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 1.4.2 (Apurba, Nov 3): playlists and liked songs from SEVERAL music
// apps live side by side, and they're the first row on Home.
void main() {
  late Services sv;
  late LibrarySync sync;
  var matched = 0;

  // Every song is "found" as a song whose id is its title (so the same song
  // from two apps is the same Byte song).
  Future<List<Item?>> matcher(List<ExtTrack> ts, void Function(int, int) progress) async {
    matched += ts.length;
    return [
      for (final t in ts) t.title.startsWith('Unknown') ? null : Item(kind: ItemKind.song, id: 'yt_${t.title.toLowerCase().replaceAll(' ', '_')}', title: t.title, artists: [ArtistRef(t.artists)]),
    ];
  }

  ExtTrack t(String title, [String artist = 'Arijit Singh']) => ExtTrack(title, artist);

  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sync = LibrarySync(library: sv.library, matcher: matcher);
    await sync.open();
  });

  setUp(() async {
    for (final p in sv.library.playlists) {
      await sv.library.deletePlaylist(p.id);
    }
    for (final l in sv.library.likes) {
      await sv.library.setLiked(l, false);
    }
    for (final s in LibService.values) {
      await sync.forget(s);
    }
  });

  test('two apps: both apps\' playlists and likes coexist; same-named lists stay separate; re-sync touches only its own app', () async {
    final amazon = await sync.importSnapshot(
      LibService.amazon,
      LibSnapshot(
        'Apurba',
        [t('Kesariya'), t('Tum Hi Ho')],
        [
          LibPlaylist('A1', 'Romantic', [t('Kesariya'), t('Raabta')]),
          LibPlaylist('A2', 'Gym', [t('Zinda', 'Siddharth Mahadevan')]),
        ],
      ),
    );
    expect(amazon.liked, 2);
    expect(amazon.playlists, 2);

    final saavn = await sync.importSnapshot(
      LibService.jiosaavn,
      LibSnapshot(
        'Apurba',
        [t('Tum Hi Ho'), t('Apna Bana Le')],
        [
          LibPlaylist('J1', 'Romantic', [t('Pehla Nasha', 'Udit Narayan')]),
        ],
      ),
    );
    expect(saavn.playlists, 1);

    final lists = sv.library.playlists;
    expect(lists.length, 3, reason: 'the second app added to the first, replaced nothing');
    final romantic = lists.where((p) => p.name == 'Romantic').toList();
    expect(romantic.length, 2, reason: 'same name, two apps, two playlists');
    expect(romantic.map((p) => importSourceLabel(p.source)).toSet(), {'Amazon Music', 'JioSaavn'});
    // likes from both apps merged, each song once
    expect(sv.library.likes.map((i) => i.id).toSet(), {'yt_kesariya', 'yt_tum_hi_ho', 'yt_apna_bana_le'});
    expect(sv.library.likes.length, 3);

    // re-sync Amazon with a changed "Romantic": only Amazon's list changes
    await sync.importSnapshot(
      LibService.amazon,
      LibSnapshot(
        'Apurba',
        [t('Kesariya')],
        [
          LibPlaylist('A1', 'Romantic', [t('Kesariya'), t('Raabta'), t('Agar Tum Saath Ho')]),
          LibPlaylist('A2', 'Gym', [t('Zinda', 'Siddharth Mahadevan')]),
        ],
      ),
    );
    final after = sv.library.playlists;
    expect(after.length, 3);
    final az = after.firstWhere((p) => p.source == 'amazon:A1');
    final js = after.firstWhere((p) => p.source == 'jiosaavn:J1');
    expect(az.items.length, 3);
    expect(js.items.map((i) => i.title), ['Pehla Nasha'], reason: 'the other app\'s list is untouched');
    expect(sync.connected(LibService.amazon) && sync.connected(LibService.jiosaavn), isTrue);
    expect(sync.playlistCount(LibService.amazon), 2);
    expect(sync.playlistCount(LibService.jiosaavn), 1);
  });

  test('two imports at the same moment run one after the other, nothing lost', () async {
    final a = sync.importSnapshot(
      LibService.gaana,
      LibSnapshot(
        'A',
        [t('Kal Ho Naa Ho', 'Sonu Nigam')],
        [
          LibPlaylist('G1', 'Old', [t('Kal Ho Naa Ho', 'Sonu Nigam')]),
        ],
      ),
    );
    final b = sync.importSnapshot(
      LibService.deezer,
      LibSnapshot(
        'A',
        [t('Blinding Lights', 'The Weeknd')],
        [
          LibPlaylist('D1', 'Old', [t('Levitating', 'Dua Lipa')]),
        ],
      ),
    );
    await Future.wait([a, b]);
    expect(sv.library.playlists.length, 2);
    expect(sv.library.likes.length, 2);
  });

  test('logged in but 0 songs read: a clear problem with details, not "0 imported"', () async {
    await expectLater(
      sync.importSnapshot(LibService.jiosaavn, const LibSnapshot('Apurba', [], [])),
      throwsA(isA<LibProblem>().having((e) => e.message, 'message', contains('couldn\'t read any songs')).having((e) => e.details, 'details', contains('service=jiosaavn'))),
    );
    expect(sync.connected(LibService.jiosaavn), isFalse);
  });

  test('a playlist whose songs can\'t be found is reported, and a later empty read never wipes a list', () async {
    final r = await sync.importSnapshot(
      LibService.apple,
      LibSnapshot('A', [], [
        LibPlaylist('P1', 'Good', [t('Raabta')]),
        LibPlaylist('P2', 'Rare', [t('Unknown song 1'), t('Unknown song 2')]),
      ]),
    );
    expect(r.playlists, 1);
    expect(r.emptyPlaylists, ['Rare']);
    await sync.importSnapshot(
      LibService.apple,
      LibSnapshot('A', [], [
        LibPlaylist('P1', 'Good', [t('Unknown now')]),
      ]),
    );
    expect(sv.library.playlistBySource('apple:P1')!.items.map((i) => i.title), ['Raabta']);
  });

  test('a page that answers "ok: false, retry" asks to read again', () {
    expect(() => parseLibraryMessage(LibService.deezer, {'ok': false, 'retry': true, 'error': 'The page changed'}), throwsA(isA<LibProblem>().having((e) => e.retry, 'retry', isTrue)));
  });

  test('source labels for each app', () {
    expect(importSourceLabel('spotify:x'), 'Spotify');
    expect(importSourceLabel('account:VL123'), 'YouTube Music');
    expect(importSourceLabel('soundcloud:9'), 'SoundCloud');
    expect(importSourceLabel(null), isNull);
    expect(importSourceLabel('pl_123'), isNull);
    expect(matched, greaterThan(0));
  });
  testWidgets('Home: imported playlists from every app + Liked songs are the FIRST row; tap plays and opens', (tester) async {
    // nothing imported yet: no row at all
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ImportedRow())));
    expect(find.byKey(const ValueKey('home-imports')), findsNothing);
    await tester.runAsync(() async {
      await sync.importSnapshot(
        LibService.amazon,
        LibSnapshot(
          'A',
          [t('Kesariya')],
          [
            LibPlaylist('A1', 'Romantic', [t('Kesariya'), t('Raabta')]),
          ],
        ),
      );
      await sync.importSnapshot(
        LibService.jiosaavn,
        LibSnapshot(
          'A',
          [t('Tum Hi Ho')],
          [
            LibPlaylist('J1', 'Romantic', [t('Pehla Nasha', 'Udit Narayan')]),
          ],
        ),
      );
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Liked songs only shows once an app is connected — LibrarySync in the
    // services is a different instance in tests, so check the playlists here.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: HomeScreen())));
    await tester.pump(const Duration(milliseconds: 500));
    // 1.4.4: each logged-in app has its own row ("From Amazon Music",
    // "From JioSaavn"); "From your music apps" keeps only the rest.
    expect(find.text('From Amazon Music'), findsOneWidget);
    expect(find.text('From JioSaavn'), findsOneWidget);
    expect(find.text('From your music apps'), findsNothing);
    expect(find.text('2 songs'), findsOneWidget);
    expect(find.text('Romantic'), findsNWidgets(2));
    // first section: above every other title on Home
    final row = tester.getTopLeft(find.byKey(const ValueKey('home-service-rows'))).dy;
    for (final other in ['Top Picks for You', 'Recents', 'Quick picks', 'Find Your Mood']) {
      final f = find.text(other);
      if (f.evaluate().isNotEmpty) expect(tester.getTopLeft(f.first).dy, greaterThan(row), reason: other);
    }
    // tap: plays that playlist and opens it
    final saavnRomantic = sv.library.playlists.firstWhere((p) => p.source == 'jiosaavn:J1');
    await tester.tap(find.byKey(ValueKey('home-service-${saavnRomantic.id}')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(sv.player.current.value?.title, 'Pehla Nasha');
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });
}
