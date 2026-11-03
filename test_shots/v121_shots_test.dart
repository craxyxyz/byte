// Byte 1.2.1 screenshots (new look: home light/dark, player, DJ, icon picker)
// with real YouTube Music data and real fonts; audio and voice are simulated.
//   flutter test test_shots/v121_shots_test.dart   (needs internet + relay)
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/widgets.dart' show networkImage;
import 'dart:math';

import 'package:byte/dj/dj_controller.dart';
import 'package:byte/dj/dj_session.dart';
import 'package:byte/ui/app_icon_picker.dart';
import 'package:byte/ui/screens/dj_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';
import '../tool/relay_net.dart';

final key = GlobalKey();

class _RealHttp extends HttpOverrides {}

/// flutter_test fakes every HTTP call (answers 400); screenshots want the real thing.
void realTest(String name, Future<void> Function(WidgetTester t) body) =>
    testWidgets(name, (t) => HttpOverrides.runWithHttpOverrides(() => body(t), _RealHttp()), timeout: const Timeout(Duration(minutes: 10)));

class RealNetFakePlayer extends Net {
  final real = HttpOverrides.runWithHttpOverrides(() => HttpNet(), _RealHttp());
  final relay = RelayNet();
  @override
  Future<NetResponse> send(NetRequest r, {Duration timeout = const Duration(seconds: 20)}) async {
    if (r.url.path.endsWith('/player')) return jsonRes(fakePlayer('x', durationMs: 262000));
    // YouTube Music through the home-connection relay (this box's address is rate-limited).
    final viaRelay = r.url.host.endsWith('youtube.com');
    final res = await HttpOverrides.runWithHttpOverrides(() => (viaRelay ? relay : real).send(r, timeout: timeout), _RealHttp());
    if (res.status >= 400) {
      // ignore: avoid_print
      print('HTTP ${res.status} ${r.url} ${r.headers} ${r.body == null ? '' : String.fromCharCodes(r.body!)} -> ${String.fromCharCodes(res.body.take(400))}');
    }
    return res;
  }
}

