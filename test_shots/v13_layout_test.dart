// Layout check: renders the main screens with the fake catalogue (no network)
// at the recording's aspect ratio, for side-by-side comparison.
//   flutter test test_shots/v13_layout_test.dart --dart-define=SHOTS=/tmp/byte13
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';
import 'shot_screens.dart';

final key = GlobalKey();
const outDir = String.fromEnvironment('SHOTS', defaultValue: '/tmp/byte13');
const only = String.fromEnvironment('ONLY', defaultValue: '');

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

Future<void> settle(WidgetTester t, {int ms = 1200}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await t.pump(const Duration(milliseconds: 120));
  }
}

Future<void> snap(WidgetTester t, String name) async {
  await settle(t, ms: 500);
  final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await t.runAsync(() async {
    final img = await b.toImage(pixelRatio: 1.5);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory(outDir).createSync(recursive: true);
    File('$outDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('snap $name');
}

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
  });

  testWidgets('layout', (t) async {
    await t.runAsync(loadFonts);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 878);
    addTearDown(t.view.reset);
    await t.pumpWidget(RepaintBoundary(key: key, child: const ByteApp()));
    await settle(t, ms: 2000);
    final album = await t.runAsync(() => sv.yt.album('MPREb_E4GfUXfDfhy'));
    await t.runAsync(() => sv.player.playItems(album!.tracks));
    await settle(t);
    await shootAll(t, sv, snap, settle, only);
    await t.runAsync(() => sv.player.stop());
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
