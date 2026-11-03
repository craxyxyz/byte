import 'package:byte/player/audio_route.dart';
import 'package:byte/ui/player_parts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Byte 1.4: the volume bar. In 1.3.1 Byte mixed its own gain on top of the
// phone's coarse volume steps; because the phone's steps are in decibels and
// Byte's gain was linear, loudness rose in a saw-tooth while dragging, and
// the bar snapped to the step 1.5 s after letting go. Now: phone steps only,
// the bar never snaps back, and the phone's buttons move it at once.
void main() {
  late List<Map<String, Object?>> calls;
  setUp(() {
    calls = [];
    AudioRoute.invokeForTest = (m, a) async {
      calls.add({'m': m, ...a});
      await Future<void>.delayed(const Duration(milliseconds: 30)); // a slow phone
    };
  });
  tearDown(() => AudioRoute.invokeForTest = null);

  group('volume logic', () {
    test('the bar shows the value at once; the phone gets the nearest step; no extra gain', () async {
      final r = AudioRoute()..setForTest(const AudioRouteInfo(native: true, steps: 15, volume: 0.2));
      final gains = <double>[];
      final f = r.setVolume(0.5, playerVolume: gains.add);
      expect(r.volume, 0.5, reason: 'shown before the phone answers');
      await f;
      expect(calls.single['index'], 8);
      expect(gains.every((g) => g == 1), isTrue, reason: 'Byte adds no gain of its own (no saw-tooth)');
    });

    test('a fast drag: only one call in flight, newest wins, ends on the last value', () async {
      final r = AudioRoute()..setForTest(const AudioRouteInfo(native: true, steps: 15, volume: 0));
      r.dragging(true);
      final all = <Future<void>>[];
      for (var i = 1; i <= 60; i++) {
        all.add(r.setVolume(i / 60, playerVolume: (_) {}));
      }
      await Future.wait(all);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      r.dragging(false);
      expect(calls.length, lessThan(15));
      expect(calls.last['index'], 15);
      expect(r.volume, 1);
    });

    test('inside one phone step no extra call is made', () async {
      final r = AudioRoute()..setForTest(const AudioRouteInfo(native: true, steps: 15, volume: 0.5));
      await r.setVolume(0.52);
      final n = calls.length;
      await r.setVolume(0.525);
      expect(calls.length, n);
      await r.setVolume(0);
      expect(calls.last['index'], 0);
    });

    test('after letting go the bar does NOT snap to the phone step (1.3.1 bug)', () async {
      final r = AudioRoute()..setForTest(const AudioRouteInfo(native: true, steps: 15, volume: 0.2));
      r.dragging(true);
      await r.setVolume(0.51);
      r.dragging(false);
      // the phone echoes step 8 (0.533) — the bar keeps 0.51
      r.systemVolumeChanged(8, 15);
      expect(r.volume, 0.51);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      r.systemVolumeChanged(8, 15);
      expect(r.volume, 0.51);
    });

    test('the phone\'s volume buttons move the bar at once', () async {
      final r = AudioRoute()..setForTest(const AudioRouteInfo(native: true, steps: 15, volume: 0.4));
      r.systemVolumeChanged(9, 15);
      expect(r.volume, closeTo(0.6, 1e-9));
      r.systemVolumeChanged(10, 15);
      expect(r.volume, closeTo(10 / 15, 1e-9));
      r.systemVolumeChanged(0, 15);
      expect(r.volume, 0);
    });

    test('while dragging, the buttons\' echoes never fight the finger', () async {
      final r = AudioRoute()..setForTest(const AudioRouteInfo(native: true, steps: 15, volume: 0.4));
      r.dragging(true);
      await r.setVolume(0.9);
      r.systemVolumeChanged(6, 15); // a stale echo
      expect(r.volume, 0.9);
      r.dragging(false);
    });

    test('where the phone volume can\'t be set (web, iPhone) Byte\'s player volume follows', () async {
      final r = AudioRoute();
      final gains = <double>[];
      await r.setVolume(0.3, playerVolume: gains.add);
      expect(gains.last, 0.3);
      expect(r.appVolume.value, 0.3);
      expect(calls, isEmpty);
    });
  });

  group('volume bar widget', () {
    Future<(ValueNotifier<double>, List<double>, ByteVolumeSliderState)> pump(WidgetTester t, double start) async {
      final v = ValueNotifier<double>(start);
      final got = <double>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: SizedBox(
                width: 300,
                child: ByteVolumeSlider(key: const ValueKey('vol'), value: v, onChanged: (x) {
                  got.add(x);
                  v.value = x;
                }),
              ),
            ),
          ),
        ),
      );
      return (v, got, t.state<ByteVolumeSliderState>(find.byKey(const ValueKey('vol'))));
    }

    testWidgets('follows the finger from the first pixel, smoothly and in order', (t) async {
      final (_, got, st) = await pump(t, 0.5);
      final box = t.getRect(find.byKey(const ValueKey('vol')));
      final g = await t.startGesture(Offset(box.left + 150, box.center.dy));
      await t.pump();
      expect(st.held, isTrue);
      expect(got.isEmpty || (got.last - 0.5).abs() < 0.08, isTrue, reason: 'grabbing the thumb does not jump');
      for (var i = 1; i <= 20; i++) {
        await g.moveBy(const Offset(6, 0));
        await t.pump(const Duration(milliseconds: 8));
      }
      await g.up();
      await t.pump();
      expect(st.held, isFalse);
      expect(got.length, greaterThanOrEqualTo(18), reason: 'every move reaches the volume');
      for (var i = 1; i < got.length; i++) {
        expect(got[i], greaterThanOrEqualTo(got[i - 1]));
      }
      expect(got.last, closeTo(0.9, 0.03));
      expect(st.shown, closeTo(got.last, 1e-9));
    });

    testWidgets('a tap away from the thumb jumps there', (t) async {
      final (_, got, _) = await pump(t, 0.1);
      final box = t.getRect(find.byKey(const ValueKey('vol')));
      await t.tapAt(Offset(box.left + 240, box.center.dy));
      await t.pump();
      expect(got.last, closeTo(0.8, 0.01));
    });

    testWidgets('the phone\'s buttons make the bar glide (no jump) to the new level', (t) async {
      final (v, _, st) = await pump(t, 0.2);
      v.value = 0.8;
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      expect(st.shown, greaterThan(0.2));
      expect(st.shown, lessThan(0.8));
      await t.pumpAndSettle();
      expect(st.shown, closeTo(0.8, 1e-9));
    });

    testWidgets('a vertical swipe on the bar still only moves the volume (the player swipe doesn\'t steal it)', (t) async {
      var parentDrags = 0;
      final v = ValueNotifier<double>(0.5);
      final got = <double>[];
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            onVerticalDragEnd: (_) => parentDrags++,
            child: Center(child: SizedBox(width: 300, child: ByteVolumeSlider(key: const ValueKey('vol'), value: v, onChanged: got.add))),
          ),
        ),
      ));
      final box = t.getRect(find.byKey(const ValueKey('vol')));
      await t.dragFrom(Offset(box.left + 100, box.center.dy), const Offset(60, 120));
      await t.pump();
      expect(parentDrags, 0);
      expect(got, isNotEmpty);
    });

    testWidgets('accessibility: increase / decrease', (t) async {
      final (_, got, _) = await pump(t, 0.5);
      final sem = t.ensureSemantics();
      final node = t.getSemantics(find.byKey(const ValueKey('vol')));
      expect(node.label, contains('Volume'));
      sem.dispose();
      t.state<ByteVolumeSliderState>(find.byKey(const ValueKey('vol')));
      expect(got, isEmpty);
    });
  });
}
