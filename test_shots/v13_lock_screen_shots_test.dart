// Byte 1.3 lock-screen player screenshots (small card and big cover), with a real cover.
//   flutter test test_shots/v13_lock_screen_shots_test.dart --dart-define=CMP=/tmp/lock13
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/lock/lock_app.dart';
import 'package:byte/lock/lock_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'compare_test.dart' show RealNetFakePlayer, loadFonts, settle, realTest, key;

const outDir = String.fromEnvironment('CMP', defaultValue: '/tmp/lock13');

class _Player extends LockPlayer {
  final LockSnapshot s;
  _Player(this.s);
  @override
  LockSnapshot get state => s;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> next() async {}
  @override
  Future<void> previous() async {}
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> setVolume(double v) async {}
}

Future<void> _shot(WidgetTester t, String name) async {
  await settle(t, ms: 900);
  final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await t.runAsync(() async {
    final img = await b.toImage(pixelRatio: 2);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory(outDir).createSync(recursive: true);
    File('$outDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('snap $name');
}

void main() {
  realTest('lock screen shots', (t) async {
    await t.runAsync(loadFonts);
    Item? song;
    Uint8List? cover;
    await t.runAsync(() async {
      final yt = InnerTube(RealNetFakePlayer());
      final r = await yt.search('Kesariya Arijit Singh', SearchFilter.songs);
      song = r.first;
      final url = song!.thumbAt(544)!.replaceFirst(RegExp(r'=w\d+-h\d+'), '=w1080-h1080');
      final c = HttpClient();
      final rq = await c.getUrl(Uri.parse(url));
      final rs = await rq.close();
      cover = Uint8List.fromList(await rs.fold<List<int>>([], (a, b) => a..addAll(b)));
      c.close(force: true);
    });
    final img = MemoryImage(cover!);
    final now = DateTime(2026, 11, 2, 15, 7);
    final player = _Player(
      LockSnapshot(
        track: LockTrack(
          title: song!.title,
          artist: song!.artistLine,
          artUrl: 'https://cover',
          duration: Duration(seconds: song!.durationSec ?? 268),
        ),
        playing: false,
        position: const Duration(seconds: 6),
        positionAt: now,
        volume: 0.55,
      ),
    );
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(400 * 2, 900 * 2);
    addTearDown(t.view.reset);
    Widget app() => RepaintBoundary(
      key: key,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 900), padding: EdgeInsets.only(top: 32, bottom: 16), devicePixelRatio: 2),
        child: LockScreenApp(player: player, image: (_) => img, now: () => now),
      ),
    );
    await t.pumpWidget(app());
    await t.runAsync(() => precacheImage(img, key.currentContext!));
    await settle(t, ms: 800);
    await _shot(t, 'lock-small');
    await t.tap(find.byKey(const ValueKey('lock-art')));
    await settle(t, ms: 1200);
    await _shot(t, 'lock-expanded');
    await t.pumpWidget(const SizedBox());
    await settle(t, ms: 300);
  });
}
