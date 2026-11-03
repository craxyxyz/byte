@Timeout(Duration(seconds: 120))
library;

// Byte © 2026 Apurba Laskar
// 1.4.5 (Apurba, 9:18 PM: "Agar koi Spotify ya dusre platform se import kare
// toh playlist isi tarah hi show karega?"): imported playlists show on Home as
// the same cards as "Your playlists", one "From <app>" shelf per app, right
// below "Your playlists", for every import source, live after an import.
import 'package:byte/core/models.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/home_library_rows.dart';
import 'package:byte/ui/imported_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Item song(String id) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('Arijit Singh')], durationSec: 200);

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  testWidgets('every import source gets its own "From <app>" shelf below "Your playlists", same cards, live', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await sv.library.createPlaylist('Road Trip', items: [song('r1')]);
      await sv.library.createPlaylist('Gym', items: [song('g1'), song('g2')], source: 'spotify:pl_gym');
      await sv.library.createPlaylist('Romantic', items: [song('j1')], source: 'jiosaavn:J1');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // const, as on Home: each row must listen to the library itself
          body: SingleChildScrollView(child: Column(children: [HomeLibraryRows(), ImportedRow()])),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('From Spotify'), findsOneWidget);
    expect(find.text('From JioSaavn'), findsOneWidget);
    expect(find.text('From your music apps'), findsNothing);
    // right below "Your playlists"
    final mine = tester.getTopLeft(find.text('Your playlists')).dy;
    expect(tester.getTopLeft(find.text('From Spotify')).dy, greaterThan(mine));
    // the same card size as "Your playlists"
    final gym = sv.library.playlists.firstWhere((p) => p.source == 'spotify:pl_gym');
    final road = sv.library.playlists.firstWhere((p) => p.name == 'Road Trip');
    final importedCard = tester.getSize(find.byKey(ValueKey('home-import-${gym.id}')));
    final mineCard = tester.getSize(find.byKey(ValueKey('home-pl-${road.id}')));
    expect(importedCard, mineCard, reason: 'same card as "Your playlists"');
    expect(find.text('2 songs'), findsWidgets);
    // live: a new import from another app shows at once
    await tester.runAsync(() async {
      await sv.library.createPlaylist('Chill', items: [song('a1')], source: 'apple:A1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('From Apple Music', skipOffstage: false), findsOneWidget);
    // a web page / song list / file import: one "Imported lists" shelf, source on the card
    await tester.runAsync(() async {
      await sv.library.createPlaylist('From a blog', items: [song('w1')], source: 'web:https://x');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Imported lists', skipOffstage: false), findsOneWidget);
    expect(find.text('Web page · 1 song', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
