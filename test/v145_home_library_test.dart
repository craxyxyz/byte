@Timeout(Duration(seconds: 120))
library;

// Byte © 2026 Apurba Laskar
// 1.4.5 (Apurba, Nov 3: "Byte account se login karne ke baad liked songs home
// page pe kyun nahi aa rahe? Agar koi Byte app pe playlist banaye toh woh home
// page pe hi show hona chahiye"): Home shows "Liked songs" and "Your
// playlists" for every account — Byte email, music-app log-in or signed out —
// and keeps them live (likes, new / renamed / deleted playlists, songs added,
// and whatever a sync pull brings from the Byte account).
import 'dart:convert';
import 'dart:io';

import 'package:byte/core/models.dart';
import 'package:byte/data/cloud_sync.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/home_library_rows.dart';
import 'package:byte/ui/screens/home_screen.dart';
import 'package:byte/ui/screens/library_pages.dart' show LikedScreen;
import 'package:byte/ui/screens/playlist_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'helpers.dart';

Item song(String id, [String? title]) => Item(kind: ItemKind.song, id: id, title: title ?? 'Song $id', artists: const [ArtistRef('Arijit Singh')], durationSec: 200);

/// The Byte account's server as the phone sees it: rows to pull, then
/// (optionally) a dropped connection or "tables not made yet".
class FakeServer implements SyncBackend {
  final List<SyncRow> rows;
  bool notReady = false;
  bool dropAfterFirstPage = false;
  int pulls = 0;
  final pushed = <SyncRow>[];
  FakeServer(this.rows);

  @override
  Future<List<SyncRow>> pull(int afterSeq, {int limit = 500}) async {
    pulls++;
    if (notReady) throw const SyncNotReady('relation "public.byte_records" does not exist');
    if (dropAfterFirstPage && afterSeq > 0) throw const SocketException('connection reset');
    return rows.where((r) => r.seq > afterSeq).take(limit).toList();
  }

  @override
  Future<void> push(List<SyncRow> rows) async {
    if (notReady) throw const SyncNotReady('relation "public.byte_records" does not exist');
    pushed.addAll(rows);
  }

  @override
  Stream<void> changes() => const Stream.empty();
  @override
  Future<void> close() async {}
}

SyncRow likeRow(int seq, String id, {int at = 5}) => SyncRow(
  collection: 'likes',
  id: id,
  payload: {
    'v': jsonEncode({'item': song(id, 'Server song $id').toJson(), 'at': at}),
  },
  updatedAt: 1000 + seq,
  device: 'other-phone',
  seq: seq,
);

SyncRow playlistRow(int seq, String id, String name, List<Item> items, {int updated = 1700000000000}) => SyncRow(
  collection: 'playlists',
  id: id,
  payload: {
    'v': jsonEncode({'id': id, 'n': name, 'i': [for (final i in items) i.toJson()], 'c': updated, 'u': updated}),
  },
  updatedAt: 1000 + seq,
  device: 'other-phone',
  seq: seq,
);

