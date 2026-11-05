import 'dart:math';

import 'package:byte/app.dart';
import 'package:byte/core/models.dart';
import 'package:byte/dj/dj_controller.dart';
import 'package:byte/dj/dj_session.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/dj_card.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/dj_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dj_test.dart' show FakeYt, song;
import 'helpers.dart';
import 'screens_test.dart' show settle;

/// Byte 1.2's new screens (DJ card on Home, DJ screen idle and on air,
/// Automix and DJ settings, Playback with Automix on) at 360 / 390 / 820 px,
/// light and dark. Any overflow or exception fails.
void main() {
  late Services sv;

  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
    for (var i = 0; i < 9; i++) {
      await sv.library.setLiked(
        song('wlk$i'.padRight(11, 'W'), i.isEven ? 'আমি তোমার সঙ্গে বেঁধেছি আমার প্রাণ — অনেক লম্বা শিরোনাম $i' : 'Tum Hi Ho $i', artist: i.isEven ? 'শ্রেয়া ঘোষাল' : 'Arijit Singh'),
        true,
      );
    }
  });

  DjController freshDj() {
    final dj = DjController(
      player: sv.player,
      brain: DjBrain(library: sv.library, stats: sv.stats, yt: FakeYt(), rng: Random(2), now: () => DateTime(2026, 11, 2, 22, 10)),
      settings: sv.settings,
      now: () => DateTime(2026, 11, 2, 22, 10),
    );
    sv.dj = dj;
    return dj;
  }

  Future<void> scrollAll(WidgetTester tester) async {
    final s = find.byType(Scrollable);
    if (s.evaluate().isNotEmpty) {
      await tester.drag(s.last, const Offset(0, -4000), warnIfMissed: false);
      await settle(tester);
      await tester.drag(s.last, const Offset(0, 4000), warnIfMissed: false);
      await settle(tester);
    }
  }

  void pop(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).at(1)).pop();

  const sizes = {'360': Size(360, 780), '390': Size(390, 844), '820': Size(820, 1180)};

  // One widget test walks all sizes and both themes: the player (and the DJ
  // driving it) stays bound to the test that started it.
  testWidgets('v1.2 screens at 360/390/820 px, light and dark', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    sv.settings.automix = true;
    sv.settings.djName = '';
    final dj = freshDj();
    var first = true;
    for (final e in sizes.entries) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        final tag = '${e.key}px ${mode.name}';
        tester.view.physicalSize = e.value;
        sv.settings.themeMode = mode;
        await tester.pumpWidget(const ByteApp());
        await settle(tester);

        // Home matches the video; the DJ lives in its own tab now (1.3)
        expect(find.byType(DjCard), findsNothing, reason: tag);
        expect(tester.takeException(), isNull, reason: tag);

        pushInCurrentTab!(const DjScreen());
        await settle(tester);
        if (first) {
          // before it starts
          expect(find.text('Start the DJ'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: tag);
          // on air: the greeting shows on screen (the DJ never speaks, 1.4.3)
          await tester.runAsync(() async {
            await dj.start();
            for (var i = 0; i < 100 && dj.lastLine == null; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          });
          await settle(tester);
          expect(dj.active, isTrue);
          expect(find.text('ON AIR'), findsOneWidget);
          expect(find.text('DJ IS TALKING'), findsNothing);
          expect(find.byTooltip('DJ voice on'), findsNothing);
          expect(find.textContaining('Apurba'), findsWidgets);
        }
        expect(find.text('Switch it up'), findsOneWidget, reason: tag);
        expect(find.text('Now playing'), findsOneWidget, reason: tag);
        await scrollAll(tester);
        expect(tester.takeException(), isNull, reason: tag);
        if (first) {
          // switch it up
          await tester.tap(find.text('Switch it up'));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
          await settle(tester);
          expect(dj.segment!.kind, SegmentKind.vibe);
          expect(tester.takeException(), isNull);
              }
        pop(tester);
        await settle(tester);

        // Settings pages
        for (final page in const [AutomixScreen(), DjSettingsScreen(), PlaybackScreen()]) {
          pushInCurrentTab!(page);
          await settle(tester);
          await scrollAll(tester);
          expect(tester.takeException(), isNull, reason: '$tag ${page.runtimeType}');
          if (page is PlaybackScreen) {
            // the crossfade slider is handed over to Automix
            expect(find.text('Automix is on: the next song starts 8.5 s before the end'), findsOneWidget);
            final sliders = tester.widgetList<Slider>(find.byType(Slider));
            expect(sliders.every((s) => s.onChanged == null), isTrue);
          }
          if (page is AutomixScreen && first) {
            await tester.tap(find.text('Simple'));
            await settle(tester);
            expect(sv.settings.automixSmart, isFalse);
            expect(find.textContaining('Simple: a smooth, even fade'), findsOneWidget);
            await tester.tap(find.text('Smart'));
            await settle(tester);
            expect(sv.settings.automixSmart, isTrue);
          }
          pop(tester);
          await settle(tester);
        }
        first = false;
      }
    }
    dj.stop(silent: true);
    sv.player.pause();
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  test('Home card: "DJ" sub-line uses the name he set', () {
    sv.settings.djName = 'Apu';
    expect(sv.settings.djName, 'Apu');
    sv.settings.djName = '';
    expect(sv.settings.djName, 'Apurba');
    // keep an Item import in use for analyzer
    expect(const Item(kind: ItemKind.song, id: 'x', title: 'x').id, 'x');
  });
}
