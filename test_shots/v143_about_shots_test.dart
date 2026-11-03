// Byte © 2026 Apurba Laskar
// Golden screenshots for 1.4.3: Settings → About with the Developer card,
// light and dark, 390 px. Run on its own: flutter test test_shots/v143_about_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/helpers.dart';

const _fonts = '/home/user/sdk/flutter/bin/cache/artifacts/material_fonts';
final _out = Platform.environment['SHOTS_DIR'] ?? 'build/shots';

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
  setUpAll(() async {
    await _loadFonts();
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.font = 'Roboto';
  });

  testWidgets('about shots', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    final video = Platform.environment['SHOTS_VIDEO'] != null;
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      sv.settings.themeMode = mode;
      await tester.pumpWidget(RepaintBoundary(key: _key, child: const ByteApp()));
      await _pump(tester);
      pushInCurrentTab!(const AboutScreen());
      await tester.pump();
      if (video) {
        // the entrance at 30 fps, as the page opens (the whole card is in view at the top)
        for (var f = 0; f < 75; f++) {
          await tester.pump(const Duration(microseconds: 33333));
          await _shot(tester, 'video_${mode.name}/f${f.toString().padLeft(3, '0')}');
        }
        await tester.pumpWidget(const SizedBox());
        await _pump(tester, n: 3);
        continue;
      }
      await _pump(tester, n: 32);
      expect(find.bySemanticsLabel(RegExp('Apurba Laskar')), findsWidgets);
      await _shot(tester, 'about_top_${mode.name}');
      // scrolled: the solid bar covers the logo, the card in full view
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -170), warnIfMissed: false);
      await _pump(tester);
      await _shot(tester, 'about_${mode.name}');
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -2000), warnIfMissed: false);
      await _pump(tester);
      await _shot(tester, 'about_end_${mode.name}');
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, n: 3);
    }
  });
}
