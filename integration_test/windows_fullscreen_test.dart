// Byte © 2026 Apurba Laskar
// Runs on the Windows runner (flutter test integration_test/windows_fullscreen_test.dart -d windows):
// the real window plugin and Byte's own full-screen switch take the window to
// full screen and give it back, and the window's size and place come back.
// When BYTE_FS_DIR is set, it also saves a screenshot of the full-screen window
// and a result file there.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/ui/app_fullscreen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 1500));

Future<void> _screenshot(String path) async {
  final esc = path.replaceAll("'", "''");
  final script = "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; "
      "\$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds; "
      "\$bmp=New-Object System.Drawing.Bitmap \$b.Width,\$b.Height; "
      "\$g=[System.Drawing.Graphics]::FromImage(\$bmp); "
      "\$g.CopyFromScreen(\$b.Location,[System.Drawing.Point]::Empty,\$b.Size); "
      "\$bmp.Save('$esc',[System.Drawing.Imaging.ImageFormat]::Png); \$g.Dispose(); \$bmp.Dispose()";
  final r = await Process.run('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script]);
  if (r.exitCode != 0) throw StateError('screenshot exit ${r.exitCode}: ${r.stderr}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows: full screen takes the window over and gives it back', (tester) async {
    await windowManager.ensureInitialized();
    AppFullscreen.desktopHook = (on) => windowManager.setFullScreen(on);
    AppFullscreen.window = AppFullscreen.platform;
    final dir = Platform.environment['BYTE_FS_DIR'];
    final lines = <String>[];
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Text('Byte full screen check', style: TextStyle(color: Colors.white, fontSize: 40))),
      ),
    ));
    await tester.runAsync(_settle);
    final view = ui.PlatformDispatcher.instance.views.first;
    final screenW = view.display.size.width / view.display.devicePixelRatio;
    final screenH = view.display.size.height / view.display.devicePixelRatio;
    final before = await windowManager.getBounds();
    final wasFull = await windowManager.isFullScreen();
    lines.add('screen ${screenW.round()}x${screenH.round()} logical');
    lines.add('before: full=$wasFull bounds=${before.left.round()},${before.top.round()} ${before.width.round()}x${before.height.round()}');

    await tester.runAsync(() async {
      await AppFullscreen.enter();
      await _settle();
    });
    final fullOn = await windowManager.isFullScreen();
    final during = await windowManager.getBounds();
    lines.add('full: full=$fullOn bounds=${during.left.round()},${during.top.round()} ${during.width.round()}x${during.height.round()}');
    if (dir != null) {
      try {
        await tester.runAsync(() => _screenshot('$dir${Platform.pathSeparator}fullscreen.png'));
        lines.add('screenshot saved');
      } catch (e) {
        lines.add('screenshot failed: $e');
      }
    }
    // a few frames later (the picture may lag the window on a computer with no graphics card)
    await tester.runAsync(() async {
      for (var i = 0; i < 3; i++) {
        WidgetsBinding.instance.scheduleForcedFrame();
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    });
    await tester.pump();
    final later = await windowManager.getBounds();
    lines.add('full, later: full=${await windowManager.isFullScreen()} bounds=${later.left.round()},${later.top.round()} ${later.width.round()}x${later.height.round()}');
    if (dir != null) {
      try {
        await tester.runAsync(() => _screenshot('$dir${Platform.pathSeparator}fullscreen-later.png'));
        lines.add('later screenshot saved');
      } catch (e) {
        lines.add('later screenshot failed: $e');
      }
    }

    await tester.runAsync(() async {
      await AppFullscreen.exit();
      await _settle();
    });
    final fullOff = await windowManager.isFullScreen();
    final after = await windowManager.getBounds();
    lines.add('back: full=$fullOff bounds=${after.left.round()},${after.top.round()} ${after.width.round()}x${after.height.round()}');
    if (dir != null) {
      await File('$dir${Platform.pathSeparator}result.txt').writeAsString('${lines.join('\n')}\n');
    }

    expect(fullOn, isTrue, reason: 'the window went full screen');
    expect(during.width >= screenW - 2 && during.height >= screenH - 2, isTrue, reason: 'it covers the screen (title bar and taskbar gone)');
    expect(fullOff, isFalse, reason: 'the window left full screen');
    expect(after.width, closeTo(before.width, 2));
    expect(after.height, closeTo(before.height, 2));
    expect(after.left, closeTo(before.left, 2));
    expect(after.top, closeTo(before.top, 2));
  });
}
