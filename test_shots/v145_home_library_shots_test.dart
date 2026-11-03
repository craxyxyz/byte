// Byte © 2026 Apurba Laskar
// Golden screenshots for 1.4.5: Home with "Liked songs" and "Your playlists"
// (playlists made in Byte) at the top, phone (390) and wide (1280).
// Run on its own: SHOTS_DIR=... flutter test test_shots/v145_home_library_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/models.dart';
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

Item _song(int i, {bool cover = true}) => Item(
  kind: ItemKind.song,
  id: 'homeShot$i',
  title: 'Song $i',
  artists: const [ArtistRef('Aarav Sen')],
  durationSec: 200,
  thumb: cover ? 'https://lh3.googleusercontent.com/shot-cover-$i=w226-h226' : null,
);

void main() {
  late Services sv;

  setUpAll(() async {
    await _loadFonts();
    sv = await makeServices(net: FakeNet((r, body) => catalogue(r, body)));
    sv.settings.autoplay = false;
    sv.settings.font = 'Roboto';
    CoverCache.dir = Directory.systemTemp.createTempSync('byte_shots_');
    CoverCache.fetch = (u) async => u.contains('shot-cover') ? _art : _busy;
    for (final p in sv.library.playlists) {
      await sv.library.deletePlaylist(p.id);
    }
    for (var i = 0; i < 37; i++) {
      await sv.library.setLiked(_song(i), true);
    }
    // made in Byte (on this phone or pulled from the Byte account)
    final names = ['Bengali Classics', 'Gym Bangers', 'Late Night Lofi', 'Road Trip 2026'];
    for (var n = 0; n < names.length; n++) {
      await sv.library.createPlaylist(names[n], items: [for (var i = 0; i < 6 + n * 5; i++) _song(100 + n * 20 + i)]);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    // a brand-new one, still empty
    await sv.library.createPlaylist('New Year Party');
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final last = sv.library.playlists.firstWhere((p) => p.name == 'Road Trip 2026');
    await sv.library.notePlaylistPlayed(last.id);
  });

  testWidgets('home library shots', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    sv.settings.themeMode = ThemeMode.light;
    for (final size in const [Size(390, 844), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      tester.view.padding = size.width < 600 ? const FakeViewPadding(top: 44, bottom: 24) : FakeViewPadding.zero;
      await tester.pumpWidget(RepaintBoundary(key: _key, child: const ByteApp()));
      await _pump(tester, n: 16);
      expect(find.text('Liked songs'), findsOneWidget);
      expect(find.text('37 songs'), findsOneWidget);
      expect(find.text('Your playlists'), findsOneWidget);
      expect(find.text('New playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _shot(tester, 'home_library_${size.width.toInt()}');
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, n: 3);
    }
  });
}
