import 'dart:io';

import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/glass.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/now_playing.dart' show SeekBar;
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:byte/ui/player_parts.dart';
import 'package:byte/ui/screens/dj_screen.dart';
import 'package:byte/ui/screens/phone_setup_screen.dart';
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

/// Byte 1.3, round 3: the DJ is a small feature (no tab), one icon handler,
/// liquid glass everywhere, Phone setup for every Android brand.
void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
  });
  tearDown(GlassPerf.reset);

  group('DJ is a small feature, not a tab', () {
    test('the bottom bar has Home, Explore, Library (+ Search), no DJ', () {
      expect(ShellState.tabs.map((t) => t.$3), ['Home', 'Explore', 'Library', 'Search']);
      expect(ShellState.pillTabs, [0, 1, 2]);
    });

    testWidgets('Home: the DJ pill at the top opens the DJ (talk, mix, For you)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
      expect(find.text('DJ'), findsWidgets);
      final pill = find.byKey(const ValueKey('home-dj-pill'));
      expect(pill, findsOneWidget);
      // near the top of the screen, small
      final r = tester.getRect(pill);
      expect(r.top, lessThan(80));
      expect(r.height, lessThanOrEqualTo(44));
      // it's glass
      expect(find.descendant(of: pill, matching: find.byType(LiquidGlass)), findsOneWidget);
      await tester.tap(pill);
      await settle(tester);
      expect(find.byType(DjScreen), findsOneWidget);
      expect(find.byType(TalkToDjCard), findsOneWidget);
      expect(find.text('Start the DJ'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('player ⋯ has "Start DJ"', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
        await sv.player.playItems(album.tracks);
      });
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('mini')));
      await settle(tester);
      final ctx = tester.element(find.byType(SeekBar).first);
      showPlayerMore(ctx, sv.player.current.value!);
      await settle(tester);
      expect(find.text('Start DJ'), findsOneWidget);
      // the ⋯ sheet is liquid glass
      expect(find.byKey(const ValueKey('glass-sheet')), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await settle(tester);
      await tester.runAsync(() => sv.player.stop());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('app icon switch (Android)', () {
    final kt = File('android/app/src/main/kotlin/com/apurbalaskar/byteapp/MainActivity.kt').readAsStringSync();
    test('one "byte/icons" handler (a second one silently replaced the first)', () {
      expect('"byte/icons"'.allMatches(kt).length, 1);
    });
    test('"set" only records the choice; the switch happens in onStop (Byte in the background)', () {
      final start = kt.indexOf('"byte/icons"');
      final setBlock = kt.substring(kt.indexOf('"set" ->', start), kt.indexOf('"get" ->', start));
      expect(setBlock, contains('pendingIcon = want'));
      expect(setBlock, isNot(contains('setComponentEnabledSetting')));
      final onStop = kt.substring(kt.indexOf('override fun onStop'), kt.indexOf('private val ALIAS_PREFIX'));
      expect(onStop, contains('applyIcon(want)'));
      // "get" answers the pending choice, not cookies
      final getBlock = kt.substring(kt.indexOf('"get" ->', start), kt.indexOf('else -> result.notImplemented()', start));
      expect(getBlock, contains('pendingIcon'));
      expect(getBlock, isNot(contains('CookieManager')));
    });
  });

  group('liquid glass', () {
    Widget host(Widget child, {Brightness b = Brightness.light}) => MaterialApp(
      theme: ThemeData(brightness: b),
      home: Scaffold(body: Center(child: child)),
    );
    const box = LiquidGlass(radius: BorderRadius.all(Radius.circular(20)), child: SizedBox(width: 100, height: 40));

    double sigmaOf(WidgetTester t) {
      final f = t.widget<BackdropFilter>(find.byType(BackdropFilter)).filter;
      final m = RegExp(r'blur\(([\d.]+)').firstMatch(f.toString());
      return double.parse(m!.group(1)!);
    }

    // 2.0: no live blur by default (smooth scrolling); the frosted look is a
    // denser tint + the bright edge. Real glass blur is an opt-in setting.
    testWidgets('2.0 default: frosted tint + bright edge, no live blur', (t) async {
      expect(sv.settings.realBlur, isFalse);
      await t.pumpWidget(host(box));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byKey(const ValueKey('glass-edge')), findsOneWidget);
    });

    testWidgets('on with Real glass blur: blur + bright edge', (t) async {
      sv.settings.realBlur = true;
      addTearDown(() => sv.settings.realBlur = false);
      expect(sv.settings.liquidGlass, isTrue);
      await t.pumpWidget(host(box));
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byKey(const ValueKey('glass-edge')), findsOneWidget);
      expect(sigmaOf(t), greaterThan(15));
    });

    testWidgets('low-RAM phone: lighter blur', (t) async {
      sv.settings.realBlur = true;
      addTearDown(() => sv.settings.realBlur = false);
      GlassPerf.applyDeviceInfo({'lowRam': true, 'totalMemMb': 1900});
      expect(GlassPerf.light.value, isTrue);
      await t.pumpWidget(host(box));
      expect(sigmaOf(t), lessThan(8));
    });

    test('slow frames switch to the lighter glass; smooth frames don\'t', () {
      expect(GlassPerf.noteFrameTimes(List.filled(300, 9000)), isFalse);
      expect(GlassPerf.light.value, isFalse);
      expect(GlassPerf.noteFrameTimes(List.filled(300, 45000)), isTrue);
      expect(GlassPerf.light.value, isTrue);
      expect(GlassPerf.reason, 'slow-frames');
    });

    test('4 GB phone stays on full glass', () {
      GlassPerf.applyDeviceInfo({'lowRam': false, 'totalMemMb': 3800});
      expect(GlassPerf.light.value, isFalse);
    });

    testWidgets('setting off: solid, no blur', (t) async {
      sv.settings.liquidGlass = false;
      addTearDown(() => sv.settings.liquidGlass = true);
      await t.pumpWidget(host(box));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(glassLevel(), 0);
    });

    testWidgets('light and dark tints differ and stay readable', (t) async {
      final l = LiquidGlass.baseTint(dark: false, strong: true, level: 2);
      final d = LiquidGlass.baseTint(dark: true, strong: true, level: 2);
      expect(l.computeLuminance(), greaterThan(0.8));
      expect(d.computeLuminance(), lessThan(0.05));
      await t.pumpWidget(host(box, b: Brightness.dark));
      expect(t.takeException(), isNull);
    });

    testWidgets('toast, dialog and sheet are glass', (t) async {
      await t.pumpWidget(host(Builder(
        builder: (c) => Column(
          children: [
            TextButton(onPressed: () => toast(c, 'Saved'), child: const Text('toast')),
            TextButton(onPressed: () => showDialog<void>(context: c, builder: (_) => const GlassDialog(title: Text('Remove?'), content: Text('Sure?'))), child: const Text('dialog')),
            TextButton(onPressed: () => showByteSheet<void>(context: c, builder: (_) => const ListTile(title: Text('Row'))), child: const Text('sheet')),
          ],
        ),
      )));
      await t.tap(find.text('toast'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('glass-toast')), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
      await t.tap(find.text('dialog'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('glass-dialog')), findsOneWidget);
      expect(find.text('Remove?'), findsOneWidget);
      Navigator.of(t.element(find.text('Remove?'))).pop();
      await t.pumpAndSettle();
      await t.tap(find.text('sheet'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('glass-sheet')), findsOneWidget);
      expect(find.text('Row'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('search bar and scrolled top bar are glass', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 844);
      addTearDown(t.view.reset);
      await t.pumpWidget(const ByteApp());
      await settle(t);
      // Home scrolled: the glass top bar fades in
      final bar = find.byKey(const ValueKey('tab-glass-bar'));
      expect(t.widget<AnimatedOpacity>(bar.first).opacity, 0);
      await t.drag(find.byType(Scrollable).first, const Offset(0, -300), warnIfMissed: false);
      await settle(t);
      expect(t.widget<AnimatedOpacity>(bar.first).opacity, 1);
      ShellState.current!.select(3);
      await settle(t);
      expect(find.byKey(const ValueKey('glass-search')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('Phone setup (every Android brand)', () {
    PhoneInfo phone(String maker, {String? brand, bool miui = false, int sdk = 34}) =>
        PhoneInfo.fromMap({'manufacturer': maker, 'brand': brand ?? maker, 'model': 'X1', 'sdk': sdk, 'release': '14', 'miui': miui, 'totalMemMb': 6000});

    test('finds the family from the maker', () {
      expect(phone('Xiaomi', brand: 'Redmi').family, PhoneFamily.xiaomi);
      expect(phone('Xiaomi', brand: 'POCO').family, PhoneFamily.xiaomi);
      expect(phone('vivo').family, PhoneFamily.vivo);
      expect(phone('vivo', brand: 'iQOO').family, PhoneFamily.vivo);
      expect(phone('OPPO').family, PhoneFamily.oppo);
      expect(phone('realme').family, PhoneFamily.oppo);
      expect(phone('OnePlus').family, PhoneFamily.oppo);
      expect(phone('samsung').family, PhoneFamily.samsung);
      expect(phone('HUAWEI').family, PhoneFamily.huawei);
      expect(phone('HONOR').family, PhoneFamily.huawei);
      expect(phone('motorola').family, PhoneFamily.stock);
      expect(phone('HMD Global', brand: 'Nokia').family, PhoneFamily.stock);
      expect(phone('Google').family, PhoneFamily.stock);
      expect(phone('Tecno').family, PhoneFamily.other);
      expect(phone('Generic', miui: true).family, PhoneFamily.xiaomi);
    });

    test('the right steps per brand', () {
      List<String> kinds(PhoneInfo p) => phoneSetupSteps(p).map((s) => s.kind).toList();
      expect(kinds(phone('Xiaomi', brand: 'Redmi')), ['battery-request', 'autostart', 'lockscreen', 'battery', 'fullscreen']);
      expect(kinds(phone('vivo')), containsAll(['autostart', 'lockscreen', 'battery']));
      expect(kinds(phone('OPPO')), containsAll(['autostart', 'lockscreen', 'battery']));
      expect(kinds(phone('samsung')), ['battery-request', 'battery', 'notifications', 'fullscreen']);
      expect(kinds(phone('HUAWEI')), containsAll(['autostart', 'battery']));
      expect(kinds(phone('motorola', sdk: 30)), ['battery-request', 'notifications', 'overlay']);
      // Samsung's battery step says Unrestricted
      expect(phoneSetupSteps(phone('samsung')).firstWhere((s) => s.kind == 'battery').title, contains('Unrestricted'));
      // already ignoring battery optimisation: the step shows done
      final done = PhoneInfo.fromMap({'manufacturer': 'samsung', 'brand': 'samsung', 'ignoringBattery': true});
      expect(phoneSetupSteps(done).first.done, isTrue);
    });

    testWidgets('screen: shows the phone, opens the maker\'s pages, falls back to the app page', (t) async {
      final calls = <String>[];
      Future<Object?> invoke(String m, [Object? a]) async {
        calls.add(a == null ? m : '$m:$a');
        if (m == 'info') return {'manufacturer': 'Xiaomi', 'brand': 'Redmi', 'model': 'Note 12', 'sdk': 34, 'release': '14', 'miui': true, 'totalMemMb': 6000};
        if (m == 'open' && a == 'battery') return 'app';
        return 'maker';
      }

      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 1200);
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: PhoneSetupScreen(invoke: invoke)));
      await t.pumpAndSettle();
      expect(find.text('Redmi Note 12'), findsOneWidget);
      expect(find.text('Autostart'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('setup-autostart')));
      await t.pumpAndSettle();
      expect(calls, contains('open:autostart'));
      await t.tap(find.byKey(const ValueKey('setup-battery-request')));
      await t.pumpAndSettle();
      expect(calls, contains('requestIgnoreBattery'));
      await t.tap(find.byKey(const ValueKey('setup-battery')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(calls, contains('open:battery'));
      expect(find.textContaining('Byte\'s app page'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('settings: the Phone setup row is there', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 844);
      addTearDown(t.view.reset);
      await t.pumpWidget(const ByteApp());
      await settle(t);
      pushInCurrentTab!(const SettingsScreen());
      await settle(t);
      final row = find.byKey(const ValueKey('settings-phone-setup'));
      for (var i = 0; i < 12 && row.evaluate().isEmpty; i++) {
        await t.drag(find.byType(CustomScrollView).last, const Offset(0, -300), warnIfMissed: false);
        await settle(t);
      }
      expect(row, findsOneWidget);
      expect(find.text('Phone setup'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('iPhone: nothing Android-only runs', () {
    testWidgets('app, Home DJ pill, player, settings: no crash on iOS', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 844);
      addTearDown(t.view.reset);
      try {
        await t.runAsync(() async {
          final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
          await sv.player.playItems(album.tracks);
        });
        await t.pumpWidget(const ByteApp());
        await settle(t);
        expect(find.byKey(const ValueKey('home-dj-pill')), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('mini')));
        await settle(t);
        // sound only: no Song | Video switch anywhere
        expect(find.byKey(const ValueKey('song-video-switch')), findsNothing);
        expect(t.takeException(), isNull);
        Navigator.of(t.element(find.byType(SeekBar).first)).pop();
        await settle(t);
        pushInCurrentTab!(const SettingsScreen());
        await settle(t);
        // Phone setup is an Android page
        expect(find.byKey(const ValueKey('settings-phone-setup')), findsNothing);
        expect(t.takeException(), isNull);
        await t.runAsync(() => sv.player.stop());
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 2));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
