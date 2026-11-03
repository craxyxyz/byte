
import 'package:byte/data/playlist_import.dart' show ExtTrack;
import 'package:byte/data/service_library.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/import_sheet.dart';
import 'package:byte/ui/music_apps.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  setUp(() async {
    final sv = await makeServices();
    Services.i = sv;
    await sv.spotify.open();
    await sv.spotify.disconnect();
    await sv.scrobbler.open();
    await sv.spotifySync.open();
    await sv.libSync.open();
  });

  testWidgets('Music apps: every app listed, each opens its page with Log in and an honest note', (t) async {
    t.view.physicalSize = const Size(390 * 3, 1800 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: MusicAppsScreen()));
    await t.pump(const Duration(milliseconds: 300));
    for (final n in ['Spotify', 'YouTube Music', 'Amazon Music', 'Apple Music', 'JioSaavn', 'Gaana', 'SoundCloud', 'Deezer']) {
      expect(find.text(n), findsOneWidget, reason: n);
    }
    expect(find.text('Tap to log in'), findsNWidgets(8));
    await t.tap(find.byKey(const ValueKey('music-app-amazon')));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('music-app-login')), findsOneWidget);
    expect(find.textContaining('Opens Amazon Music\'s own login page'), findsOneWidget);
    expect(find.textContaining('Amazon Music\'s own pages'), findsOneWidget);
  });

  testWidgets('a logged-in app shows Sync now and Log out; log out keeps the playlists', (t) async {
    final sv = Services.i;
    // 1.4.2: an import needs at least one song (a 0-song read is a problem, not a log-in)
    await t.runAsync(() => sv.libSync.importSnapshot(LibService.deezer, const LibSnapshot('apurba', [ExtTrack('Tum Hi Ho', 'Arijit Singh')], [])));
    await t.pumpWidget(const MaterialApp(home: MusicAppAccountScreen(service: LibService.deezer)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('apurba'), findsWidgets);
    expect(find.byKey(const ValueKey('music-app-sync')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-app-logout')), findsOneWidget);
    await t.runAsync(() => logOutMusicApp(LibService.deezer));
    await t.pump(const Duration(milliseconds: 300));
    expect(sv.libSync.connected(LibService.deezer), isFalse);
    expect(find.byKey(const ValueKey('music-app-login')), findsOneWidget);
  });

  testWidgets('Account & integrations lists the other music apps', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2600 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: AccountScreen()));
    await t.pump(const Duration(milliseconds: 300));
    for (final s in ['youtubeMusic', 'amazon', 'apple', 'jiosaavn', 'gaana', 'soundcloud', 'deezer']) {
      expect(find.byKey(ValueKey('account-music-app-$s')), findsOneWidget, reason: s);
    }
  });

  testWidgets('Import screen: pick a music app, the Log in button and note follow the pick', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: ImportScreen(initial: '')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('import-login-picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-login-button')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('import-login-picker')));
    await t.pumpAndSettle();
    await t.tap(find.text('JioSaavn').last);
    await t.pumpAndSettle();
    expect(find.textContaining('mobile number'), findsOneWidget);
  });
}
