// Byte © 2026 Apurba Laskar
// Golden screenshots for 1.4.4: the Like heart beside ⋯ on Now Playing,
// light and dark, phone (390 px) and wide (1280x800).
// Run on its own: SHOTS_DIR=... flutter test test_shots/v144_like_shots_test.dart
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

void main() {
  late Services sv;
  const song = Item(
    kind: ItemKind.song,
    id: 'shotSong001',
    title: 'Neon Raat',
    artists: [ArtistRef('Aarav Sen'), ArtistRef('Meera Das')],
    durationSec: 214,
    thumb: 'https://lh3.googleusercontent.com/shot-cover=w226-h226',
  );

  setUpAll(() async {
    await _loadFonts();
    sv = await makeServices(net: FakeNet((r, body) => catalogue(r, body)));
    sv.settings.autoplay = false;
    sv.settings.font = 'Roboto';
    sv.settings.lyricsAutoFullScreen = false;
    CoverCache.dir = Directory.systemTemp.createTempSync('byte_shots_');
    CoverCache.fetch = (u) async => u.contains('shot-cover') ? _art : _busy;
  });

  testWidgets('like shots', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    for (final size in const [Size(390, 844), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      tester.view.padding = size.width < 600 ? const FakeViewPadding(top: 44, bottom: 24) : FakeViewPadding.zero;
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        sv.settings.themeMode = mode;
        await tester.runAsync(() => sv.library.setLiked(song, false));
        await tester.runAsync(() => sv.player.playItems([song], from: 'Search'));
        await tester.runAsync(() => sv.player.pause());
        await tester.pumpWidget(RepaintBoundary(key: _key, child: const ByteApp()));
        await _pump(tester);
        await tester.tap(find.byKey(const ValueKey('mini')));
        await _pump(tester, n: 16);
        final w = size.width.toInt();
        // wide: show Up next beside the player (the test renderer has no Indian-script fonts for lyrics)
        if (size.width >= 900 && find.text('Up next').evaluate().isNotEmpty) {
          await tester.tap(find.text('Up next').first);
          await _pump(tester, n: 8);
        }
        await _shot(tester, 'now_playing_${w}_${mode.name}_not_liked');
        await tester.tap(find.byKey(const ValueKey('np-like')));
        await _pump(tester, n: 10);
        expect(sv.library.isLiked(song.id), isTrue);
        await _shot(tester, 'now_playing_${w}_${mode.name}_liked');
        await tester.runAsync(() => sv.player.stop());
        await tester.pumpWidget(const SizedBox());
        await _pump(tester, n: 3);
      }
    }
  });
}
