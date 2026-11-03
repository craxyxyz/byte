// Byte © 2026 Apurba Laskar
// Golden screenshot for 1.4.5: the Queue with autoplay on shows the next
// similar songs ahead of time (never "Nothing next"), phone width 390 px.
// Run on its own: SHOTS_DIR=... flutter test test_shots/v145_queue_shots_test.dart
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

Item _s(String id, String title, String artist, {int sec = 230, bool cover = false}) => Item(
  kind: ItemKind.song,
  id: id,
  title: title,
  artists: [ArtistRef(artist)],
  durationSec: sec,
  thumb: 'https://lh3.googleusercontent.com/${cover ? 'shot-cover' : 'shot-other'}-$id=w226-h226',
);

void main() {
  late Services sv;
  final song = _s('shotQueue01', 'Banjaare Raaste', 'Aarav Sen', cover: true);
  final similar = [
    _s('shotQ000002', 'Tere Bina Shaam', 'Meera Das'),
    _s('shotQ000003', 'Dil Ki Gali', 'Kabir Rao'),
    _s('shotQ000004', 'Chand Sitare', 'Aarav Sen', cover: true),
    _s('shotQ000005', 'Baarish Ki Boondein', 'Isha Malhotra'),
    _s('shotQ000006', 'Safar Lamba Hai', 'Rohan Verma'),
    _s('shotQ000007', 'Khwabon Ka Sheher', 'Meera Das'),
    _s('shotQ000008', 'Raat Bhar Jaagna', 'Kabir Rao'),
    _s('shotQ000009', 'Pehli Nazar Mein Hi Tumse Pyaar Ho Gaya (Extended)', 'Tanvi Shah & Arjun Mehta'),
    _s('shotQ000010', 'Yaadon Ki Kashti', 'Isha Malhotra'),
    _s('shotQ000011', 'Awara Dil', 'Aarav Sen', cover: true),
    _s('shotQ000012', 'Mitti Ki Khushboo', 'Rohan Verma'),
    _s('shotQ000013', 'Saans', 'Neha Kapoor'),
  ];

  setUpAll(() async {
    await _loadFonts();
    sv = await makeServices(net: FakeNet((r, body) => catalogue(r, body)));
    sv.settings.autoplay = true;
    sv.settings.font = 'Roboto';
    sv.settings.lyricsAutoFullScreen = false;
    sv.player.personalRadio = (seed, exclude) async => [for (final x in similar) if (!exclude.contains(x.id)) x];
    CoverCache.dir = Directory.systemTemp.createTempSync('byte_shots_');
    CoverCache.fetch = (u) async => u.contains('shot-cover') ? _art : _busy;
  });

  testWidgets('queue with similar songs ahead (390)', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    const size = Size(390, 844);
    tester.view.physicalSize = size;
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    sv.settings.themeMode = ThemeMode.dark;
    // a single song with no queue (what a party load or a resumed party gives)
    await tester.runAsync(() => sv.player.playItems([song]));
    await tester.runAsync(() => sv.player.pause());
    await tester.pumpWidget(RepaintBoundary(key: _key, child: const ByteApp()));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('mini')));
    await _pump(tester, n: 16);
    await tester.tap(find.byTooltip('Queue').first);
    await _pump(tester, n: 16);
    expect(sv.player.upcomingCount, greaterThanOrEqualTo(10));
    expect(find.text('Nothing next'), findsNothing);
    expect(find.text('Similar songs next'), findsWidgets);
    expect(find.text('Tere Bina Shaam'), findsOneWidget);
    await _shot(tester, 'queue_similar_390');
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, n: 3);
  });
}
