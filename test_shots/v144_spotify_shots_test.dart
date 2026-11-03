// Byte © 2026 Apurba Laskar
// Golden screenshots for 1.4.4: Home with the logged-in account's row
// ("From Spotify", Liked Songs first) at 390 and 1280, and the
// "How sync works" sheet at 390.
// Run on its own: SHOTS_DIR=... flutter test test_shots/v144_spotify_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/data/spotify_account.dart';
import 'package:byte/data/spotify_sync.dart';
import 'package:byte/ui/screens/integrations_pages.dart';
import 'package:byte/ui/screens/home_screen.dart';
import 'package:byte/services.dart';
import 'package:byte/core/cover_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';

const _fonts = '/home/user/sdk/flutter/bin/cache/artifacts/material_fonts';
final _out = Platform.environment['SHOTS_DIR'] ?? 'build/shots/like';
final _art = File('test_shots/cover.png').readAsBytesSync();
final _busy = File('test_shots/busy.png').readAsBytesSync();

Future<void> _loadFonts() async {
  Future<ByteData> f(String p) async => ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer);
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Black']) {
    roboto.addFont(f('$_fonts/Roboto-$w.ttf'));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(f('$_fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

final _key = GlobalKey();

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final ro = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await ro.toImage(pixelRatio: 1);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Future<void> _pump(WidgetTester tester, {int n = 12}) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

class _Acc extends SpotifyAccount {
  _Acc(super.net);
  @override
  bool get connected => true;
  @override
  String get userName => 'Apurba';
  final ls = const [
    SpotifyPlaylistInfo('liked', 'Liked Songs', null, -1, 'Apurba'),
    SpotifyPlaylistInfo('pl_epic', '_epic.score', 'https://i.example/shot-cover-1', -1, 'Apurba'),
    SpotifyPlaylistInfo('pl_gym', 'Gym Bangers', 'https://i.example/shot-cover-2', -1, 'Apurba'),
    SpotifyPlaylistInfo('pl_drive', 'Late Night Drive', 'https://i.example/shot-cover-3', -1, 'Apurba'),
    SpotifyPlaylistInfo('pl_lofi', 'Lofi Study', 'https://i.example/shot-cover-4', -1, 'Apurba'),
  ];
  @override
  Future<List<SpotifyPlaylistInfo>> playlists() async => ls;
  @override
  Future<ExtList> read(SpotifyPlaylistInfo p, {void Function(String)? onStatus}) async =>
      ExtList(p.name, p.cover, [for (var i = 0; i < (p.id == 'liked' ? 48 : 24); i++) ExtTrack('Song $i ${p.id}', 'Artist')], MusicService.spotify, 'spotify:${p.id}');
}

void main() {
  late Services sv;

  setUpAll(() async {
    await _loadFonts();
    sv = await makeServices(net: FakeNet((r, body) => catalogue(r, body)));
    sv.settings.autoplay = false;
    sv.settings.font = 'Roboto';
    CoverCache.dir = Directory.systemTemp.createTempSync('byte_shots_');
    CoverCache.fetch = (u) async => u.contains('shot-cover') ? _art : _busy;
    SpotifySync.retryDelays = const [];
    final acc = _Acc(sv.net);
    sv.spotify = acc;
    final sy = SpotifySync(
      account: acc,
      library: sv.library,
      matcher: (ts, _) async => [
        for (final t in ts) Item(kind: ItemKind.song, id: 'm_${t.title.hashCode}', title: t.title, artists: [ArtistRef(t.artists)]),
      ],
    );
    await sy.open();
    await sy.forget();
    sv.spotifySync = sy;
    await sy.refreshLists();
    // the counts a sync learns (nothing imported: Home shows them anyway)
    for (final p in acc.ls) {
      await sy.importOne(p);
    }
  });

  testWidgets('spotify home shots', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    sv.settings.themeMode = ThemeMode.light;
    for (final size in const [Size(390, 844), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      tester.view.padding = size.width < 600 ? const FakeViewPadding(top: 44, bottom: 24) : FakeViewPadding.zero;
      await tester.pumpWidget(RepaintBoundary(key: _key, child: const ByteApp()));
      await _pump(tester, n: 16);
      expect(find.text('From Spotify'), findsOneWidget);
      await _shot(tester, 'home_spotify_${size.width.toInt()}');
      if (size.width < 600) {
        Navigator.of(tester.element(find.byType(HomeScreen))).push(MaterialPageRoute<void>(builder: (_) => const SpotifyAccountScreen()));
        await _pump(tester, n: 10);
        await tester.tap(find.byKey(const ValueKey('spotify-sync-help')));
        await _pump(tester, n: 10);
        expect(find.text('How sync works'), findsWidgets);
        await _shot(tester, 'sync_help_390');
      }
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, n: 3);
    }
  });
}
