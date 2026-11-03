import 'dart:ui' as ui;

import 'package:byte/ui/art_background.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/now_playing.dart' show Marquee;
import 'package:byte/ui/smooth_wheel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

// Byte © 2026 Apurba Laskar.
//
// 1.4.5.2 (computer lag): the player must not redraw nonstop when nothing
// moves, the cover blur is made once, and the mouse wheel glides.

class _Ticking extends StatefulWidget {
  const _Ticking();
  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking> with SingleTickerProviderStateMixin {
  late final Ticker t;
  late final LyricsPace pace;
  int ticks = 0;
  @override
  void initState() {
    super.initState();
    t = createTicker((_) => tick());
    pace = LyricsPace(t, tick);
    pace.wake();
  }

  void tick() {
    ticks++;
    pace.update();
  }

  @override
  void dispose() {
    pace.dispose();
    t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  tearDown(() => LyricsPace.isPlaying = () => true);

  testWidgets('lyric clock: per frame while playing, no frames while paused, back on play', (tester) async {
    var playing = true;
    LyricsPace.isPlaying = () => playing;
    await tester.pumpWidget(const _Ticking());
    final st = tester.state<_TickingState>(find.byType(_Ticking));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(st.pace.perFrame, isTrue);
    expect(tester.binding.hasScheduledFrame, isTrue);
    playing = false;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(st.pace.perFrame, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'paused: nothing asks for frames');
    final before = st.ticks;
    await tester.pump(const Duration(seconds: 1));
    expect(st.ticks - before, inInclusiveRange(3, 5), reason: 'paused: a 4×/s check (catches a seek)');
    playing = true;
    await tester.pump(const Duration(milliseconds: 300));
    expect(st.pace.perFrame, isTrue);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('computers: a playing song\'s lyrics move 30×/s on a timer, not every refresh', (tester) async {
    LyricsPace.isPlaying = () => true;
    LyricsPace.playingStepMs = 33;
    addTearDown(() => LyricsPace.playingStepMs = 0);
    await tester.pumpWidget(const _Ticking());
    final st = tester.state<_TickingState>(find.byType(_Ticking));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(st.pace.perFrame, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    final before = st.ticks;
    await tester.pump(const Duration(seconds: 1));
    expect(st.ticks - before, inInclusiveRange(28, 32));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a long title scrolls only while a song plays, and draws nothing while it waits', (tester) async {
    var playing = false;
    LyricsPace.isPlaying = () => playing;
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(width: 100, child: Marquee(text: 'A very very long song title that never fits', style: TextStyle(fontSize: 20))),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'paused: the title stays still, no frames');
    }
    playing = true;
    var frames = 0;
    for (var i = 0; i < 400; i++) {
      if (tester.binding.hasScheduledFrame) frames++;
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(frames, greaterThan(20), reason: 'playing: it scrolls');
    await tester.pumpWidget(const SizedBox());
  });

  test('cover blur is made once into a small image of the same size', () {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(const Rect.fromLTWH(0, 0, 32, 64), Paint()..color = const Color(0xFFFF0000));
    c.drawRect(const Rect.fromLTWH(32, 0, 32, 64), Paint()..color = const Color(0xFF0000FF));
    final src = rec.endRecording().toImageSync(64, 64);
    final out = BlurredCover.blur(src);
    expect(out.width, 64);
    expect(out.height, 64);
    src.dispose();
    out.dispose();
  });

  testWidgets('mouse wheel glides the list under the pointer, notches add up', (tester) async {
    SmoothWheel.enabled = true;
    SmoothWheel.stepFactor = 2.0;
    addTearDown(() => SmoothWheel.enabled = false);
    final ctl = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: ListView.builder(controller: ctl, itemCount: 200, itemExtent: 50, itemBuilder: (_, i) => Text('row $i')),
      ),
    );
    Future<bool> wheel(double dy) async {
      final at = tester.getCenter(find.byType(ListView));
      final r = HitTestResult();
      tester.binding.hitTestInView(r, at, tester.view.viewId);
      return SmoothWheel.handle(PointerScrollEvent(position: at, scrollDelta: Offset(0, dy)), r);
    }

    expect(await wheel(60), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final mid = ctl.offset;
    expect(mid, greaterThan(0));
    expect(mid, lessThan(120), reason: 'eased, not a jump');
    expect(await wheel(60), isTrue, reason: 'a second notch while gliding');
    await tester.pumpAndSettle();
    expect(ctl.offset, 240, reason: '2 notches × 60 × 2.0');
    // back up past the top: stops at 0
    expect(await wheel(-600), isTrue);
    await tester.pumpAndSettle();
    expect(ctl.offset, 0);
    // at the top already: not handled (the default / an outer list takes it)
    expect(await wheel(-60), isFalse);
    // small precise deltas are not multiplied
    expect(await wheel(10), isTrue);
    await tester.pumpAndSettle();
    expect(ctl.offset, 10);
  });

  testWidgets('mouse wheel over a sideways shelf scrolls the page around it', (tester) async {
    SmoothWheel.enabled = true;
    SmoothWheel.stepFactor = 1.0;
    addTearDown(() => SmoothWheel.enabled = false);
    final outer = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: outer,
          children: [
            SizedBox(
              height: 120,
              child: ListView(key: const ValueKey('shelf'), scrollDirection: Axis.horizontal, children: [for (var i = 0; i < 20; i++) const SizedBox(width: 100)]),
            ),
            for (var i = 0; i < 40; i++) const SizedBox(height: 50),
          ],
        ),
      ),
    );
    final at = tester.getCenter(find.byKey(const ValueKey('shelf')));
    final r = HitTestResult();
    tester.binding.hitTestInView(r, at, tester.view.viewId);
    expect(SmoothWheel.handle(PointerScrollEvent(position: at, scrollDelta: const Offset(0, 60)), r), isTrue);
    await tester.pumpAndSettle();
    expect(outer.offset, 60);
  });

  testWidgets('mouse wheel: page views and trackpads keep the default', (tester) async {
    SmoothWheel.enabled = true;
    addTearDown(() => SmoothWheel.enabled = false);
    await tester.pumpWidget(MaterialApp(home: PageView(children: const [Text('a'), Text('b')])));
    final at = tester.getCenter(find.byType(PageView));
    final r = HitTestResult();
    tester.binding.hitTestInView(r, at, tester.view.viewId);
    expect(SmoothWheel.handle(PointerScrollEvent(position: at, scrollDelta: const Offset(0, 60)), r), isFalse);
    expect(SmoothWheel.handle(PointerScrollEvent(position: at, kind: PointerDeviceKind.trackpad, scrollDelta: const Offset(0, 60)), r), isFalse);
  });
}
