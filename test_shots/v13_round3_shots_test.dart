// Byte 1.3 round-3 screenshots: glass on/off, Home DJ pill, player, Phone setup, sync.
//   flutter test test_shots/v13_round3_shots_test.dart --dart-define=CMP=/tmp/r3
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/link_import.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/now_playing.dart' show SeekBar;
import 'package:byte/ui/player_parts.dart' show showPlayerMore;
import 'package:byte/ui/screens/phone_setup_screen.dart';
import 'package:byte/ui/screens/sync_screen.dart';
import 'package:byte/ui/widgets.dart' show networkImage;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';
import 'compare_test.dart' show RealNetFakePlayer, loadFonts, settle, fetchImages, testImage, realTest, key;

const outDir = String.fromEnvironment('CMP', defaultValue: '/tmp/r3');

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
    for (final q in ['Thuli Thuli Paiya', 'Kesariya Arijit Singh', 'Tum Hi Ho Arijit Singh', 'Apna Bana Le Arijit Singh', 'Tumi Robe Nirobe', 'Raataan Lambiyan']) {
      try {
        final r = await HttpOverrides.runWithHttpOverrides(() => yt.search(q, SearchFilter.songs), _H());
        if (r.isNotEmpty) songs.add(r.first);
      } catch (_) {}
    }
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
    fakeAudio.durationFor = (_) => const Duration(seconds: 267);
    networkImage = testImage;
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
    for (final (i, s) in songs.indexed) {
      await sv.library.addHistory(s);
      if (i < 3) await sv.library.setLiked(s, true);
    }
  });

  realTest('v1.3 round 3 shots', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(400 * 2, 900 * 2);
    addTearDown(t.view.reset);
    await t.pumpWidget(RepaintBoundary(key: key, child: const ByteApp()));
    await settle(t, ms: 6000);
    await shot(t, 'home');
    await t.runAsync(() => sv.player.playItems(songs));
    await t.runAsync(() => sv.player.seek(const Duration(seconds: 57)));
    await t.runAsync(() => sv.player.pause());
    await settle(t, ms: 2500);
    await shot(t, 'home-playing');
    // player
    await t.tap(find.byKey(const ValueKey('mini')));
    await settle(t, ms: 2500);
    await shot(t, 'player');
    // ⋯ sheet on glass, then the same with Liquid glass off
    final ctx = t.element(find.byType(SeekBar).first);
    showPlayerMore(ctx, songs.first);
    await settle(t, ms: 1500);
    await shot(t, 'glass-on-sheet');
    sv.settings.liquidGlass = false;
    sv.settings.changed();
    await settle(t, ms: 1500);
    await shot(t, 'glass-off-sheet');
    sv.settings.liquidGlass = true;
    sv.settings.changed();
    Navigator.of(t.element(find.byKey(const ValueKey('glass-sheet')))).pop();
    await settle(t, ms: 800);
    // back to Home
    Navigator.of(t.element(find.byType(Scaffold).last)).pop();
    await settle(t, ms: 1200);
    // Phone setup (a Xiaomi)
    pushInCurrentTab!(
      PhoneSetupScreen(
        info: const PhoneInfo(manufacturer: 'Xiaomi', brand: 'Redmi', model: 'Redmi Note 13 Pro', sdk: 34, release: '14', lowRam: false, totalMemMb: 8000, miui: true, ignoringBattery: false),
        invoke: (m, [a]) async => m == 'open' ? 'maker' : null,
      ),
    );
    await settle(t, ms: 1500);
    await shot(t, 'phone-setup');
    Navigator.of(t.element(find.byType(PhoneSetupScreen))).pop();
    await settle(t, ms: 800);
    pushInCurrentTab!(const SyncScreen());
    await settle(t, ms: 1500);
    await t.enterText(find.byKey(const ValueKey('sync-email')), 'apurba@gmail.com');
    await settle(t, ms: 600);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, ms: 800);
    await shot(t, 'sync');
    await t.runAsync(() => sv.player.stop());
    await t.pumpWidget(const SizedBox());
    await settle(t, ms: 500);
    await t.pump(const Duration(minutes: 2));
  });
}
