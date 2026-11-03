// © 2026 Apurba Laskar
// Byte 1.4.3 — renders the three Developer card concepts (A Vinyl,
// B Aurora glass, C Signature) as light | dark entrance frames + stills,
// and checks reduce-motion and the links.
// Frames: SHOTS_DIR=… SHOTS_VIDEO=1 flutter test test_shots/v143_dev_concepts_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/ui/developer_concepts.dart';
import 'package:byte/ui/developer_card.dart' show DeveloperLinks;
import 'package:byte/ui/style.dart';
import 'package:byte/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _fonts = '/home/user/sdk/flutter/bin/cache/artifacts/material_fonts';
final _out = Platform.environment['SHOTS_DIR'] ?? 'build/shots/dev_concepts';
final _video = Platform.environment['SHOTS_VIDEO'] != null;

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

const _titles = {'A': 'Design 1 · Vinyl', 'B': 'Design 2 · Aurora glass', 'C': 'Design 3 · Signature'};

Widget _page(String id, Brightness b, {bool still = false, Future<bool> Function(Uri)? open}) {
  final o = open ?? (Uri u) async => true;
  final card = switch (id) {
    'A' => DeveloperConceptA(open: o),
    'B' => DeveloperConceptB(open: o),
    _ => DeveloperConceptC(open: o),
  };
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ByteTheme.build(b, font: 'Roboto'),
    home: Builder(
      builder: (context) {
        final p = BytePalette.of(context);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: still),
          child: RepaintBoundary(
            key: _key,
            child: Material(
              color: p.bg,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 72, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('About Byte', style: BT.largeTitle.copyWith(color: p.label)),
                    const SizedBox(height: 4),
                    Text(_titles[id]!, style: BT.sub.copyWith(color: p.secondary)),
                    const SizedBox(height: 120),
                    card,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

Future<void> _run(WidgetTester tester, Duration d) async {
  for (var e = Duration.zero; e < d; e += const Duration(milliseconds: 100)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(_loadFonts);

  void sized(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
  }

  for (final id in ['A', 'B', 'C']) {
    testWidgets('concept $id renders, frames + stills', (tester) async {
      sized(tester);
      for (final b in [Brightness.light, Brightness.dark]) {
        final mode = b == Brightness.light ? 'light' : 'dark';
        await tester.pumpWidget(_page(id, b));
        if (_video) {
          final frames = id == 'A' ? 135 : 120;
          TestGesture? g;
          for (var f = 0; f < frames; f++) {
            if (id == 'A' && f == 72) await tester.tap(find.byType(DeveloperConceptA));
            if (id == 'B') {
              final c = tester.getCenter(find.byType(DeveloperConceptB));
              if (f == 78) g = await tester.startGesture(c + const Offset(-60, -50));
              if (f > 78 && f <= 92) await g!.moveBy(const Offset(9, 0));
              if (f > 92 && f <= 100) await g!.moveBy(const Offset(-24, 6));
              if (f == 101) await g!.up();
            }
            await tester.pump(const Duration(microseconds: 33333));
            await _shot(tester, 'frames/${id}_$mode/f${f.toString().padLeft(3, '0')}');
          }
        }
        if (_video) {
          // start the stills from a fresh card (the video flipped / dragged it)
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(_page(id, b));
        }
        await _run(tester, const Duration(seconds: 4));
        expect(tester.takeException(), isNull);
        await _shot(tester, 'still_${id}_$mode');
        if (id == 'A') {
          await tester.tap(find.byType(DeveloperConceptA));
          await _run(tester, const Duration(seconds: 1));
          await _shot(tester, 'still_A_back_$mode');
        }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('concept $id: reduce motion shows everything at rest, no ticker', (tester) async {
      sized(tester);
      await tester.pumpWidget(_page(id, Brightness.light, still: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.transientCallbackCount, 0, reason: 'nothing animates with animations off');
      expect(find.text('DEVELOPER'), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Apurba Laskar')), findsWidgets);
      await _shot(tester, 'still_${id}_reduce_motion');
    });

    testWidgets('concept $id: links open his profiles', (tester) async {
      sized(tester);
      final opened = <Uri>[];
      await tester.pumpWidget(_page(id, Brightness.light, open: (u) async {
        opened.add(u);
        return true;
      }));
      await _run(tester, const Duration(seconds: 4));
      if (id == 'A') {
        await tester.tap(find.byType(DeveloperConceptA));
        await _run(tester, const Duration(seconds: 1));
      }
      await tester.tap(find.bySemanticsLabel(RegExp('^Instagram|^@apurbaaa_')).first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.bySemanticsLabel(RegExp('^Facebook')).first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(opened, [DeveloperLinks.instagram, DeveloperLinks.facebook]);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
