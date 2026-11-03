// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba): on a laptop / MacBook / desktop / Linux, full-screen lyrics
// fill the whole screen: the window goes real full screen (no title bar, no
// taskbar), Esc / F11 / leaving the lyrics bring the window back, and the
// mouse pointer hides after 3 s without a move.
import 'package:byte/services.dart';
import 'package:byte/ui/app_fullscreen.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;

class FakeWindow implements WindowFullscreen {
  final List<bool> calls = [];
  bool full = false;
  @override
  Future<void> set(bool on) async {
    calls.add(on);
    full = on;
  }
}

void main() {
  late Services sv;
  late FakeWindow win;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });
  setUp(() {
    win = FakeWindow();
    AppFullscreen.window = win;
    AppFullscreen.active.value = false;
  });

  Future<void> quiet(WidgetTester tester, [int halfSeconds = 10]) async {
    for (var i = 0; i < halfSeconds; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  testWidgets('desktop: lyrics go full screen → the window goes full screen; Esc brings it back', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = true;
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(win.full, isFalse, reason: 'not before the lyrics go full screen');
    await quiet(tester);
    expect(LyricsPane.idle.value, isTrue);
    expect(win.full, isTrue, reason: 'real full screen: title bar and taskbar gone');
    expect(AppFullscreen.active.value, isTrue);
    // a click brings the controls back but keeps the window full screen (no jumping window)
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(LyricsPane.idle.value, isFalse);
    expect(win.full, isTrue);
    // Esc: back to the normal window
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(win.full, isFalse);
    expect(win.calls, [true, false]);
    // F11 toggles
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(win.full, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(win.full, isFalse);
    await closeAll(tester, sv);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop: leaving the lyrics or closing the player restores the window', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = true;
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pump(const Duration(milliseconds: 400));
    await quiet(tester);
    expect(win.full, isTrue);
    await closeAll(tester, sv);
    expect(win.full, isFalse, reason: 'closing the player gives the window back');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop: the mouse pointer hides after 3 s in full screen and comes back on a move', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = true;
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pump(const Duration(milliseconds: 400));
    await quiet(tester);
    expect(win.full, isTrue);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(200, 300));
    await tester.pump();
    MouseCursor cursorNow() => RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1) ?? SystemMouseCursors.basic;
    await gesture.moveTo(const Offset(210, 310));
    await tester.pump();
    expect(cursorNow(), isNot(SystemMouseCursors.none));
    await tester.pump(const Duration(milliseconds: 3200));
    expect(cursorNow(), SystemMouseCursors.none);
    await gesture.moveTo(const Offset(240, 330));
    await tester.pump();
    expect(cursorNow(), isNot(SystemMouseCursors.none));
    await gesture.removePointer();
    await closeAll(tester, sv);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: the window is left alone (the player keeps its own immersive mode)', (tester) async {
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = true;
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pump(const Duration(milliseconds: 400));
    await quiet(tester);
    expect(LyricsPane.idle.value, isTrue);
    // the switch is flipped, but on a phone the platform window does nothing
    expect(AppFullscreen.active.value, isTrue);
    await closeAll(tester, sv);
    expect(AppFullscreen.active.value, isFalse);
  });
}
