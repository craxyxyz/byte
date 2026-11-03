// Byte 1.3 "Talk to your DJ" screenshots with real songs and covers (audio simulated).
//   flutter test test_shots/v13_dj_chat_shots_test.dart --dart-define=CMP=/tmp/djchat
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/link_import.dart';
import 'package:byte/dj/dj_controller.dart';
import 'package:byte/dj/dj_session.dart';
import 'package:byte/dj/recommender.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/screens/dj_chat_screen.dart';
import 'package:byte/ui/theme.dart';
import 'package:byte/ui/widgets.dart' show networkImage;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';
import 'compare_test.dart' show RealNetFakePlayer, loadFonts, settle, fetchImages, testImage, realTest, key;

const outDir = String.fromEnvironment('CMP', defaultValue: '/tmp/djchat');

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
  final songs = <Item>[];
  setUpAll(() async {
    final base = await makeServices();
    final net = RealNetFakePlayer();
    final yt = InnerTube(net);
    for (final q in ['Kesariya Arijit Singh', 'Tum Hi Ho Arijit Singh', 'Chaleya Anirudh', 'Apna Bana Le Arijit Singh', 'Hukum Anirudh', 'Tumi Robe Nirobe']) {
      try {
        final r = await yt.search(q, SearchFilter.songs);
        if (r.isNotEmpty) songs.add(r.first);
      } catch (_) {}
    }
    // ignore: avoid_print
    print('songs ${songs.map((s) => '${s.title} / ${s.artistLine}').join(', ')}');
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
    sv.settings.djLanguage = 'hinglish';
    sv.settings.djName = 'Apurba';
    final now = DateTime.now();
    for (final (i, s) in songs.indexed) {
      await sv.library.addHistory(s);
      sv.stats.add(s, (8 - i) * 230000, session: 's$i', at: now);
      if (i < 3) await sv.library.setLiked(s, true);
    }
    sv.dj = DjController(
      player: sv.player,
      brain: DjBrain(library: sv.library, stats: sv.stats, yt: yt),
      settings: sv.settings,
      recommender: DjRecommender.forPhone(yt: yt, library: sv.library, stats: sv.stats, log: sv.playLog),
      library: sv.library,
    );
  });

  realTest('DJ chat shots', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(400 * 2, 900 * 2);
    addTearDown(t.view.reset);
    await t.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(debugShowCheckedModeBanner: false, theme: ByteTheme.build(Brightness.light), home: const DjChatScreen())));
    await settle(t, ms: 1500);
    await t.enterText(find.byKey(const Key('djChatInput')), 'sad hindi, Arijit jaisa');
    await settle(t, ms: 500);
    await shot(t, 'dj-chat-1-greeting');
    await t.tap(find.byKey(const Key('djChatSend')));
    for (var i = 0; i < 40 && !sv.dj.inRequest; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await settle(t, ms: 300);
    }
    await t.runAsync(() => sv.player.pause());
    await settle(t, ms: 2500);
    await shot(t, 'dj-chat-2-playing');
    await t.runAsync(() => sv.player.stop());
    sv.dj.stop();
    await t.pumpWidget(const SizedBox());
    await settle(t, ms: 500);
    await t.pump(const Duration(minutes: 2));
  });
}
