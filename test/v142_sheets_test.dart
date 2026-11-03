// Byte © 2026 Apurba Laskar
import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/glass.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/listen_together_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

// Byte 1.4.2 (Apurba's video, Nov 3): "Create a party" opened its sheet BEHIND
// the mini player and the tab bar, so "Party size" and the button were hidden.
// Every sheet now opens above them.
void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  Future<void> appWithMiniPlayer(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
      await sv.player.playItems(album.tracks, from: 'Test Album');
    });
    await tester.pumpWidget(const ByteApp());
    await settle(tester);
    expect(find.byKey(const ValueKey('mini')), findsOneWidget, reason: 'the mini player is showing');
  }

  Future<void> done(WidgetTester tester) async {
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  }

  testWidgets('Listen together → Create a party: the whole sheet is above the mini player; Party size and Create can be tapped', (tester) async {
    await appWithMiniPlayer(tester);
    pushInCurrentTab!(const ListenTogetherScreen());
    await settle(tester);
    await tester.tap(find.text('Create a party').first);
    await settle(tester);
    expect(find.text('Party size'), findsOneWidget);
    expect(find.text('Party size').hitTestable(), findsOneWidget, reason: 'not covered by the mini player / tab bar');
    expect(find.text('Create').hitTestable(), findsOneWidget, reason: 'the Create button can be tapped');
    // the size stepper works
    final plus = find.byIcon(Icons.add_rounded);
    if (plus.evaluate().isNotEmpty) {
      expect(plus.hitTestable(), findsWidgets);
    }
    // the sheet sits above the mini player: its button is lower on screen than the mini player's top
    final mini = tester.getRect(find.byKey(const ValueKey('mini')));
    final create = tester.getRect(find.text('Create'));
    expect(create.bottom, greaterThan(mini.top), reason: 'same screen area, and the button still wins the tap');
    Navigator.of(tester.element(find.text('Party size'))).pop();
    await settle(tester);
    // Join sheet too
    await tester.tap(find.text('Join existing').first);
    await settle(tester);
    expect(find.text('Join').hitTestable(), findsOneWidget);
    Navigator.of(tester.element(find.text('Join'))).pop();
    await settle(tester);
    await done(tester);
  });

  testWidgets('any glass sheet opened from a tab page sits above the mini player and tab bar', (tester) async {
    await appWithMiniPlayer(tester);
    pushInCurrentTab!(Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showByteSheet<void>(
              context: context,
              builder: (_) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [const SizedBox(height: 200), FilledButton(onPressed: () {}, child: const Text('Confirm at the bottom'))],
              ),
            ),
            child: const Text('open sheet'),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('open sheet'));
    await settle(tester);
    expect(find.text('Confirm at the bottom').hitTestable(), findsOneWidget);
    Navigator.of(tester.element(find.text('Confirm at the bottom'))).pop();
    await settle(tester);
    await done(tester);
  });
}
