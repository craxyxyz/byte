
import 'dart:io';

import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/now_playing.dart';
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:byte/ui/screens/audio_lab_screen.dart';
import 'package:byte/ui/screens/listen_together_screen.dart';
import 'package:byte/ui/app_icon_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

// Byte 2.0 © 2026 Apurba Laskar.
//
// The smoothness tour: every main screen at phone and tablet sizes, idle,
// paused and playing. For each it measures frames drawn per second, widget
// rebuilds per second, and the costly layers on screen (live blur, shader
// masks, transparency layers). Writes build/perf_tour.tsv and fails when a
// still screen keeps drawing.

class Probe {
  double fps = 0, rebuilds = 0;
  int blur = 0, masks = 0, layers = 0;
}

Future<Probe> measure(WidgetTester tester, {int ms = 2000}) async {
  var frames = 0, builds = 0;
  final old = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (e, builtOnce) {
    builds++;
    final k = e.widget.runtimeType.toString();
    byType[k] = (byType[k] ?? 0) + 1;
  };
  for (var t = 0; t < ms; t += 16) {
    if (tester.binding.hasScheduledFrame) {
      frames++;
      await tester.pump(const Duration(milliseconds: 16));
    } else {
      await tester.binding.delayed(const Duration(milliseconds: 16));
    }
  }
  debugOnRebuildDirtyWidget = old;
  final p = Probe()
    ..fps = frames * 1000 / ms
    ..rebuilds = builds * 1000 / ms;
  // What really gets drawn: the composited layer tree of the last frame.
  void walk(Layer? l) {
    while (l != null) {
      if (l is BackdropFilterLayer || l is ImageFilterLayer) p.blur++;
      if (l is ShaderMaskLayer) p.masks++;
      if (l is OpacityLayer && (l.alpha ?? 255) < 255) p.layers++;
      if (l is ContainerLayer) walk(l.firstChild);
      l = l.nextSibling;
    }
  }
  for (final v in tester.binding.renderViews) {
    walk(v.debugLayer);
  }
  return p;
}

final rows = <String>[];
final byType = <String, int>{};

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });
  tearDownAll(() {
    final f = File('build/perf_tour.tsv');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('size\tscreen\tstate\tframes/s\trebuilds/s\tblur\tmasks\tlayers\n${rows.join('\n')}\n');
  });

  const sizes = {'phone': Size(390, 844), 'tablet-portrait': Size(800, 1280), 'tablet-landscape': Size(1280, 800)};
  final screens = <String, Widget Function()>{
    'Settings': () => const SettingsScreen(),
    'Audio Lab': () => const AudioLabScreen(),
    'About': () => const AboutScreen(),
    'App icon': () => const AppIconScreen(),
    'Party': () => const ListenTogetherScreen(),
  };
  for (final e in sizes.entries) {
    testWidgets('smoothness tour ${e.key}', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = e.value * 2;
      addTearDown(tester.view.reset);
      final fails = <String>[];
      Future<void> rec(String screen, String state) async {
        await settle(tester);
        await tester.pump(const Duration(seconds: 2));
        byType.clear();
        final p = await measure(tester);
        if (p.rebuilds > 200) {
          final top = byType.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
          // ignore: avoid_print
          print('REBUILDS ${e.key} $screen $state: ${top.take(14).map((x) => '${x.key}=${x.value}').join(' ')}');
        }
        rows.add('${e.key}\t$screen\t$state\t${p.fps.toStringAsFixed(1)}\t${p.rebuilds.toStringAsFixed(0)}\t${p.blur}\t${p.masks}\t${p.layers}');
        if (state != 'playing' && p.fps > 1) fails.add('$screen $state draws ${p.fps}/s');
        if (state == 'playing' && p.fps > 48) fails.add('$screen playing draws ${p.fps}/s');
      }

      Future<void> states(String screen) async {
        await tester.runAsync(() => sv.player.play());
        await rec(screen, 'playing');
        await tester.runAsync(() => sv.player.pause());
        await rec(screen, 'paused');
      }

      await tester.pumpWidget(const ByteApp());
      await rec('Home', 'nothing playing');
      await tester.runAsync(() async {
        final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
        await sv.player.playItems(album.tracks, from: 'Test Album');
      });
      await states('Home');
      for (final tab in [1, 2, 3]) {
        ShellState.current!.select(tab);
        await states(['Home', 'Explore', 'Library', 'Search'][tab]);
      }
      ShellState.current!.select(0);
      for (final s in screens.entries) {
        ShellState.current!.navKeys[0].currentState!.push(MaterialPageRoute(builder: (_) => s.value()));
        await states(s.key);
        ShellState.current!.navKeys[0].currentState!.pop();
        await settle(tester);
      }
      NowPlayingScreen.open(ShellState.current!.context);
      await states('Player');
      NowPlayingScreen.open(ShellState.current!.context, tab: NpTab.lyrics);
      await states('Lyrics');
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      // ignore: avoid_print
      print(rows.where((r) => r.startsWith(e.key)).join('\n'));
      expect(fails, isEmpty);
    });
  }
}
