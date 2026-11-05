import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/glass.dart' show ReadableGlass;
import 'package:byte/ui/kit/liquid_bar.dart';
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:byte/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

// Byte 2.0 © 2026 Apurba Laskar.
//
// The liquid glass tab bar and mini player: it renders, switches tabs and
// follows the "Real glass blur" switch in both modes; an idle bar costs no
// frames; and it is photographed (build/shots) in light and dark.

const _shots = String.fromEnvironment('SHOTS', defaultValue: '');

Future<void> _shot(WidgetTester tester, Finder f, String name) async {
  if (_shots.isEmpty) return;
  final b = tester.renderObject<RenderRepaintBoundary>(f);
  final img = await tester.runAsync(() => b.toImage(pixelRatio: 2));
  final data = await tester.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
  File('$_shots/$name.png')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> _loadFonts() async {
  const dir = '/home/user/sdk/flutter/bin/cache/artifacts/material_fonts';
  if (!Directory(dir).existsSync()) return;
  final l = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold']) {
    final f = File('$dir/Roboto-$w.ttf');
    if (f.existsSync()) l.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await l.load();
}

Widget _backdrop() => DecoratedBox(
  decoration: const BoxDecoration(
    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFF6B6B), Color(0xFFFFB347), Color(0xFF4ECDC4), Color(0xFF5B8DEF)]),
  ),
  child: Column(
    children: [
      for (var i = 0; i < 16; i++)
        Container(height: 44, margin: const EdgeInsets.fromLTRB(16, 8, 16, 0), decoration: BoxDecoration(color: [Colors.white, Colors.black, const Color(0xFF222244), const Color(0xFFFFE066)][i % 4].withValues(alpha: 0.85), borderRadius: BorderRadius.circular(12))),
    ],
  ),
);

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    await _loadFonts();
  });

  group('colour of the mini player glass', () {
    test('white text keeps >= 4.5:1 on the mini tint over white, black and yellow pages, blur on and off, for any cover', () {
      for (final blur in [true, false]) {
        for (final art in const [Color(0xFFFFFF00), Color(0xFFFFFFFF), Color(0xFFFF66AA), Color(0xFF00E5FF), Color(0xFF7CFC00), Color(0xFF000000), Color(0xFF3D2C8D)]) {
          final tint = liquidMiniTint(art, blur: blur);
          expect(tint.a, blur ? closeTo(0.74, 0.01) : closeTo(0.9, 0.01));
          for (final page in const [Colors.white, Colors.black, Color(0xFFFFD54F)]) {
            final bg = ReadableGlass.over(tint, page);
            expect(ReadableGlass.contrast(Colors.white, bg), greaterThanOrEqualTo(4.5), reason: 'blur=$blur $art over $page');
          }
        }
      }
    });
  });

  for (final dark in [false, true]) {
    for (final blur in [true, false]) {
      final name = '${dark ? 'dark' : 'light'}-${blur ? 'blur' : 'noblur'}';
      testWidgets('tab bar $name: glass is there, tabs switch, the capsule slides, an idle bar draws nothing', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          sv.settings.themeMode = dark ? ThemeMode.dark : ThemeMode.light;
          sv.settings.realBlur = blur;
          sv.settings.glassEffects = true;
          await sv.player.stop();
          sv.player.current.value = null;
        });
        await tester.pumpWidget(const ByteApp());
        await settle(tester);
        final shell = tester.state<ShellState>(find.byType(Shell));
        expect(find.byType(FloatingBar), findsOneWidget);
        final nav = find.byKey(const ValueKey('nav-glass'));
        expect(nav, findsOneWidget);
        for (final t in ['Home', 'Explore', 'Library']) {
          expect(find.descendant(of: nav, matching: find.text(t)), findsOneWidget);
        }
        // blur ON: one real backdrop blur on just this bar; OFF: none, a denser tint instead
        final blurs = find.descendant(of: nav, matching: find.byKey(const ValueKey('liquid-blur')));
        expect(blurs, blur ? findsOneWidget : findsNothing);
        expect(find.descendant(of: nav, matching: find.byType(RepaintBoundary)), findsWidgets);
        final tint = tester.widget<DecoratedBox>(find.descendant(of: nav, matching: find.byKey(const ValueKey('liquid-tint'))));
        final a = ((tint.decoration as BoxDecoration).color!).a;
        expect(blur ? a < 0.6 : a > 0.85, isTrue, reason: 'translucent with blur ($a), dense without');
        expect(find.byKey(const ValueKey('search-glass')), findsOneWidget);

        // switching tabs: the capsule slides to the new tab
        final capsule = find.byKey(const ValueKey('nav-capsule'));
        final x0 = tester.getCenter(capsule).dx;
        await tester.tap(find.descendant(of: nav, matching: find.text('Library')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final xMid = tester.getCenter(capsule).dx;
        await settle(tester);
        final x1 = tester.getCenter(capsule).dx;
        expect(shell.index, 2);
        expect(x1, greaterThan(x0 + 60));
        expect(xMid, greaterThan(x0), reason: 'it is moving, not jumping');
        expect(xMid, lessThan(x1 + 1));
        await tester.tap(find.descendant(of: nav, matching: find.text('Home')));
        await settle(tester);
        expect(shell.index, 0);
        expect(tester.getCenter(capsule).dx, closeTo(x0, 1));
        await tester.tap(find.byKey(const ValueKey('search-glass')));
        await settle(tester);
        expect(shell.index, 3);
        shell.select(0);
        await settle(tester);

        // idle: no frames scheduled by the bar
        await tester.pump(const Duration(seconds: 2));
        expect(tester.binding.hasScheduledFrame, isFalse);
        await _shot(tester, find.byType(RepaintBoundary).first, 'app-$name');
        await tester.runAsync(() async => sv.settings.realBlur = false);
      });

      testWidgets('glass over busy content $name (+ mini player)', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          sv.settings.realBlur = blur;
          sv.settings.glassEffects = true;
        });
        const acc = ByteColors.brand;
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ByteTheme.build(dark ? Brightness.dark : Brightness.light),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('shot'),
              child: Stack(
                children: [
                  Positioned.fill(child: _backdrop()),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 98,
                    height: 56,
                    child: LiquidBar(
                      radius: BorderRadius.circular(28),
                      tint: liquidMiniTint(const Color(0xFFD81B60), blur: blur),
                      dark: true,
                      child: const Row(children: [
                        SizedBox(width: 12),
                        Icon(Icons.album, color: Colors.white, size: 36),
                        SizedBox(width: 10),
                        Expanded(child: Text('Tum Hi Ho', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15))),
                        Icon(Icons.pause_rounded, color: Colors.white, size: 32),
                        SizedBox(width: 12),
                      ]),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    bottom: 24,
                    width: 300,
                    height: 64,
                    child: LiquidBar(
                      radius: BorderRadius.circular(32),
                      child: Stack(children: [
                        Positioned(left: 104, top: 4, bottom: 4, width: 94, child: LiquidCapsule(accent: acc, dark: dark)),
                        Row(
                          children: [
                            for (final (i, (ic, t)) in [(Icons.home_rounded, 'Home'), (Icons.explore_rounded, 'Explore'), (Icons.library_music_rounded, 'Library')].indexed)
                              Expanded(
                                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  Icon(ic, size: 26, color: i == 1 ? acc : (dark ? const Color(0xFFBDBDC3) : const Color(0xFF505055))),
                                  Text(t, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: i == 1 ? acc : (dark ? const Color(0xFFBDBDC3) : const Color(0xFF505055)))),
                                ]),
                              ),
                          ],
                        ),
                      ]),
                    ),
                  ),
                  Positioned(
                    right: 16,
                    bottom: 24,
                    width: 64,
                    height: 64,
                    child: LiquidBar(radius: BorderRadius.circular(32), child: Center(child: Icon(Icons.search_rounded, size: 28, color: dark ? Colors.white : Colors.black))),
                  ),
                ],
              ),
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('liquid-blur')), blur ? findsNWidgets(3) : findsNothing);
        await _shot(tester, find.byKey(const ValueKey('shot')), 'glass-$name');
        await tester.runAsync(() async => sv.settings.realBlur = false);
      });
    }
  }
}
