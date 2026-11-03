
// Lyrics side-by-side with Apurba's reference recording: the same Tamil song,
// real KuGou lyrics, real translation, real cover (audio simulated).
//   flutter test test_shots/v13_lyrics_compare_test.dart --dart-define=CMP=/tmp/lycmp
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/link_import.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/widgets.dart' show networkImage;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';
import 'compare_test.dart' show RealNetFakePlayer, loadFonts, settle, fetchImages, testImage, realTest, key;

const outDir = String.fromEnvironment('CMP', defaultValue: '/tmp/lycmp');
const query = String.fromEnvironment('Q', defaultValue: 'Thuli Thuli Paiya Yuvan Shankar Raja');
const atMs = int.fromEnvironment('AT', defaultValue: 57600);

Future<void> shot(WidgetTester t, String name) async {
  await fetchImages(t);
  for (final e in find.byType(Image).evaluate()) {
    final w = e.widget as Image;
    await t.runAsync(() async {
      try {
        await precacheImage(w.image, e).timeout(const Duration(seconds: 5));
      } catch (_) {}
    });
  }
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
  late Services sv;
  late Item song;
  setUpAll(() async {
    final base = await makeServices();
    final net = RealNetFakePlayer();
    final yt = InnerTube(net);
    final hits = await HttpOverrides.runWithHttpOverrides(() => yt.search(query, SearchFilter.songs), _H());
    song = hits.first;
    // ignore: avoid_print
    print('song ${song.title} / ${song.artistLine} ${song.durationSec}');
    sv = Services(
      net: net,
      yt: yt,
      resolver: base.resolver,
      library: base.library,
      settings: base.settings,
      lyrics: LyricsService(net, yt),
      downloads: base.downloads,
      local: base.local,
      account: base.account,
      importer: LinkImporter(yt, net),
      player: base.player,
      stats: base.stats,
      party: base.party,
    );
    Services.i = sv;
    await sv.wireSources();
    fakeAudio.durationFor = (_) => Duration(seconds: song.durationSec ?? 283);
    networkImage = testImage;
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
    sv.settings.lyricsOrder = ['kugou', 'lrclib', 'ytm', 'ytcaptions', 'files', 'addons', 'musixmatch'];
  });

  realTest('lyrics compare', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(400 * 2, 900 * 2);
    addTearDown(t.view.reset);
    await t.pumpWidget(RepaintBoundary(key: key, child: const ByteApp()));
    await settle(t, ms: 2500);
    await t.runAsync(() => sv.player.playItems([song]));
    await settle(t, ms: 1500);
    await t.runAsync(() => sv.player.seek(const Duration(milliseconds: atMs)));
    await t.runAsync(() => sv.player.pause());
    await settle(t, ms: 800);
    await t.tap(find.byKey(const ValueKey('mini')));
    await settle(t, ms: 9000);
    await shot(t, 'song');
    await t.tap(find.byTooltip('Lyrics').first, warnIfMissed: false);
    await settle(t, ms: 3000);
    await shot(t, 'lyrics');
    await t.tap(find.byTooltip('Translate').first, warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 150));
    await shot(t, 'translating');
    await settle(t, ms: 12000);
    await shot(t, 'translated');
    await t.tap(find.byTooltip('Romanize').first, warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 400));
    await shot(t, 'romanize-toast');
    await t.runAsync(() => sv.player.stop());
    await t.pumpWidget(const SizedBox());
    await settle(t, ms: 500);
    await t.pump(const Duration(minutes: 2));
  });
}

class _H extends HttpOverrides {}
