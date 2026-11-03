// Shared screen tour for the layout and real-data screenshot tests.
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/screens/listen_together_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Snap = Future<void> Function(WidgetTester t, String name);
typedef Settle = Future<void> Function(WidgetTester t, {int ms});

Future<void> shootAll(WidgetTester t, Services sv, Snap snap, Settle settle, String only) async {
  bool want(String n) => only.isEmpty || only.split(',').any((o) => n.startsWith(o));
  final shell = t.state<ShellState>(find.byType(Shell));
  Future<void> pop() async {
    shell.navKeys[shell.index].currentState?.pop();
    await settle(t, ms: 700);
  }

  Future<void> page(String name, Widget w, {Future<void> Function()? then}) async {
    if (!want(name)) return;
    pushInCurrentTab!(w);
    await settle(t, ms: 1200);
    await snap(t, name);
    if (then != null) await then();
    await pop();
  }

  Future<void> tapTip(String tip) async {
    final f = find.byTooltip(tip);
    if (f.evaluate().isEmpty) {
      // ignore: avoid_print
      print('no tooltip $tip');
      return;
    }
    await t.tap(f.first, warnIfMissed: false);
    await settle(t, ms: 1200);
  }

  if (want('home')) await snap(t, 'home');
  shell.select(1);
  await settle(t);
  if (want('explore')) await snap(t, 'explore');
  shell.select(2);
  await settle(t);
  if (want('library')) await snap(t, 'library');
  shell.select(3);
  await settle(t);
  if (want('search')) {
    await snap(t, 'search-yt');
    for (final tab in ['Library', 'Addons']) {
      final f = find.text(tab);
      if (f.evaluate().isNotEmpty) {
        await t.tap(f.last, warnIfMissed: false);
        await settle(t, ms: 800);
        await snap(t, 'search-${tab.toLowerCase()}');
      }
    }
  }
  if (find.text('DJ').evaluate().isNotEmpty && want('dj')) {
    final i = ShellState.tabs.indexWhere((x) => x.$3 == 'DJ');
    if (i >= 0) {
      shell.select(i);
      await settle(t, ms: 1500);
      await snap(t, 'dj-tab');
    }
  }
  shell.select(0);
  await settle(t);

  if (want('player')) {
    await t.tap(find.byKey(const ValueKey('mini')));
    await settle(t, ms: 1500);
    await snap(t, 'player');
    await tapTip('Lyrics');
    await snap(t, 'player-lyrics');
    final by = find.textContaining('Lyrics by');
    if (by.evaluate().isNotEmpty) {
      await t.tap(by.first, warnIfMissed: false);
      await settle(t, ms: 1500);
      await snap(t, 'player-lyrics-sources');
    }
    if (find.byType(BottomSheet).evaluate().isNotEmpty) {
      Navigator.of(find.byType(BottomSheet).evaluate().first).pop();
      await settle(t, ms: 600);
    }
    await tapTip('Queue');
    await snap(t, 'player-queue');
    await tapTip('Queue');
    await tapTip('Audio output');
    await snap(t, 'player-output');
    final pipe = find.text('Audio Pipeline');
    if (pipe.evaluate().isNotEmpty) {
      await t.tap(pipe.first, warnIfMissed: false);
      await settle(t, ms: 1200);
      await snap(t, 'player-pipeline');
    }
    for (var i = 0; i < 3; i++) {
      final nav = Navigator.of(find.byType(Scaffold).evaluate().last, rootNavigator: true);
      if (nav.canPop()) {
        nav.pop();
        await settle(t, ms: 600);
      }
    }
  }

  await page('settings', const SettingsScreen(), then: () async {
    await t.drag(find.byType(Scrollable).last, const Offset(0, -700));
    await settle(t, ms: 600);
    await snap(t, 'settings-2');
    await t.drag(find.byType(Scrollable).last, const Offset(0, -900));
    await settle(t, ms: 600);
    await snap(t, 'settings-3');
  });
  await page('set-account', const AccountScreen());
  await page('set-sources', const SourcesScreen());
  await page('set-downloads', const DownloadSettingsScreen());
  await page('set-playback', const PlaybackScreen());
  await page('set-appearance', const AppearanceScreen(), then: () async {
    await t.drag(find.byType(Scrollable).last, const Offset(0, -700));
    await settle(t, ms: 600);
    await snap(t, 'set-appearance-2');
  });
  await page('set-misc', const MiscScreen());
  await page('set-data', const YourDataScreen());
  await page('party', const ListenTogetherScreen());
  sv.settings.themeMode = sv.settings.themeMode;
}
