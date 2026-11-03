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
import 'package:byte/data/playlist_import.dart';
import 'package:byte/ui/import_sheet.dart';
import 'package:byte/ui/now_playing.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/services.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/screens/listen_together_screen.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:byte/ui/widgets.dart' show networkImage;
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
    testWidgets(name, (t) => HttpOverrides.runWithHttpOverrides(() => body(t), _RealHttp()), timeout: const Timeout(Duration(minutes: 8)));

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

const outDir = String.fromEnvironment('SHOTS', defaultValue: '/tmp/byte_v11_shots');

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
  late BrowsePage album;
  late ExtList imported;
  late List<TrackMatch> matches;
  setUpAll(() async {
    sv = await makeServices(net: FakeNet(catalogue));
    final net = RealNetFakePlayer();
    final yt = InnerTube(net);
    album = await HttpOverrides.runWithHttpOverrides(() => yt.album('MPREb_E4GfUXfDfhy'), _RealHttp());
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
    await sv.scrobbler.open();
    await sv.webdav.open();
    await sv.spotify.open();
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
    // A real import: a JioSaavn playlist, matched on YouTube Music.
    imported = await HttpOverrides.runWithHttpOverrides(
      () => PlaylistReader(net.real, yt).read('https://www.jiosaavn.com/featured/lets-play-arijit-singh-hindi/Iz0pi7nkjUE_'),
      _RealHttp(),
    );
    matches = await HttpOverrides.runWithHttpOverrides(() => PlaylistMatcher(yt).matchAll(imported.tracks.take(14).toList()), _RealHttp());
    matches.add(TrackMatch(const ExtTrack('Tera Zikr [SAN Lofi Remix] | Indian Bollywood Lofi', 'DeRAWAT'), searched: true));
    await sv.player.playItems(album.tracks);
    await sv.player.pause();
    final moods = await HttpOverrides.runWithHttpOverrides(() => yt.moods(), _RealHttp());
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
            await sv.library.put('moodimg:$p', {'u': u, 't': DateTime.now().millisecondsSinceEpoch});
          } catch (_) {}
        }, _RealHttp()),
    ]);
  });

  Widget app() => RepaintBoundary(key: key, child: const ByteApp());

  realTest('phone', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 3;
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    addTearDown(t.view.reset);
    await t.pumpWidget(app());
    await settle(t, ms: 8000);
    final shell = t.state<ShellState>(find.byType(Shell));
    await snap(t, 'home', 3);

    shell.select(1);
    await settle(t, ms: 9000);
    await fetchImages(t);
    await settle(t, ms: 3000);
    await snap(t, 'explore', 3);

    shell.select(2);
    await settle(t, ms: 3000);
    await snap(t, 'library', 3);

    Future<void> page(String name, Widget w, {int ms = 3000, Future<void> Function()? then}) async {
      pushInCurrentTab!(w);
      await settle(t, ms: ms);
      if (then != null) await then();
      await snap(t, name, 3);
      final nav = t.state<NavigatorState>(find.byType(Navigator).at(1));
      while (nav.canPop()) {
        nav.pop();
        await settle(t, ms: 500);
      }
    }

    await page('import', ImportReviewScreen(list: imported, matches: matches), ms: 4000);

    final party = sv.party;
    party
      ..role = RoomRole.host
      ..code = 'ZWB9YJ'
      ..connected = true
      ..roundTripMs = 86
      ..capacity = 5
      ..people = [Listener2(sv.settings.deviceId, 'Apurba', true), const Listener2('r', 'Rahul', false), const Listener2('p', 'Priya', false)];
    party.activity
      ..clear()
      ..add(Activity(DateTime(2026, 11, 2, 0, 51, 47), 'Apurba', 'Changed the song to "${album.tracks.first.title}"'))
      ..add(Activity(DateTime(2026, 11, 2, 0, 52, 3), 'Rahul', 'Joined'));
    await page('listen-together', const ListenTogetherScreen());
    party
      ..role = RoomRole.none
      ..code = null
      ..people = const [];

    await page('settings', const SettingsScreen());

    // Now playing → lyrics
    await t.runAsync(() async {
      await sv.player.play();
      await sv.player.seek(const Duration(seconds: 71));
    });
    await settle(t, ms: 1500);
    NowPlayingScreen.open(t.element(find.byType(Scaffold).first), tab: NpTab.lyrics);
    await settle(t, ms: 6000);
    await snap(t, 'lyrics', 3);
    await t.runAsync(() => sv.player.pause());
    await t.pumpWidget(const SizedBox());
    await settle(t, ms: 500);
    await t.pump(const Duration(minutes: 2));
  });

  realTest('tablet', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(1180 * 2, 820 * 2);
    addTearDown(t.view.reset);
    await t.pumpWidget(app());
    await settle(t, ms: 6000);
    await t.runAsync(() async {
      await sv.player.play();
      await sv.player.seek(const Duration(seconds: 101));
    });
    await settle(t, ms: 1500);
    NowPlayingScreen.open(t.element(find.byType(Scaffold).first), tab: NpTab.lyrics);
    await settle(t, ms: 6000);
    await snap(t, 'tablet', 2);
    await t.runAsync(() => sv.player.stop());
    await t.pumpWidget(const SizedBox());
    await settle(t, ms: 500);
    await t.pump(const Duration(minutes: 2));
  });
}
