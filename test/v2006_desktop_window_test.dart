// Byte © 2026 Apurba Laskar
// Byte 2.0.6: on a computer the lyrics' full screen goes to the window (the
// plugin's hook), on phones it does not; the hook gets true on enter and false
// on exit, once each, and a refusal leaves the app in its window.
import 'package:byte/ui/app_fullscreen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<bool> calls;

  setUp(() {
    calls = [];
    AppFullscreen.desktopHook = (on) async => calls.add(on);
    AppFullscreen.window = AppFullscreen.platform;
    AppFullscreen.active.value = false;
  });

  tearDown(() {
    AppFullscreen.desktopHook = null;
    debugDefaultTargetPlatformOverride = null;
    AppFullscreen.active.value = false;
  });

  for (final p in [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
    test('${p.name}: enter asks the window for full screen, exit gives it back', () async {
      debugDefaultTargetPlatformOverride = p;
      await AppFullscreen.enter();
      expect(AppFullscreen.active.value, isTrue);
      await AppFullscreen.enter(); // already in: no second call
      await AppFullscreen.exit();
      expect(AppFullscreen.active.value, isFalse);
      await AppFullscreen.exit(); // already out: nothing
      expect(calls, [true, false]);
    });
  }

  test('phone: the window hook is not used', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await AppFullscreen.enter();
    await AppFullscreen.exit();
    expect(calls, isEmpty);
  });

  test('a window refusal leaves the app in its window and the state consistent', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    AppFullscreen.desktopHook = (on) async => throw StateError('no window');
    await AppFullscreen.enter();
    expect(AppFullscreen.active.value, isTrue);
    await AppFullscreen.exit();
    expect(AppFullscreen.active.value, isFalse);
  });
}
