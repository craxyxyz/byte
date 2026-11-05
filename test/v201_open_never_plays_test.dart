// Byte © 2026 Apurba Laskar.
//
// 2.0.1 (Apurba: "playlist ya Liked songs pe click karte hi seedha song play
// ho jata hai — mai sirf dekhna chahta hu"): opening a collection card only
// opens its page. Playing starts from a song row or the Play / Shuffle buttons.
import 'package:byte/core/models.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/home_library_rows.dart';
import 'package:byte/ui/screens/library_pages.dart' show LikedScreen;
import 'package:byte/ui/screens/library_screen.dart';
import 'package:byte/ui/screens/playlist_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Item song(String id) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('Arijit Singh')], durationSec: 200);

void main() {
  late Services sv;

  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    await sv.spotify.open();
    await sv.spotifySync.open();
    await sv.libSync.open();
    sv.dj;
  });

  setUp(() async {
    for (final p in sv.library.playlists) {
      await sv.library.deletePlaylist(p.id);
    }
    for (final l in sv.library.likes) {
      await sv.library.setLiked(l, false);
    }
  });

  Future<T> act<T>(WidgetTester tester, Future<T> Function() f) async {
    final out = await tester.runAsync(f);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return out as T;
  }

  // Songs get ids unique to each test: the player keeps its last song after a
  // stop, so "nothing started" is "the current song is not one of ours".
  Future<void> seed(WidgetTester tester, String tag) => act(tester, () async {
    await sv.library.setLiked(song('$tag-l1'), true);
    await sv.library.setLiked(song('$tag-l2'), true);
    await sv.library.createPlaylist('Road Trip', items: [song('$tag-r1'), song('$tag-r2')]);
  });

  bool started(String tag) => sv.player.current.value?.id.startsWith(tag) ?? false;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> done(WidgetTester tester) async {
    if (sv.player.current.value != null) await act(tester, () => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('Home: tapping the Liked card shows the list and plays nothing', (tester) async {
    phone(tester);
    await seed(tester, 'a');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: HomeLibraryRows()))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('home-liked')));
    await settle(tester);
    expect(find.byType(LikedScreen), findsOneWidget);
    expect(started('a'), isFalse);
    await done(tester);
  });

  testWidgets('Home: the little play button on the Liked card still plays', (tester) async {
    phone(tester);
    await seed(tester, 'b');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: HomeLibraryRows()))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('home-liked-play')));
    await settle(tester);
    expect(started('b'), isTrue);
    await done(tester);
  });

  testWidgets('Home: tapping a playlist card shows the playlist and plays nothing', (tester) async {
    phone(tester);
    await seed(tester, 'c');
    final road = sv.library.playlists.firstWhere((p) => p.name == 'Road Trip');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: HomeLibraryRows()))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ValueKey('home-pl-${road.id}')));
    await settle(tester);
    expect(find.byType(PlaylistScreen), findsOneWidget);
    expect(started('c'), isFalse);
    expect(sv.library.playlistPlayed.containsKey(road.id), isFalse, reason: 'only really playing counts as played');
    await done(tester);
  });

  testWidgets('Library: Liked Songs and a playlist open without playing', (tester) async {
    phone(tester);
    await seed(tester, 'd');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: LibraryScreen())));
    await settle(tester);
    await tester.ensureVisible(find.text('Liked Songs').first);
    await tester.pump();
    await tester.tap(find.text('Liked Songs').first);
    await settle(tester);
    expect(find.byType(LikedScreen), findsOneWidget);
    expect(started('d'), isFalse);
    Navigator.of(tester.element(find.byType(LikedScreen))).pop();
    await settle(tester);
    await tester.ensureVisible(find.text('Road Trip').first);
    await tester.pump();
    await tester.tap(find.text('Road Trip').first);
    await settle(tester);
    expect(find.byType(PlaylistScreen), findsOneWidget);
    expect(started('d'), isFalse);
    await done(tester);
  });

  testWidgets('Liked page: Play button and a song row start playback', (tester) async {
    phone(tester);
    await seed(tester, 'e');
    await tester.pumpWidget(const MaterialApp(home: LikedScreen()));
    await settle(tester);
    expect(started('e'), isFalse, reason: 'just viewing');
    await tester.tap(find.text('Play').first);
    await settle(tester);
    expect(started('e'), isTrue);
    await act(tester, () => sv.player.stop());
    await tester.tap(find.text('Song e-l1').first);
    await settle(tester);
    expect(sv.player.current.value?.id, 'e-l1');
    await done(tester);
  });

  testWidgets('Playlist page: viewing plays nothing; Play and Shuffle buttons + song row play', (tester) async {
    phone(tester);
    await seed(tester, 'f');
    final road = sv.library.playlists.firstWhere((p) => p.name == 'Road Trip');
    await tester.pumpWidget(MaterialApp(home: PlaylistScreen(id: road.id)));
    await settle(tester);
    expect(started('f'), isFalse);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Shuffle'), findsOneWidget);
    await tester.tap(find.text('Play'));
    await settle(tester);
    expect(started('f'), isTrue);
    await act(tester, () => sv.player.stop());
    await tester.tap(find.text('Song f-r2').first);
    await settle(tester);
    expect(sv.player.current.value?.id, 'f-r2');
    await done(tester);
  });
}
