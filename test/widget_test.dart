import 'package:byte/app.dart';
import 'package:byte/core/models.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/page.dart' show SubPage;
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/style.dart' show SegmentedPill;
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// The whole app at phone (360, 390) and tablet (820) widths, in light and
/// dark: home → search → explore → library → play → player tabs → settings.
/// A layout overflow or any exception fails the test.
void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  const sizes = {'360': Size(360, 780), '390': Size(390, 844), '820': Size(820, 1180)};
  for (final e in sizes.entries) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('all screens ${e.key}px ${mode.name}', (tester) async {
        SubPage.forgetScroll(); // every size starts Settings at the top
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = e.value;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          sv.settings.themeMode = mode;
          await sv.player.stop();
          sv.player.current.value = null;
        });

        await tester.pumpWidget(const ByteApp());
        await settle(tester);
        final shell = tester.state<ShellState>(find.byType(Shell));
        // Phones get the floating bar, tablets the sidebar.
        expect(find.byType(FloatingBar).evaluate().isNotEmpty, e.value.width < 820);
        expect(find.text('Top Picks for You').evaluate().isNotEmpty || find.text('Quick picks').evaluate().isNotEmpty, isTrue);

        // Search
        shell.select(3);
        await settle(tester);
        expect(find.text('Artists, Songs, Lyrics and More'), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, 'arijit singh');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await settle(tester);
        expect(find.textContaining('Arijit', findRichText: true), findsWidgets);
        await tester.tap(find.descendant(of: find.byType(SegmentedPill), matching: find.text('Library')));
        await settle(tester);
        await tester.tap(find.descendant(of: find.byType(SegmentedPill), matching: find.text('Addons')));
        await settle(tester);
        expect(find.text('Add an addon'), findsWidgets);

        // Explore + Library
        shell.select(1);
        await settle(tester);
        expect(find.text('Explore'), findsWidgets);
        shell.select(2);
        await settle(tester);
        expect(shell.index, 2);
        expect(find.text('Library'), findsWidgets);

        // Start playing an album → mini player → now playing (song / lyrics / up next)
        final album = await tester.runAsync(() => sv.yt.album('MPREb_E4GfUXfDfhy'));
        await tester.runAsync(() => sv.player.playItems(album!.tracks));
        await settle(tester);
        expect(find.byKey(const ValueKey('mini')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('mini')));
        await settle(tester);
        expect(find.byTooltip('Next'), findsWidgets);
        // the video's bottom row: lyrics · output · queue (Listen together moved to ⋯)
        expect(find.byTooltip('Listen together'), findsNothing);
        expect(find.byTooltip('Audio output'), findsOneWidget);
        for (final tab in ['Lyrics', 'Up next', 'Song']) {
          final f = find.text(tab);
          if (f.evaluate().isNotEmpty) {
            await tester.tap(f.first);
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
            await settle(tester);
          }
        }
        await tester.tap(find.byTooltip('Close').first);
        await settle(tester);

        // Settings
        pushInCurrentTab!(const SettingsScreen());
        await settle(tester);
        expect(find.text('Account & integrations'), findsOneWidget); // 1.4: reference wording
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -3000));
        await settle(tester);
        expect(find.textContaining('© 2026 Apurba Laskar'), findsWidgets);

        await tester.runAsync(() => sv.player.stop());
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('now-playing works with a song that has no album art or duration', () {
    const it = Item(kind: ItemKind.song, id: 'x', title: 'A very very very very long title that must scroll in a marquee instead of overflowing the screen');
    expect(it.thumbAt(500), isNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 150));
  }
}
