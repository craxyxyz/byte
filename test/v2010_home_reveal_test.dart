import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:byte/ui/home_reveal.dart';

/// Counts how often its own build runs: a section must be built once and then
/// only moved by the entrance, never rebuilt each frame.
class _Counted extends StatefulWidget {
  final void Function() onBuild;
  const _Counted({required this.onBuild});
  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return const SizedBox(width: 100, height: 40);
  }
}

Widget _page({required List<Widget> sections, bool disableAnimations = false}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Column(children: sections),
    ),
  );
}

/// Advances the clock in 16 ms frames, as a device would.
Future<void> _advance(WidgetTester t, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = left < 16 ? left : 16;
    await t.pump(Duration(milliseconds: step));
    left -= step;
  }
}

/// The entrance's translate, or null once the section has settled (no wrapper).
double _rise(WidgetTester t, Key key) {
  final finder = find.descendant(of: find.byKey(key), matching: find.byType(Transform));
  return t.widget<Transform>(finder.first).transform.getTranslation().y;
}

double _opacity(WidgetTester t, Key key) {
  final finder = find.descendant(of: find.byKey(key), matching: find.byType(Opacity));
  return t.widget<Opacity>(finder.first).opacity;
}

void main() {
  test('stagger steps 120 ms per place, capped at 8 steps', () {
    expect(homeRevealDelay(0), Duration.zero);
    expect(homeRevealDelay(1), const Duration(milliseconds: 120));
    expect(homeRevealDelay(3), const Duration(milliseconds: 360));
    expect(homeRevealDelay(8), const Duration(milliseconds: 960));
    expect(homeRevealDelay(40), homeRevealDelay(8));
  });

  testWidgets('a section starts at its place in the order and rises into place', (t) async {
    const a = Key('a');
    const b = Key('b');
    await t.pumpWidget(_page(sections: const [
      HomeReveal(key: a, index: 0, child: SizedBox(width: 100, height: 40)),
      HomeReveal(key: b, index: 2, child: SizedBox(width: 100, height: 40)),
    ]));
    // first frame: both sections start hidden and below their place
    expect(_rise(t, a), kHomeRevealRise);
    expect(_rise(t, b), kHomeRevealRise);

    await _advance(t, 120);
    // section 0 is already moving; section 2 (starts at 240 ms) has not moved
    expect(_rise(t, a), inExclusiveRange(0, kHomeRevealRise));
    expect(_rise(t, b), kHomeRevealRise);

    await _advance(t, 200); // 320 ms: section 2 began at 240 ms
    expect(_rise(t, b), inExclusiveRange(0, kHomeRevealRise));
    expect(_rise(t, b), greaterThan(_rise(t, a)), reason: 'the later section is still further down');
  });

  testWidgets('the entrance ends in about the duration and then unwraps', (t) async {
    const a = Key('a');
    await t.pumpWidget(_page(sections: const [HomeReveal(key: a, index: 0, child: SizedBox(width: 100, height: 40))]));
    await _advance(t, 240);
    expect(_rise(t, a), inExclusiveRange(0, kHomeRevealRise));
    expect(_opacity(t, a), inExclusiveRange(0, 1));
    await _advance(t, 600);
    expect(_rise(t, a), 0);
    expect(_opacity(t, a), 1);
    expect(find.byKey(a), findsOneWidget);
  });

  testWidgets('a later section waits for its own start, however long the page', (t) async {
    const late = Key('late');
    await t.pumpWidget(_page(sections: const [HomeReveal(key: late, index: 20, child: SizedBox(width: 100, height: 40))]));
    await _advance(t, 900);
    expect(_rise(t, late), kHomeRevealRise, reason: 'index 20 is capped at 8 steps = 960 ms');
    await _advance(t, 200);
    expect(_rise(t, late), inExclusiveRange(0, kHomeRevealRise));
  });

  testWidgets('reduce motion, in the app or the system, shows the section at once', (t) async {
    const a = Key('a');
    await t.pumpWidget(_page(
      disableAnimations: true,
      sections: const [HomeReveal(key: a, index: 4, child: SizedBox(width: 100, height: 40))],
    ));
    expect(_rise(t, a), 0);
    expect(_opacity(t, a), 1);
    await t.pump(const Duration(seconds: 2));
    expect(_rise(t, a), 0);
    expect(_opacity(t, a), 1);
    expect(find.byKey(a), findsOneWidget);
  });

  testWidgets('the section is built once; only the wrapper moves each frame', (t) async {
    var builds = 0;
    await t.pumpWidget(_page(sections: [
      HomeReveal(index: 0, child: _Counted(onBuild: () => builds++)),
    ]));
    final afterFirst = builds;
    await _advance(t, 1000);
    expect(builds, afterFirst, reason: 'no rebuild of the section while it enters or after it settles');
  });
}
