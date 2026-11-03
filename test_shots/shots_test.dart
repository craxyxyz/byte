
// Golden screenshots for 1.4.1 (Apurba's reference video): poster player,
// mini lyric line, lyrics view mid-line, mini player over a white and a busy
// page. Run on its own:  flutter test test_shots/shots_test.dart
// It writes PNGs to $SHOTS_DIR (default build/shots) — not part of the suite.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/cover_cache.dart';
import 'package:byte/core/models.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';

const _fonts = '/home/user/sdk/flutter/bin/cache/artifacts/material_fonts';
final _out = Platform.environment['SHOTS_DIR'] ?? 'build/shots';
final _art = File(Platform.environment['SHOTS_ART'] ?? 'test_shots/cover.png').readAsBytesSync();
final _busy = File(Platform.environment['SHOTS_BUSY'] ?? 'test_shots/busy.png').readAsBytesSync();

// Original demo words (written for this test), timed like a real song.
const _lrc = '[00:02.00] Raat ki roshni mein\n'
    '[00:06.00] Tera naam likha hai\n'
    '[00:10.00] Har dhadkan kehti hai\n'
    '[00:14.00] Bas tu hi basa hai\n'
    '[00:18.00] Shehar so gaya, hum jaage\n'
    '[00:22.00] Chaand bhi ruk ke sune\n'
    '[00:26.00] ♪\n'
    '[00:36.00] Kal ki fikar chhod de\n'
    '[00:40.00] Aaj ka pal jee le\n';

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
    sv = await makeServices(
      net: FakeNet((r, body) {
        final u = r.url.toString();
        if (u.contains('lrclib.net')) {
          return jsonRes({
            'id': 1, 'trackName': song.title, 'artistName': song.artistLine, 'duration': 214,
            'syncedLyrics': _lrc, 'plainLyrics': _lrc.replaceAll(RegExp(r'\[[^\]]*\] ?'), ''),
          });
        }
        return catalogue(r, body);
      }),
    );
    sv.settings.autoplay = false;
    sv.settings.font = 'Roboto';
    CoverCache.dir = Directory.systemTemp.createTempSync('byte_shots_');
    CoverCache.fetch = (u) async => u.contains('shot-cover') ? _art : _busy;
  });

  Future<void> boot(WidgetTester tester, {ThemeMode theme = ThemeMode.dark}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    sv.settings.themeMode = theme;
    await tester.runAsync(() => sv.player.playItems([song], from: 'Search'));
    await tester.pumpWidget(RepaintBoundary(key: _key, child: const ByteApp()));
    await _pump(tester);
  }

  Future<void> at(WidgetTester tester, int ms) async {
    await tester.runAsync(() async {
      await sv.player.pause();
      await sv.player.seek(Duration(milliseconds: ms));
    });
    sv.player.clock.set(ms, playing: false);
  }

  testWidgets('shots', (tester) async {
    addTearDown(tester.view.reset);
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      final ctx = d.informationCollector?.call().map((e) => e.toString()).join('\n') ?? '';
      if (Platform.environment['SHOTS_DEBUG'] != null) debugPrint('FLUTTER-ERROR ${d.exceptionAsString()}\n${ctx.substring(0, ctx.length.clamp(0, 6000))}');
      prev?.call(d);
    };
    await boot(tester, theme: ThemeMode.light);
    // mini player over a white page (Library) and a busy page (Home's covers)
    await tester.tap(find.text('Library').first);
    await _pump(tester);
    await _shot(tester, 'mini_white_light');
    await tester.tap(find.text('Home').first);
    await _pump(tester);
    await _shot(tester, 'mini_busy_light');
    sv.settings.themeMode = ThemeMode.dark;
    await _pump(tester);
    await _shot(tester, 'mini_busy_dark');
    await tester.tap(find.text('Library').first);
    await _pump(tester);
    await _shot(tester, 'mini_page_dark');

    // the player: poster + mini lyric line (mid-line "Tera naam likha hai")
    await tester.tap(find.byKey(const ValueKey('mini')));
    await _pump(tester);
    await at(tester, 7600);
    await _pump(tester, n: 8);
    await tester.pump(const Duration(milliseconds: 50));
    await _shot(tester, 'player');

    // full lyrics, mid-line
    sv.settings.lyricsAutoFullScreen = false;
    await tester.tap(find.byTooltip('Lyrics'));
    await _pump(tester);
    await at(tester, 15400);
    await _pump(tester, n: 10);
    await tester.pump(const Duration(milliseconds: 50));
    await _shot(tester, 'lyrics');
    // an instrumental gap: the "…" dots
    await at(tester, 30000);
    await _pump(tester, n: 8);
    await _shot(tester, 'lyrics_gap');

    // contrast report (white text on the mini tint over white / black)
    final tint = ReadableGlass.miniTint(const Color(0xFFD64A60));
    final r = StringBuffer()
      ..writeln('mini title on white page: ${ReadableGlass.contrast(Colors.white, ReadableGlass.over(tint, Colors.white)).toStringAsFixed(2)}')
      ..writeln('mini artist on white page: ${ReadableGlass.contrast(ReadableGlass.over(ReadableGlass.miniSecondary, ReadableGlass.over(tint, Colors.white)), ReadableGlass.over(tint, Colors.white)).toStringAsFixed(2)}');
    File('$_out/contrast.txt').writeAsStringSync(r.toString());
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
