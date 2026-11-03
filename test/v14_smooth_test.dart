import 'package:byte/ui/style.dart';
import 'package:byte/ui/theme.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Byte 1.4: smoothness rules that are checkable.
void main() {
  test('every page slides softly; ripples are the soft sparkle kind', () {
    final t = ByteTheme.build(Brightness.dark);
    expect(t.pageTransitionsTheme.builders[TargetPlatform.android], isA<CupertinoPageTransitionsBuilder>());
    expect(t.splashFactory, InkSparkle.splashFactory);
  });

  testWidgets('lists bounce everywhere and follow a mouse drag on the web', (t) async {
    late ScrollPhysics phys;
    await t.pumpWidget(MaterialApp(
      scrollBehavior: const ByteScrollBehavior(),
      home: Builder(builder: (c) {
        phys = ScrollConfiguration.of(c).getScrollPhysics(c);
        return const SizedBox();
      }),
    ));
    expect(phys, isA<BouncingScrollPhysics>());
    expect(const ByteScrollBehavior().dragDevices, contains(PointerDeviceKind.mouse));
  });

  testWidgets('switches give a light tap feel when flipped', (t) async {
    final calls = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      calls.add('${c.method}:${c.arguments}');
      return null;
    });
    var v = false;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: StatefulBuilder(builder: (c, set) => ByteSwitch(value: v, onChanged: (x) => set(() => v = x)))))));
    await t.tap(find.byType(ByteSwitch));
    await t.pumpAndSettle();
    expect(v, isTrue);
    expect(calls.any((c) => c.contains('HapticFeedback.vibrate') && c.contains('selectionClick')), isTrue);
  });
}
