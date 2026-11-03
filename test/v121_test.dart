import 'dart:io';
import 'dart:math';

import 'package:byte/app.dart';
import 'package:byte/brand.dart';
import 'package:byte/dj/dj_controller.dart';
import 'package:byte/dj/dj_session.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/app_icon_picker.dart';
import 'package:byte/ui/app_icons.dart';
import 'package:byte/ui/dj_card.dart';
import 'package:byte/ui/logo.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/dj_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:byte/ui/style.dart';
import 'package:byte/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dj_test.dart' show FakeYt, song;
import 'helpers.dart';
import 'screens_test.dart' show settle;

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

/// Byte 1.2.1: the new "b)" logo, the 15-icon picker and the brand look.
void main() {
  group('icon pack wiring', () {
    test('15 icons, unique ids and native names, every preview bundled', () {
      expect(AppIcons.all.length, 15);
      expect(AppIcons.all.map((e) => e.id).toSet().length, 15);
      expect(AppIcons.all.map((e) => e.native).toSet().length, 15);
      expect(AppIcons.all.first.id, 'default');
      for (final o in AppIcons.all) {
        expect(File(o.preview).existsSync(), isTrue, reason: o.preview);
      }
      final grouped = [for (final g in AppIcons.groups) ...g.$2];
      expect(grouped.length, 15);
      expect(grouped.toSet(), AppIcons.all.map((e) => e.id).toSet());
      expect(AppIcons.byId('pixel-neon-cyan').shape, IconShape.circle);
      expect(AppIcons.byId('samsung-glass').shape, IconShape.squircle);
    });

    test('an icon saved by an older version falls back to Default', () {
      expect(AppIcons.normalize('midnight'), 'default');
      expect(AppIcons.normalize('neon-violet'), 'neon-violet');
    });

    test('Android: one launcher alias per icon, only Default enabled, resources present', () {
      final mf = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final aliases = RegExp(r'<activity-alias android:name="\.Logo(\w+)"[^>]*android:enabled="(true|false)"[^>]*android:icon="@mipmap/(\w+)"').allMatches(mf).toList();
      expect(aliases.length, 15);
      expect(aliases.where((m) => m.group(2) == 'true').map((m) => m.group(1)), ['Default']);
      expect(aliases.map((m) => m.group(1)).toSet(), AppIcons.all.map((e) => e.native).toSet());
      expect(mf.contains('.IconMidnight'), isFalse);
      for (final m in aliases) {
        final res = m.group(3)!;
        for (final d in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
          expect(File('android/app/src/main/res/mipmap-$d/$res.png').existsSync(), isTrue, reason: '$d $res');
        }
        final xml = File('android/app/src/main/res/mipmap-anydpi-v26/$res.xml').readAsStringSync();
        expect(xml, contains('<monochrome android:drawable="@mipmap/ic_launcher_themed"'), reason: res);
        expect(xml.contains('@mipmap/$res"'), isFalse, reason: '$res must not point at itself');
      }
      final kt = File('android/app/src/main/kotlin/com/apurbalaskar/byteapp/MainActivity.kt').readAsStringSync();
      for (final o in AppIcons.all) {
        expect(kt, contains('"${o.native}"'));
      }
      expect(kt, contains('com.apurbalaskar.byteapp.Logo'));
    });

    test('iPhone: alternate icon sets exist and are listed in the project', () {
      final pb = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      final line = RegExp(r'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "([^"]+)"').firstMatch(pb)!.group(1)!.split(' ');
      expect(line.toSet(), AppIcons.all.skip(1).map((e) => 'AppIcon-${e.native}').toSet());
      for (final n in line) {
        expect(File('ios/Runner/Assets.xcassets/$n.appiconset/icon-1024.png').existsSync(), isTrue, reason: n);
      }
      expect(File('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png').existsSync(), isTrue);
    });
  });

  group('brand colours', () {
    test('text contrast passes AA', () {
      expect(contrast(BytePalette.light.accent, BytePalette.light.bg), greaterThanOrEqualTo(4.5));
      expect(contrast(BytePalette.light.accent, BytePalette.light.grouped), greaterThanOrEqualTo(4.5));
      expect(contrast(BytePalette.dark.accent, BytePalette.dark.bg), greaterThanOrEqualTo(4.5));
      expect(contrast(BytePalette.dark.accent, BytePalette.dark.grouped), greaterThanOrEqualTo(4.5));
      expect(contrast(Colors.white, ByteColors.brand), greaterThanOrEqualTo(4.5));
      expect(contrast(Colors.white, ByteColors.deep), greaterThanOrEqualTo(4.5));
      expect(contrast(BytePalette.light.secondary, BytePalette.light.bg), greaterThanOrEqualTo(4.5));
      expect(contrast(BytePalette.dark.secondary, BytePalette.dark.bg), greaterThanOrEqualTo(4.5));
    });

    test('buttons, sliders and switches use the logo red in both themes', () {
      for (final b in Brightness.values) {
        final t = ByteTheme.build(b);
        expect(t.colorScheme.primary, ByteColors.brand);
        expect(t.colorScheme.onPrimary, Colors.white);
        expect(t.sliderTheme.activeTrackColor, ByteColors.brand);
        expect(t.progressIndicatorTheme.color, ByteColors.brand);
      }
    });
  });

  group('screens', () {
    late Services sv;
    setUpAll(() async {
      sv = await makeServices();
      sv.settings.autoplay = false;
      sv.settings.verifyStreams = false;
      for (var i = 0; i < 6; i++) {
        await sv.library.setLiked(song('v121s$i'.padRight(11, 'Q'), 'Tum Hi Ho $i', artist: 'Arijit Singh'), true);
      }
      sv.dj = DjController(
        player: sv.player,
        brain: DjBrain(library: sv.library, stats: sv.stats, yt: FakeYt(), rng: Random(2), now: () => DateTime(2026, 11, 2, 22, 10)),
        settings: sv.settings,
        now: () => DateTime(2026, 11, 2, 22, 10),
      );
    });

    void pop(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).at(1)).pop();
    const sizes = {'360': Size(360, 780), '390': Size(390, 844), '820': Size(820, 1180)};

    testWidgets('new look + icon picker at 360/390/820 px, light and dark', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      final calls = <String>[];
      const ch = MethodChannel('byte/icons');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
        calls.add('${c.method}:${c.arguments}');
        return c.method == 'set' ? true : 'Default';
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));
      sv.settings.appIcon = 'midnight'; // left over from v1.2
      var first = true;
      for (final e in sizes.entries) {
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          final tag = '${e.key}px ${mode.name}';
          tester.view.physicalSize = e.value;
          sv.settings.themeMode = mode;
          await tester.pumpWidget(const ByteApp());
          await settle(tester);

          // Home: the wordmark (the DJ card moved to the DJ tab in 1.3)
          expect(find.byType(ByteWordmark), findsOneWidget, reason: tag);
          expect(tester.takeException(), isNull, reason: tag);
          // selected tab is drawn in the brand colour
          final p = BytePalette.of(tester.element(find.byType(ByteWordmark)));
          final homeIcons = tester.widgetList<Icon>(find.byIcon(Icons.home_rounded));
          if (homeIcons.isNotEmpty) expect(homeIcons.first.color, p.accent, reason: tag);

          // Appearance → App icon
          pushInCurrentTab!(const AppearanceScreen());
          await settle(tester);
          // App icon is the last row (after the 1.3 rows); scroll down to it
          await tester.dragUntilVisible(find.text('App icon'), find.byType(Scrollable).last, const Offset(0, -300));
          await settle(tester);
          expect(find.text('App icon'), findsOneWidget, reason: tag);
          expect(find.text('Default'), findsWidgets, reason: tag); // "midnight" fell back (Font shows Default too)
          await tester.tap(find.text('App icon'));
          await settle(tester);
          expect(find.byType(AppIconGrid), findsOneWidget, reason: tag);
          for (final o in AppIcons.all) {
            expect(find.text(o.label), findsOneWidget, reason: '$tag ${o.label}');
          }
          expect(find.byType(Image), findsNWidgets(15), reason: tag);
          expect(tester.takeException(), isNull, reason: tag);
          if (first) {
            await tester.tap(find.text('Neon Violet'));
            await settle(tester);
            expect(calls, contains('set:NeonViolet'));
            expect(sv.settings.appIcon, 'neon-violet');
            await tester.tap(find.text('Default'));
            await settle(tester);
            expect(calls.last, 'set:Default');
            expect(sv.settings.appIcon, 'default');
          }
          pop(tester);
          await settle(tester);
          pop(tester);
          await settle(tester);

          // About: the new logo and the owner
          pushInCurrentTab!(const AboutScreen());
          await settle(tester);
          expect(find.descendant(of: find.byType(AboutScreen), matching: find.byType(ByteLogo)), findsOneWidget, reason: tag);
          expect(find.text('© 2026 Apurba Laskar'), findsOneWidget, reason: tag);
          expect(find.text('Version ${Brand.version}'), findsWidgets, reason: tag);
          expect(tester.takeException(), isNull, reason: tag);
          pop(tester);
          await settle(tester);

          // Automix (brand banner) and the DJ screen
          for (final page in const [AutomixScreen(), DjScreen()]) {
            pushInCurrentTab!(page);
            await settle(tester);
            expect(find.byType(DjSurface), findsWidgets, reason: '$tag ${page.runtimeType}');
            expect(tester.takeException(), isNull, reason: '$tag ${page.runtimeType}');
            pop(tester);
            await settle(tester);
          }
          first = false;
        }
      }
      expect(Brand.version, '1.4.4');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    });
  });
}