void main() {
  late Services sv;
  var syncN = 0;

  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    // open the music-app boxes here (outside the widget tests' fake clock)
    await sv.spotify.open();
    await sv.spotifySync.open();
    await sv.libSync.open();
    // made here, not lazily inside a widget test's fake clock (Home's DJ pill)
    sv.dj;
  });

  setUp(() async {
    for (final p in sv.library.playlists) {
      await sv.library.deletePlaylist(p.id);
    }
    for (final l in sv.library.likes) {
      await sv.library.setLiked(l, false);
    }
    // compact here (real clock), so the storage never compacts itself in the
    // middle of a widget test's fake clock
    for (final b in ['likes', 'playlists', 'library_misc', 'history']) {
      await Hive.box(b).compact();
    }
  });

  Future<void> clearLibrary(WidgetTester tester) async {}

  /// Runs [f] on the real clock (the library's storage is real file I/O),
  /// then lets Home rebuild.
  Future<T> act<T>(WidgetTester tester, Future<T> Function() f) async {
    final out = await tester.runAsync(f);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return out as T;
  }

  Future<void> home(WidgetTester tester, {Size size = const Size(390, 844), bool full = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: full ? const HomeScreen() : const SingleChildScrollView(child: HomeLibraryRows()))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> done(WidgetTester tester) async {
    if (sv.player.current.value != null) await act(tester, () => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('empty: no Liked card, "Your playlists" still shows with its New playlist tile', (tester) async {
    addTearDown(tester.view.reset);
    await clearLibrary(tester);
    await home(tester);
    expect(find.byKey(const ValueKey('home-liked')), findsNothing);
    expect(find.text('Your playlists'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-new-playlist')), findsOneWidget);
    expect(find.text('New playlist'), findsOneWidget);
    expect(find.text('See all'), findsNothing);
    await done(tester);
  });

  testWidgets('live: like / unlike, create / rename / add song / delete playlist update Home at once', (tester) async {
    addTearDown(tester.view.reset);
    await clearLibrary(tester);
    await home(tester);
    expect(find.byKey(const ValueKey('home-liked')), findsNothing);

    await act(tester, () => sv.library.toggleLike(song('a')));
    await settle(tester);
    expect(find.byKey(const ValueKey('home-liked')), findsOneWidget);
    expect(find.text('1 song'), findsOneWidget);
    await act(tester, () => sv.library.toggleLike(song('b')));
    await settle(tester);
    expect(find.text('2 songs'), findsOneWidget);
    await act(tester, () => sv.library.toggleLike(song('a')));
    await settle(tester);
    expect(find.text('1 song'), findsOneWidget);

    final pl = await act(tester, () => sv.library.createPlaylist('Chill Evenings'));
    await settle(tester);
    expect(find.byKey(ValueKey('home-pl-${pl.id}')), findsOneWidget);
    expect(find.text('Chill Evenings'), findsOneWidget);
    expect(find.text('0 songs'), findsOneWidget);
    expect(find.text('See all'), findsOneWidget);

    await act(tester, () => sv.library.renamePlaylist(pl.id, 'Sunday Chill'));
    await settle(tester);
    expect(find.text('Chill Evenings'), findsNothing);
    expect(find.text('Sunday Chill'), findsOneWidget);

    await act(tester, () => sv.library.addToPlaylist(pl.id, [song('c'), song('d')]));
    await settle(tester);
    final card = find.byKey(ValueKey('home-pl-${pl.id}'));
    expect(find.descendant(of: card, matching: find.text('2 songs')), findsOneWidget);

    await act(tester, () => sv.library.deletePlaylist(pl.id));
    await settle(tester);
    expect(find.text('Sunday Chill'), findsNothing);
    expect(find.byKey(const ValueKey('home-new-playlist')), findsOneWidget);
    await done(tester);
  });

  testWidgets('"Your playlists": most recently played or edited first (pinned first)', (tester) async {
    addTearDown(tester.view.reset);
    await clearLibrary(tester);
    late String a, b, c;
    await act(tester, () async {
      a = (await sv.library.createPlaylist('Alpha', items: [song('x1')])).id;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      b = (await sv.library.createPlaylist('Beta', items: [song('x2')])).id;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      c = (await sv.library.createPlaylist('Gamma', items: [song('x3')])).id;
    });
    List<String> order() => byteMadePlaylists(sv.library).map((p) => p.id).toList();
    expect(order(), [c, b, a]);
    await act(tester, () async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sv.library.notePlaylistPlayed(a);
    });
    expect(order(), [a, c, b]);
    await act(tester, () async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sv.library.addToPlaylist(b, [song('x9')]);
    });
    expect(order(), [b, a, c]);
    await act(tester, () => sv.library.setPinned(c, true));
    expect(order(), [c, b, a]);
    await act(tester, () => sv.library.setPinned(c, false));

    // on screen, left to right
    await home(tester, size: const Size(1280, 800));
    final xs = [for (final id in [b, a, c]) tester.getTopLeft(find.byKey(ValueKey('home-pl-$id'))).dx];
    expect(xs[0], lessThan(xs[1]));
    expect(xs[1], lessThan(xs[2]));
    // the + tile comes first
    expect(tester.getTopLeft(find.byKey(const ValueKey('home-new-playlist'))).dx, lessThan(xs[0]));
    await done(tester);
  });

  testWidgets('"New playlist" tile asks for a name (the same "New playlist" flow as Library)', (tester) async {
    addTearDown(tester.view.reset);
    await home(tester);
    await tester.tap(find.byKey(const ValueKey('home-new-playlist')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Playlist name'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TextField), findsNothing);
    expect(sv.library.playlists, isEmpty);
    await done(tester);
  });

  testWidgets('signed in with a Byte (email) account: likes and playlists pulled from the server appear on Home', (tester) async {
    addTearDown(tester.view.reset);
    await clearLibrary(tester);
    final server = FakeServer([
      likeRow(1, 'srv1'),
      likeRow(2, 'srv2'),
      playlistRow(3, 'pl_srv_1', 'Made on my laptop', [song('m1'), song('m2'), song('m3')]),
      playlistRow(4, 'pl_srv_2', 'Old Hindi', [song('o1')]),
    ]);
    final sync = CloudSync(
      backendFor: () => server,
      deviceId: 'this-phone-${++syncN}',
      onApplied: sv.cloudApplied,
      debounce: const Duration(hours: 1),
      lazyEvery: const Duration(hours: 1),
    );
    await home(tester);
    expect(find.byKey(const ValueKey('home-liked')), findsNothing);
    expect(find.text('Made on my laptop'), findsNothing);
    await act(tester, () => sync.start('byte-user-$syncN'));
    await settle(tester);
    expect(sync.state, SyncState.synced);
    expect(find.text('Liked songs'), findsOneWidget);
    expect(find.text('2 songs'), findsOneWidget);
    expect(find.text('Made on my laptop'), findsOneWidget);
    expect(find.text('Old Hindi'), findsOneWidget);
    expect(find.text('3 songs'), findsOneWidget);

    // a like made on the other device arrives with the next pull
    server.rows.add(likeRow(5, 'srv3', at: 9));
    await act(tester, () => sync.syncNow());
    await settle(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('home-liked')), matching: find.text('3 songs')), findsOneWidget);
    await act(tester, () => sync.stop());
    // signed out again: what came down stays on the phone and on Home
    await settle(tester);
    expect(find.text('Made on my laptop'), findsOneWidget);
    await done(tester);
  });

  testWidgets('a first pull that drops half way still shows what arrived; server not set up: friendly state, local data stays', (tester) async {
    addTearDown(tester.view.reset);
    await clearLibrary(tester);
    final server = FakeServer([for (var i = 1; i <= 500; i++) likeRow(i, 'bulk$i')])..dropAfterFirstPage = true;
    final sync = CloudSync(
      backendFor: () => server,
      deviceId: 'this-phone-${++syncN}',
      onApplied: sv.cloudApplied,
      debounce: const Duration(hours: 1),
      lazyEvery: const Duration(hours: 1),
    );
    await home(tester);
    await act(tester, () => sync.start('byte-user-$syncN'));
    await settle(tester);
    expect(sync.state, SyncState.offline);
    expect(server.pulls, 2);
    expect(find.text('500 songs'), findsOneWidget);
    await act(tester, () => sync.stop());

    // his new server before its tables exist
    await clearLibrary(tester);
    await act(tester, () => sv.library.createPlaylist('Only on this phone', items: [song('p1')]));
    final empty = FakeServer(const [])..notReady = true;
    final sync2 = CloudSync(
      backendFor: () => empty,
      deviceId: 'this-phone-${++syncN}',
      onApplied: sv.cloudApplied,
      debounce: const Duration(hours: 1),
      lazyEvery: const Duration(hours: 1),
    );
    await act(tester, () => sync2.start('byte-user-$syncN'));
    await settle(tester);
    expect(sync2.state, SyncState.notReady);
    expect(sync2.message, contains('not switched on on the server yet'));
    expect(find.text('Only on this phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await act(tester, () => sync2.stop());
    await done(tester);
  });

  testWidgets('wide (1280): Liked card and shelf lay out without overflow', (tester) async {
    addTearDown(tester.view.reset);
    await clearLibrary(tester);
    await act(tester, () async {
      for (var i = 0; i < 4; i++) {
        await sv.library.setLiked(song('w$i'), true);
      }
      for (var i = 0; i < 9; i++) {
        await sv.library.createPlaylist('A playlist with a really long name number $i', items: [song('wp$i')]);
      }
    });
    for (final size in const [Size(390, 844), Size(1280, 800), Size(320, 640)]) {
      await home(tester, size: size);
      expect(tester.takeException(), isNull, reason: '$size');
      expect(find.byKey(const ValueKey('home-liked')), findsOneWidget);
      final w = tester.getSize(find.byKey(const ValueKey('home-liked'))).width;
      expect(w, lessThanOrEqualTo(size.width >= 700 ? 520 : size.width - 32));
    }
    await done(tester);
  });

  testWidgets('signed out, local data: likes and Byte playlists show at the top; imported lists keep their own row', (tester) async {
    addTearDown(tester.view.reset);
    await clearLibrary(tester);
    await act(tester, () async {
      await sv.library.setLiked(song('l1'), true);
      await sv.library.setLiked(song('l2'), true);
      await sv.library.setLiked(song('l3'), true);
      await sv.library.createPlaylist('Road Trip', items: [song('r1'), song('r2')]);
      await sv.library.createPlaylist('Gym Bangers', items: [song('g1')], source: 'spotify:pl_gym');
    });
    await home(tester, full: true);
    expect(find.text('Liked songs'), findsOneWidget);
    expect(find.text('3 songs'), findsOneWidget);
    expect(find.text('Road Trip'), findsOneWidget);
    // the imported one is not in "Your playlists"
    final mine = find.byKey(const ValueKey('home-your-playlists-list'));
    expect(find.descendant(of: mine, matching: find.text('Gym Bangers')), findsNothing);
    expect(find.descendant(of: mine, matching: find.text('Road Trip')), findsOneWidget);
    expect(find.text('From Spotify'), findsOneWidget, reason: 'imported lists: their own shelf per app, right below');
    // the Liked card and "Your playlists" are above everything else on Home
    final top = tester.getTopLeft(find.byKey(const ValueKey('home-liked'))).dy;
    final pls = tester.getTopLeft(find.text('Your playlists')).dy;
    expect(top, lessThan(pls));
    for (final other in ['From Spotify', 'Top Picks for You', 'Recents', 'Quick picks', 'Find Your Mood']) {
      final f = find.text(other);
      if (f.evaluate().isNotEmpty) expect(tester.getTopLeft(f.first).dy, greaterThan(pls), reason: other);
    }
    // tap Liked songs: opens the list, nothing starts playing (2.0.1)
    await tester.tap(find.byKey(const ValueKey('home-liked')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(sv.player.current.value, isNull, reason: 'opening Liked songs must not start a song');
    expect(find.byType(LikedScreen, skipOffstage: false), findsWidgets);
    // tap a playlist: opens it, nothing plays
    // (last in this file: these taps write from inside the test clock)
    Navigator.of(tester.element(find.byType(HomeScreen))).popUntil((r) => r.isFirst);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 150));
    }
    final road = sv.library.playlists.firstWhere((p) => p.name == 'Road Trip');
    await tester.tap(find.byKey(ValueKey('home-pl-${road.id}')));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(sv.player.current.value, isNull, reason: 'opening a playlist must not start a song');
    expect(find.byType(PlaylistScreen, skipOffstage: false), findsWidgets);
    expect(sv.library.playlistPlayed.containsKey(road.id), isFalse);
    await done(tester);
  });
}
