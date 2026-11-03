// Byte © 2026 Apurba Laskar.
// Golden screenshots for 1.4.4 lyrics (Apurba: "by default Romanized"): a
// Tamil song opens in Roman letters only, and full-screen lyrics show only
// the lyrics (no type buttons, no caption). Run on its own:
//   SHOTS_DIR=... flutter test test_shots/v144_lyrics_shots_test.dart
// Not part of the suite.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/core/cover_cache.dart';
import 'package:byte/core/models.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';

const _fonts = '/home/user/sdk/flutter/bin/cache/artifacts/material_fonts';
const _noto = '/usr/share/fonts/truetype/noto';
final _out = Platform.environment['SHOTS_DIR'] ?? 'build/shots/lyrics144';
final _art = File(Platform.environment['SHOTS_ART'] ?? 'test_shots/cover.png').readAsBytesSync();
// made-up Tamil lines (the harness's stand-in for his Tamil song)
const _tamil = '[00:01.00]நான் உன்னை பார்த்தேன்\n[00:05.00]வானம் நீலமாக இருக்கிறது\n[00:09.00]என் இதயம் பாடுகிறது\n[00:13.00]நீ என் அருகில் வா\n[00:17.00]மழை பெய்கிறது இன்று\n[00:21.00]உன் கண்களில் ஒளி\n[00:25.00]காற்று மெதுவாக வீசுகிறது\n[00:29.00]நாம் ஒன்றாக பாடுவோம்\n[00:33.00]இரவு நிலவு அழகு\n[00:37.00]என் உயிரே நீ தான்\n';
String _fx(String f) => f == 'tamil' ? _tamil : File('test/fixtures/dual/$f').readAsStringSync();

Future<void> _loadFonts() async {
  Future<ByteData> f(String p) async => ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer);
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Black']) {
    roboto.addFont(f('$_fonts/Roboto-$w.ttf'));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(f('$_fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  // the original scripts (the harness has no system fonts; phones do)
  final fallback = <String>[];
  for (final fam in ['NotoNaskhArabic', 'NotoSansDevanagari', 'NotoSansBengali', 'NotoSansGurmukhi', 'NotoSansTamil']) {
    if (!File('$_noto/$fam-Regular.ttf').existsSync()) continue;
    final l = FontLoader(fam)
      ..addFont(f('$_noto/$fam-Regular.ttf'))
      ..addFont(f('$_noto/$fam-Bold.ttf'));
    await l.load();
    fallback.add(fam);
  }
  LyricsDual.fontFallback = fallback;
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

class _Song {
  final Item item;
  final String original;
  final String? roman;
  final int atMs;
  const _Song(this.item, this.original, this.roman, this.atMs);
}

Item _item(String id, String title, String artist, int d) => Item(kind: ItemKind.song, id: id, title: title, artists: [ArtistRef(artist)], durationSec: d, thumb: 'https://lh3.googleusercontent.com/shot-cover-$id=w226-h226');

final _songs = {
  'tamil': _Song(_item('lyrTamil001', 'Kannukulla', 'Test Artist', 200), 'tamil', null, 9600),
};

void main() {
  late Services sv;
  var now = _songs['tamil']!;

  Map<String, Object?> hit(int id, _Song s, String lrc) => {
        'id': id, 'trackName': s.item.title, 'artistName': s.item.artistLine, 'duration': s.item.durationSec,
        'syncedLyrics': lrc, 'plainLyrics': lrc.replaceAll(RegExp(r'\[[^\]]*\] ?'), ''),
      };

  setUpAll(() async {
    await _loadFonts();
    sv = await makeServices(
      net: FakeNet((r, body) {
        final u = r.url.toString();
        if (u.contains('lrclib.net/api/get')) return jsonRes(hit(1, now, _fx(now.original)));
        if (u.contains('lrclib.net/api/search')) {
          return jsonRes([hit(1, now, _fx(now.original)), if (now.roman != null) hit(2, now, _fx(now.roman!))]);
        }
        if (u.contains('lrclib')) return jsonRes({}, 404);
        // the stand-in song has no lyrics page of its own (the shared fixture is another song's)
        if (body.toString().contains('MPLY')) return jsonRes({}, 404);
        return catalogue(r, body);
      }),
    );
    sv.settings.autoplay = false;
    sv.settings.font = 'Roboto';
    CoverCache.dir = Directory.systemTemp.createTempSync('byte_shots_');
    CoverCache.fetch = (u) async => _art;
  });

  Future<void> at(WidgetTester tester, int ms) async {
    await tester.runAsync(() async {
      await sv.player.pause();
      await sv.player.seek(Duration(milliseconds: ms));
    });
    sv.player.clock.set(ms, playing: false);
  }

  Future<void> boot(WidgetTester tester, Size size, _Song s) async {
    now = s;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    sv.settings.themeMode = ThemeMode.dark;
    sv.settings.lyricsAutoFullScreen = false;
    await tester.runAsync(() => sv.player.playItems([s.item], from: 'Search'));
    await tester.pumpWidget(RepaintBoundary(key: _key, child: const ByteApp()));
    await _pump(tester);
  }

  Future<void> lyricsAt(WidgetTester tester, int ms) async {
    await at(tester, ms);
    await _pump(tester, n: 10);
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('1.4.4 lyrics shots', (tester) async {
    addTearDown(tester.view.reset);
    Future<void> close() async {
      LyricsPane.idle.value = false;
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> scene(String name, Size size, {bool full = false}) async {
      final s = _songs['tamil']!;
      await boot(tester, size, s);
      await tester.tap(find.byKey(const ValueKey('mini')));
      await _pump(tester);
      await tester.tap(find.byTooltip('Lyrics'));
      await _pump(tester);
      await lyricsAt(tester, s.atMs);
      expect(sv.settings.lyricsLook, isNull);
      if (full) {
        LyricsPane.idle.value = true;
        await _pump(tester, n: 6);
        await lyricsAt(tester, s.atMs);
        expect(find.byTooltip('Romanize'), findsNothing);
      } else {
        expect(find.textContaining('Romanized · ', findRichText: true), findsOneWidget);
      }
      await _shot(tester, name);
      await close();
    }

    await scene('lyrics_romanized_390', const Size(390, 844));
    await scene('lyrics_romanized_1280', const Size(1280, 800));
    await scene('lyrics_fullscreen_390', const Size(390, 844), full: true);
    await scene('lyrics_fullscreen_1280', const Size(1280, 800), full: true);
  });
}
