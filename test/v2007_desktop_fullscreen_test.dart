// Byte © 2026 Apurba Laskar.
//
// 2.0.7 (Apurba, Nov 7: "lyrics ke baad 4.5 sec rukna, uske baad lyrics full
// screen ho jana chahiye, upar niche koi bhi patti nahi honi chahiye"): the
// 4.5 s rule stays; on a computer the window then goes full screen, and Esc or
// F11 give it back and it is not taken again until the lyrics are opened again.
// On a phone, the web or a tablet the window is not touched.
import 'package:byte/services.dart';
import 'package:byte/ui/app_fullscreen.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;
import 'v145_desktop_fullscreen_test.dart' show FakeWindow;

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
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AppFullscreen.window = AppFullscreen.platform;
    AppFullscreen.active.value = false;
  });

  Future<void> quiet(WidgetTester tester, [int halfSeconds = 10]) async {
    for (var i = 0; i < halfSeconds; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  test('isDesktop: Windows, macOS and Linux only (not the web, phones or tablets)', () {
    for (final p in [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = p;
      expect(AppFullscreen.isDesktop, isTrue, reason: p.name);
    }
    for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = p;
      expect(AppFullscreen.isDesktop, isFalse, reason: p.name);
    }
  });

  testWidgets('desktop: the window goes full screen after the 4.5 s rule, not at the moment the lyrics open', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = true;
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(win.full, isFalse);
    await quiet(tester);
    expect(win.calls, [true]);
    expect(win.full, isTrue);
    await closeAll(tester, sv);
    debugDefaultTargetPlatformOverride = null;
    expect(win.full, isFalse);
  });

  testWidgets('desktop: Esc gives the window back and it is not taken again by itself', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = true;
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await quiet(tester);
    expect(win.full, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(win.full, isFalse);
    expect(LyricsPane.idle.value, isFalse, reason: 'the controls are back');
    await quiet(tester, 20);
    expect(win.calls, [true, false]);
    await closeAll(tester, sv);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop: F11 leaves full screen and holds; F11 again takes it while the lyrics are open', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = true;
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await quiet(tester);
    expect(win.full, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(win.full, isFalse);
    await quiet(tester, 20);
    expect(win.full, isFalse, reason: 'F11 out holds until the lyrics are opened again');
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(win.full, isTrue);
    await closeAll(tester, sv);
    debugDefaultTargetPlatformOverride = null;
    expect(win.full, isFalse, reason: 'closing the player gives the window back');
  });

  testWidgets('desktop: the setting off keeps the window as it is', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = false;
    addTearDown(() => sv.settings.lyricsAutoFullScreen = true);
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await quiet(tester);
    expect(win.full, isFalse);
    await closeAll(tester, sv);
    debugDefaultTargetPlatformOverride = null;
  });
}
