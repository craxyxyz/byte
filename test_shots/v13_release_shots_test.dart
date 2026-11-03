
// Byte 1.3 screenshots with real songs and covers (audio simulated).
//   flutter test test_shots/v13_release_shots_test.dart --dart-define=CMP=/tmp/rel13
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/link_import.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:byte/ui/widgets.dart' show networkImage;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';
import 'compare_test.dart' show RealNetFakePlayer, loadFonts, settle, fetchImages, testImage, realTest, key;

const outDir = String.fromEnvironment('CMP', defaultValue: '/tmp/rel13');

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

class _H extends HttpOverrides {}

void main() {
  late Services sv;
  final songs = <Item>[];
  setUpAll(() async {
    final base = await makeServices();
    final net = RealNetFakePlayer();
    final yt = InnerTube(net);
    for (final q in ['Kesariya Arijit Singh', 'Tum Hi Ho Arijit Singh', 'Apna Bana Le Arijit Singh', 'Thuli Thuli Paiya', 'Tumi Robe Nirobe', 'Raataan Lambiyan']) {
      try {
        final r = await HttpOverrides.runWithHttpOverrides(() => yt.search(q, SearchFilter.songs), _H());
        if (r.isNotEmpty) songs.add(r.first);
      } catch (_) {}
    }
    // ignore: avoid_print
    print('songs ${songs.map((s) => s.title).join(', ')}');
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
    fakeAudio.durationFor = (_) => const Duration(seconds: 260);
    networkImage = testImage;
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
    final now = DateTime.now();
    for (final (i, s) in songs.indexed) {
      for (var k = 0; k < 6 - i; k++) {
        await sv.library.addHistory(s);
      }
      sv.stats.add(s, (8 - i) * 230000, session: 's$i', at: now);
      if (i < 3) await sv.library.setLiked(s, true);
    }
  });

  realTest('v1.3 shots', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(400 * 2, 900 * 2);
    addTearDown(t.view.reset);
    await t.pumpWidget(RepaintBoundary(key: key, child: const ByteApp()));
    await settle(t, ms: 3000);
    await t.runAsync(() => sv.player.playItems(songs));
    await t.runAsync(() => sv.player.pause());
    await settle(t, ms: 1500);
    final shell = t.state<ShellState>(find.byType(Shell));
    // DJ tab with For you
    shell.select(4);
    await settle(t, ms: 15000);
    await shot(t, 'dj-tab');
    final fy = find.text('For you');
    if (fy.evaluate().isNotEmpty) {
      await t.dragUntilVisible(fy, find.byType(Scrollable).first, const Offset(0, -250));
      await t.drag(find.byType(Scrollable).first, const Offset(0, -260));
      await settle(t, ms: 1500);
      await shot(t, 'dj-for-you');
    }
    // Library (stats + Artists)
    shell.select(2);
    await settle(t, ms: 3000);
    await shot(t, 'library');
    await t.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await settle(t, ms: 1500);
    await shot(t, 'library-artists');
    // Search: Addons tab
    shell.select(3);
    await settle(t, ms: 1500);
    final ad = find.text('Addons');
    if (ad.evaluate().isNotEmpty) {
      await t.tap(ad.last, warnIfMissed: false);
      await settle(t, ms: 1200);
      await shot(t, 'search-addons');
    }
    // Settings
    shell.select(0);
    await settle(t, ms: 1500);
    pushInCurrentTab!(const SettingsScreen());
    await settle(t, ms: 2000);
    await shot(t, 'settings');
    await t.runAsync(() => sv.player.stop());
    await t.pumpWidget(const SizedBox());
    await settle(t, ms: 500);
    await t.pump(const Duration(minutes: 2));
  });
}
