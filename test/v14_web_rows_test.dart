// © 2026 Apurba Laskar
import 'package:byte/core/platform_caps.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/page.dart';
import 'package:byte/ui/player_parts.dart' show showOutputSheet;
import 'package:byte/ui/screens/audio_lab_screen.dart';
import 'package:byte/ui/screens/library_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 1.4 web: rows a browser can't use are hidden; Settings stays a
// readable column on wide screens.
void main() {
  setUp(() async {
    Services.i = await makeServices();
    Services.i.lab.openForTest();
  });
  tearDown(() => debugPretendWeb = false);

  Future<void> show(WidgetTester t, Widget w, {double width = 390}) async {
    t.view.physicalSize = Size(width * 2, 3000 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: w));
    await t.pump(const Duration(milliseconds: 300));
  }

  for (final web in [false, true]) {
    final label = web ? 'web' : 'phone';
    testWidgets('$label: Settings shows Downloads / Local Music only on the phone', (t) async {
      debugPretendWeb = web;
      await show(t, const SettingsScreen());
      expect(find.text('Downloads'), web ? findsNothing : findsOneWidget);
      expect(find.text('Local Music'), web ? findsNothing : findsOneWidget);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-wear')), web ? findsNothing : findsOneWidget);
      final titles = settingsIndex().map((e) => e.title).toSet();
      expect(titles.contains('Downloads'), !web);
      expect(titles.contains('Local Music'), !web);
    });

    testWidgets('$label: Library shows Downloads / Local Music only on the phone', (t) async {
      debugPretendWeb = web;
      await show(t, const LibraryScreen());
      expect(find.text('Downloads'), web ? findsNothing : findsOneWidget);
      expect(find.text('Local Music'), web ? findsNothing : findsOneWidget);
    });

    testWidgets('$label: USB DAC and bit-perfect rows only on the phone', (t) async {
      debugPretendWeb = web;
      await show(t, const PlaybackScreen());
      expect(find.text('Prefer USB DAC'), web ? findsNothing : findsOneWidget);
      expect(find.text('Bit-perfect output'), web ? findsNothing : findsOneWidget);
      await show(t, const LabAudioPassScreen());
      expect(find.text('Use the USB DAC when connected'), web ? findsNothing : findsOneWidget);
      expect(find.text('Bit-perfect passthrough'), web ? findsNothing : findsOneWidget);
      expect(find.byKey(const ValueKey('pass-float')), findsOneWidget);
    });

    testWidgets('$label: output sheet offers Cast only on the phone', (t) async {
      debugPretendWeb = web;
      await show(t, Builder(builder: (c) => Scaffold(body: Center(child: TextButton(onPressed: () => showOutputSheet(c), child: const Text('open'))))));
      await t.tap(find.text('open'));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('TVs and speakers that support casting'), web ? findsNothing : findsOneWidget);
      Navigator.of(t.element(find.text('Audio output'))).pop();
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
  }

  testWidgets('wide screen: Settings content is capped to a readable column', (t) async {
    await show(t, const SettingsScreen(), width: 1440);
    expect(find.byKey(const ValueKey('subpage-capped')), findsOneWidget);
    final row = t.getRect(find.text('Storage'));
    expect(row.left, greaterThan((1440 - SubPage.maxContentWidth) / 2 - 1));
    expect(row.right, lessThan((1440 + SubPage.maxContentWidth) / 2 + 1));
  });

  testWidgets('phone width: no cap', (t) async {
    await show(t, const SettingsScreen());
    expect(find.byKey(const ValueKey('subpage-capped')), findsNothing);
  });
}