Future<void> loadFonts() async {
  const dir = '/home/user/sdk/flutter/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Black', 'Light']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('$dir/Roboto-$w.ttf').readAsBytesSync())));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(File('$dir/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

Future<void> settle(WidgetTester t, {int ms = 2500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await t.pump(const Duration(milliseconds: 120));
  }
}

// Images are downloaded outside the test's fake clock, then served from memory.
final Map<String, Uint8List> imgCache = {};
final Set<String> wanted = {};
final Uint8List blank = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

ImageProvider testImage(String url) {
  final b = imgCache[url];
  if (b != null) return MemoryImage(b);
  wanted.add(url);
  return MemoryImage(blank);
}

Future<void> fetchImages(WidgetTester t) async {
  for (var round = 0; round < 3 && wanted.isNotEmpty; round++) {
    final todo = wanted.toList();
    wanted.clear();
    await t.runAsync(() async {
      final c = HttpClient();
      await Future.wait(
        todo.map((u) async {
          try {
            final rq = await c.getUrl(Uri.parse(u)).timeout(const Duration(seconds: 10));
            final rs = await rq.close().timeout(const Duration(seconds: 10));
            final bytes = await rs.fold<List<int>>([], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 15));
            if (rs.statusCode == 200) imgCache[u] = Uint8List.fromList(bytes);
          } catch (_) {}
        }),
      );
      c.close(force: true);
    });
    t.binding.reassembleApplication();
    await settle(t, ms: 1500);
  }
}

const outDir = String.fromEnvironment('SHOTS', defaultValue: '/tmp/byte_v121_shots');

Future<void> snap(WidgetTester t, String name, double dpr) async {
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
    final img = await b.toImage(pixelRatio: dpr);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory(outDir).createSync(recursive: true);
    File('$outDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('snap $name');
}

void main() {
  late Services sv;
  final queue = <Item>[];
  setUpAll(() async {
    sv = await makeServices(net: FakeNet(catalogue));
    final net = RealNetFakePlayer();
    final yt = InnerTube(net);
    sv = Services(
      net: net,
      yt: yt,
      resolver: sv.resolver,
      library: sv.library,
      settings: sv.settings,
      lyrics: LyricsService(net, yt),
      downloads: sv.downloads,
      local: sv.local,
      account: sv.account,
      importer: sv.importer,
      player: sv.player,
      stats: sv.stats,
      party: sv.party,
    );
    Services.i = sv;
    fakeAudio.durationFor = (_) => const Duration(seconds: 262);
    networkImage = testImage;
    sv.settings.themeMode = ThemeMode.light;
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
    // a real taste: his kind of songs, liked and played
    final now = DateTime.now();
    var n = 0;
    for (final q in ['Arijit Singh', 'Anupam Roy', 'Pritam', 'Shreya Ghoshal bengali']) {
      final r = await HttpOverrides.runWithHttpOverrides(() => yt.search(q, SearchFilter.songs), _RealHttp());
      if (q == 'Arijit Singh') queue.addAll(r.take(8));
      for (final s in r.take(4)) {
        await sv.library.setLiked(s, true);
        await sv.library.addHistory(s);
        sv.stats.add(s, (5 - n % 4) * 200000, session: 's${n++}', at: now);
      }
    }
  });

  Widget app() => RepaintBoundary(key: key, child: const ByteApp());

  realTest('v1.2.1', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 3;
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    addTearDown(t.view.reset);
    final dj = DjController(
      player: sv.player,
      brain: DjBrain(library: sv.library, stats: sv.stats, yt: sv.yt, rng: Random(11)),
      settings: sv.settings,
    );
    sv.dj = dj;
    await t.runAsync(() => sv.player.playItems(queue));
    await t.pumpWidget(app());
    await settle(t, ms: 6000);
    await t.runAsync(() => sv.player.seek(const Duration(seconds: 71)));
    await settle(t, ms: 2000);
    await snap(t, 'home-light', 3);

    await t.tap(find.byKey(const ValueKey('mini')));
    await settle(t, ms: 4000);
    await snap(t, 'player', 3);
    await t.tap(find.byTooltip('Close').first);
    await settle(t, ms: 1500);

    pushInCurrentTab!(const AppIconScreen());
    await settle(t, ms: 2500);
    await snap(t, 'icons', 3);
    t.state<NavigatorState>(find.byType(Navigator).at(1)).pop();
    await settle(t, ms: 1200);

    pushInCurrentTab!(const AboutScreen());
    await settle(t, ms: 1500);
    await snap(t, 'about', 3);
    t.state<NavigatorState>(find.byType(Navigator).at(1)).pop();
    await settle(t, ms: 1200);

    pushInCurrentTab!(const AutomixScreen());
    await settle(t, ms: 1500);
    await snap(t, 'automix', 3);
    t.state<NavigatorState>(find.byType(Navigator).at(1)).pop();
    await settle(t, ms: 1200);

    await t.runAsync(() async {
      await dj.start();
      for (var i = 0; i < 100 && dj.lastLine == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    pushInCurrentTab!(const DjScreen());
    await settle(t, ms: 4000);
    await snap(t, 'dj', 3);
    t.state<NavigatorState>(find.byType(Navigator).at(1)).pop();
    await settle(t, ms: 1500);

    sv.settings.themeMode = ThemeMode.dark;
    await settle(t, ms: 2500);
    await snap(t, 'home-dark', 3);
    pushInCurrentTab!(const DjScreen());
    await settle(t, ms: 2500);
    await snap(t, 'dj-dark', 3);
    t.state<NavigatorState>(find.byType(Navigator).at(1)).pop();
    await settle(t, ms: 1200);
    pushInCurrentTab!(const AppIconScreen());
    await settle(t, ms: 2000);
    await snap(t, 'icons-dark', 3);
    t.state<NavigatorState>(find.byType(Navigator).at(1)).pop();
    await settle(t, ms: 1200);

    dj.stop(silent: true);
    sv.player.pause();
    await settle(t, ms: 1000);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
  });
}
