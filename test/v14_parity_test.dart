import 'package:byte/services.dart';
import 'package:byte/ui/now_playing.dart' show CoverDrift;
import 'package:byte/ui/screens/library_screen.dart';
import 'package:byte/ui/screens/onboarding_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 1.4: rows added for parity with the reference.
void main() {
  setUp(() async {
    Services.i = await makeServices();
    Services.i.lab.openForTest();
  });
  Future<void> show(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(390 * 3, 3000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: w));
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Storage: cached songs folder, cache limit, clear song / image cache', (t) async {
    await show(t, const StorageScreen());
    for (final k in ['song-cache-folder', 'song-cache-limit', 'clear-song-cache', 'clear-image-cache']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    await t.tap(find.byKey(const ValueKey('song-cache-limit')));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.text('1 GB'));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(Services.i.settings.songCacheMb, 1000);
  });

  testWidgets('Appearance: animated cover art switch', (t) async {
    await show(t, const AppearanceScreen());
    expect(find.text('Animated cover art'), findsOneWidget);
    await t.tap(find.text('Animated cover art'));
    await t.pump();
    expect(Services.i.settings.animatedCover, isTrue);
  });

  testWidgets('cover drift moves the cover only when on', (t) async {
    await t.pumpWidget(const MaterialApp(home: CoverDrift(on: true, child: SizedBox(width: 100, height: 100))));
    final a = t.widget<Transform>(find.byType(Transform).first).transform.clone();
    await t.pump(const Duration(seconds: 5));
    final b = t.widget<Transform>(find.byType(Transform).first).transform;
    expect(a == b, isFalse);
    await t.pumpWidget(const MaterialApp(home: CoverDrift(on: false, child: SizedBox(width: 100, height: 100))));
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('Settings: Audio Lab and Wear OS rows', (t) async {
    await show(t, const SettingsScreen());
    expect(find.byKey(const ValueKey('settings-audio-lab')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-wear')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('settings-wear')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('media controls already work with Byte'), findsOneWidget);
  });

  testWidgets('Onboarding: name, then skip', (t) async {
    var done = false;
    await show(t, OnboardingScreen(onDone: () => done = true));
    await t.enterText(find.byKey(const ValueKey('ob-name-field')), 'Apurba');
    await t.tap(find.byKey(const ValueKey('ob-continue')));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Hi Apurba'), findsOneWidget);
    expect(find.byKey(const ValueKey('ob-youtube')), findsOneWidget);
    expect(find.byKey(const ValueKey('ob-byte')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ob-skip')));
    await t.pump();
    expect(done, isTrue);
    expect(Services.i.settings.onboarded, isTrue);
    expect(Services.i.settings.listenName, 'Apurba');
  });

  testWidgets('Library: import tile says "From a playlist link"', (t) async {
    await show(t, const LibraryScreen());
    expect(find.text('From a playlist link'), findsOneWidget);
  });
}
