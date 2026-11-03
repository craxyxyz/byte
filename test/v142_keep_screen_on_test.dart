// Byte © 2026 Apurba Laskar
import 'package:byte/player/screen_awake.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;

// Byte 1.4.2 (Apurba, Nov 3): while the full lyrics screen is open the screen
// must never turn off — built in, no setting, playing or paused.
void main() {
  late Services sv;
  final calls = <bool>[];
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ScreenAwake.channel, (call) async {
      if (call.method == 'keepScreenOn') calls.add(call.arguments as bool);
      return true;
    });
  });
  setUp(() {
    calls.clear();
    ScreenAwake.resetForTest();
  });

  Future<void> background(WidgetTester t) async {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      t.binding.handleAppLifecycleStateChanged(s);
      await t.pump();
    }
  }

  Future<void> foreground(WidgetTester t) async {
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
      await t.pump();
    }
  }

  testWidgets('KeepScreenOn: on while shown; off on background, a page on top, removal; never times out', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(MaterialApp(navigatorKey: nav, home: const KeepScreenOn(child: Text('lyrics'))));
    expect(calls, [true]);
    expect(ScreenAwake.isOn, isTrue);

    // a long time later (paused or not): still on
    await t.pump(const Duration(hours: 2));
    expect(calls, [true]);

    // the notification shade / a call banner (inactive) is still "in front"
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(calls, [true]);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();

    // app to the background and back
    await background(t);
    expect(calls.last, isFalse);
    await foreground(t);
    expect(calls.last, isTrue);

    // another page covers the lyrics, then goes away
    nav.currentState!.push(MaterialPageRoute(builder: (_) => const Text('settings')));
    await t.pumpAndSettle();
    expect(calls.last, isFalse);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(calls.last, isTrue);

    // lyrics closed
    await t.pumpWidget(const MaterialApp(home: Text('home')));
    expect(calls.last, isFalse);
    expect(ScreenAwake.isOn, isFalse);
    for (var i = 1; i < calls.length; i++) {
      expect(calls[i] != calls[i - 1], isTrue, reason: 'call $i repeats');
    }
  });

  testWidgets('two holders: the screen stays on until both let go', (t) async {
    final a = Object(), b = Object();
    ScreenAwake.hold(a);
    ScreenAwake.hold(b);
    ScreenAwake.release(a);
    expect(ScreenAwake.isOn, isTrue);
    ScreenAwake.release(b);
    expect(ScreenAwake.isOn, isFalse);
    await t.pump();
    expect(calls, [true, false]);
  });

  testWidgets('real player: lyrics open keeps the screen on, paused too; background and closing release it', (t) async {
    addTearDown(t.view.reset);
    await openPlayer(t, sv);
    expect(calls, isEmpty, reason: 'the song view alone does not hold the screen');
    await t.tap(find.byTooltip('Lyrics'));
    await t.pump(const Duration(milliseconds: 400));
    expect(calls, [true]);
    expect(ScreenAwake.isOn, isTrue);
    // paused for a long time: still on
    await t.runAsync(() => sv.player.pause());
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(minutes: 5));
    }
    expect(calls, [true], reason: 'paused 30 min with lyrics open: still on');
    // background and back
    await background(t);
    expect(calls.last, isFalse);
    await foreground(t);
    expect(calls.last, isTrue);
    // close the player
    await t.binding.handlePopRoute();
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(calls.last, isFalse);
    expect(ScreenAwake.isOn, isFalse);
    await closeAll(t, sv);
  });

  testWidgets('no setting for it: built-in behaviour', (t) async {
    t.view.physicalSize = const Size(1170, 8000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: AppearanceScreen()));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Full-screen lyrics'), findsOneWidget);
    expect(find.textContaining('Keep screen on'), findsNothing);
  });
}
