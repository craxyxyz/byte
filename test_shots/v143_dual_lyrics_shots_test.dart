// Byte © 2026 Apurba Laskar.
// Golden screenshots for 1.4.3 dual lyrics (Apurba's "Jo Tu Na Mila" video):
// lyrics in another script show the original on the right and the same words
// in Roman letters on the left (or Roman over the original on a phone).
// Real lyrics from test/fixtures/dual. Run on its own:
//   SHOTS_DIR=... flutter test test_shots/v143_dual_lyrics_shots_test.dart
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
final _out = Platform.environment['SHOTS_DIR'] ?? 'build/shots/dual';
final _art = File(Platform.environment['SHOTS_ART'] ?? 'test_shots/cover.png').readAsBytesSync();
String _fx(String f) => File('test/fixtures/dual/$f').readAsStringSync();

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
  for (final fam in ['NotoNaskhArabic', 'NotoSansDevanagari', 'NotoSansBengali', 'NotoSansGurmukhi']) {
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
  'urdu': _Song(_item('dualUrdu001', 'Jo Tu Na Mila', 'Asim Azhar', 234), 'jo_tu_na_mila_ur.lrc', 'jo_tu_na_mila_roman.lrc', 149800),
  'punjabi': _Song(_item('dualPa00001', '295', 'Sidhu Moose Wala', 273), '295_pa.lrc', '295_roman.lrc', 24600),
  'bengali': _Song(_item('dualBn00001', 'Bojhena Shey Bojhena', 'Arijit Singh', 429), 'bojhena_bn.lrc', null, 80600),
  'hindi': _Song(_item('dualHi00001', 'Tum Hi Ho', 'Arijit Singh', 262), 'tum_hi_ho_hi.lrc', 'tum_hi_ho_roman.lrc', 50200),
};

void main() {
  late Services sv;
  var now = _songs['urdu']!;

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

  testWidgets('dual lyrics shots', (tester) async {
    addTearDown(tester.view.reset);
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      if (Platform.environment['SHOTS_DEBUG'] != null) debugPrint('FLUTTER-ERROR ${d.exceptionAsString()}');
      prev?.call(d);
    };
    Future<void> close() async {
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> scene(String name, Size size, String k, {bool lyrics = true}) async {
      final s = _songs[k]!;
      await boot(tester, size, s);
      await tester.tap(find.byKey(const ValueKey('mini')));
      await _pump(tester);
      await lyricsAt(tester, s.atMs);
      if (lyrics) {
        await tester.tap(find.byTooltip('Lyrics'));
        await _pump(tester);
        await lyricsAt(tester, s.atMs);
      }
      await _shot(tester, name);
      await close();
    }

    const phone = Size(390, 844), tablet = Size(1280, 800);
    // phone, portrait: the player with the mini line (Roman only), then lyrics
    await scene('phone_player_mini_line_urdu', phone, 'urdu', lyrics: false);
    await scene('phone_stacked_urdu', phone, 'urdu');
    for (final k in ['punjabi', 'bengali', 'hindi']) {
      await scene('phone_stacked_$k', phone, k);
    }
    // the same phone with two columns, so he can compare
    LyricsDual.columnsFrom = 0;
    await scene('phone_columns_urdu', phone, 'urdu');
    LyricsDual.columnsFrom = 400;
    // tablet, landscape: two columns
    for (final k in ['urdu', 'punjabi', 'hindi']) {
      await scene('tablet_columns_$k', tablet, k);
    }
  });
}
