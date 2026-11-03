// Renders real screenshots of Byte with real YouTube Music data, real lyrics
// and real fonts (only the audio engine is simulated). Run on demand:
//   flutter test test_shots/shots_test.dart   (needs internet)
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/data/link_import.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/services.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/ui/account_ui.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/screens/library_pages.dart';
import 'package:byte/ui/screens/listen_together_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:byte/ui/widgets.dart' show networkImage;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';

final key = GlobalKey();

class _RealHttp extends HttpOverrides {}

/// flutter_test fakes every HTTP call (answers 400); screenshots want the real thing.
void realTest(String name, Future<void> Function(WidgetTester t) body) =>
    testWidgets(name, (t) => HttpOverrides.runWithHttpOverrides(() => body(t), _RealHttp()), timeout: const Timeout(Duration(minutes: 4)));

class RealNetFakePlayer extends Net {
  final real = HttpOverrides.runWithHttpOverrides(() => HttpNet(), _RealHttp());
  @override
  Future<NetResponse> send(NetRequest r, {Duration timeout = const Duration(seconds: 20)}) async {
    if (r.url.path.endsWith('/player')) return jsonRes(fakePlayer('x', durationMs: 262000));
    final res = await HttpOverrides.runWithHttpOverrides(() => real.send(r, timeout: timeout), _RealHttp());
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

const outDir = String.fromEnvironment('CMP', defaultValue: '/tmp/byte_cmp');

Future<void> snap(WidgetTester t, String name) async {
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
  late BrowsePage album;
  setUpAll(() async {
    sv = await makeServices(net: FakeNet(catalogue));
    album = await HttpOverrides.runWithHttpOverrides(() => InnerTube(HttpNet()).album('MPREb_E4GfUXfDfhy'), _RealHttp());
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
      importer: LinkImporter(yt, net),
      player: sv.player,
      stats: sv.stats,
      party: sv.party,
    );
    Services.i = sv;
    fakeAudio.durationFor = (_) => const Duration(seconds: 262);
    networkImage = testImage;
    sv.settings.themeMode = ThemeMode.light;
    sv.settings.autoplay = false;
    await sv.library.createPlaylist('Late night drive', items: album.tracks.skip(2).toList());
    await sv.library.createPlaylist('Gym', items: album.tracks.take(5).toList());
    final now = DateTime.now();
    for (final (i, s) in album.tracks.indexed) {
      await sv.library.setLiked(s, true);
      await sv.library.addHistory(s);
      sv.stats.add(s, (12 - i).clamp(1, 12) * 210000, session: 's$i', at: now);
    }
    for (final s in album.tracks.take(3)) {
      sv.library.addRecentItem(s);
    }
    for (final q in ['arijit singh', 'lofi hindi', 'anirudh']) {
      await sv.library.addSearch(q);
    }
    await sv.player.playItems(album.tracks);
    await sv.player.pause();
    // Explore's cover art, fetched up front (the test clock can't wait on it).
    final moods = await HttpOverrides.runWithHttpOverrides(() => yt.moods(), _RealHttp());
    var got = 0;
    await Future.wait([
      for (final p in [...moods.take(16).map((m) => m.params), '_new', '_charts', '_podcasts'])
        HttpOverrides.runWithHttpOverrides(() async {
          try {
            final s = switch (p) {
              '_new' => await yt.newReleases(),
              '_charts' => await yt.charts(),
              '_podcasts' => await yt.podcasts(),
              _ => await yt.moodPage(p),
            };
            final u = s.expand((x) => x.items).map((i) => i.thumb).whereType<String>().firstOrNull;
            if (u != null) got++;
            await sv.library.put('moodimg:$p', {'u': u, 't': DateTime.now().millisecondsSinceEpoch});
          } catch (_) {}
        }, _RealHttp()),
    ]);
    // ignore: avoid_print
    print('mood art $got');
  });

  Widget app() => RepaintBoundary(key: key, child: const ByteApp());

  realTest('compare', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(432 * 2, 972 * 2);
    addTearDown(t.view.reset);
    await t.pumpWidget(app());
    await settle(t, ms: 7000);
    final shell = t.state<ShellState>(find.byType(Shell));
    await snap(t, 'home');

    shell.select(1);
    await settle(t, ms: 9000);
    await fetchImages(t);
    await settle(t, ms: 4000);
    await snap(t, 'explore');

    shell.select(2);
    await settle(t, ms: 3000);
    await snap(t, 'library');

    shell.select(3);
    await settle(t, ms: 2000);
    await snap(t, 'search');

    Future<void> page(String name, Widget w, {int ms = 2500, Future<void> Function()? then}) async {
      pushInCurrentTab!(w);
      await settle(t, ms: ms);
      if (then != null) await then();
      await snap(t, name);
      final nav = t.state<NavigatorState>(find.byType(Navigator).at(1));
      while (nav.canPop()) {
        nav.pop();
        await settle(t, ms: 500);
      }
    }

    shell.select(2);
    await settle(t, ms: 800);
    await page('history', const HistoryScreen());
    await page('downloads', const DownloadsScreen());
    await t.tap(find.byType(ProfileButton).hitTestable().first);
    await settle(t, ms: 1500);
    await snap(t, 'account-switcher');
    await t.tapAt(const Offset(216, 900));
    await settle(t, ms: 800);
    await page('replay', const ReplayScreen());
    await page('liked', const LikedScreen());
    await page('settings', const SettingsScreen());
    await page('account', const AccountScreen());
    await page('listen-lobby', const ListenTogetherScreen());
    await page(
      'listen-create',
      const ListenTogetherScreen(),
      then: () async {
        await t.tap(find.text('Create a party'));
        await settle(t, ms: 1500);
      },
    );
    // A running party (as host).
    final party = sv.party;
    party
      ..role = RoomRole.host
      ..code = 'ZWB9YJ'
      ..connected = true
      ..roundTripMs = 434
      ..capacity = 5
      ..people = [Listener2(sv.settings.deviceId, 'Apurba', true)];
    party.activity
      ..clear()
      ..add(Activity(DateTime(2026, 11, 1, 23, 51, 47), 'Apurba', 'Changed the song to "${album.tracks.first.title}"'));
    await page('listen-room', const ListenTogetherScreen());
    await page(
      'listen-room-2',
      const ListenTogetherScreen(),
      then: () async {
        await t.drag(find.byType(Scrollable).last, const Offset(0, -520));
        await settle(t, ms: 1200);
      },
    );
    party
      ..role = RoomRole.none
      ..code = null
      ..people = const [];
    await page('sources', const SourcesScreen());
    await page('quality', const QualityScreen(mobile: true));
    await page('playback', const PlaybackScreen());
    await page('appearance', const AppearanceScreen());
    await page('advanced', const AdvancedScreen());
    await page('misc', const MiscScreen());

    sv.settings.themeMode = ThemeMode.dark;
    await settle(t, ms: 1500);
    shell.select(0);
    await settle(t, ms: 2500);
    await snap(t, 'home-dark');
    await page('settings-dark', const SettingsScreen());

    await t.runAsync(() => sv.player.stop());
    await t.pumpWidget(const SizedBox());
    await settle(t, ms: 500);
    await t.pump(const Duration(minutes: 2));
  });
}
