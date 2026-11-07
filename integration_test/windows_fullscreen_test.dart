// Byte © 2026 Apurba Laskar
// Runs on the Windows runner (flutter test integration_test/windows_fullscreen_test.dart -d windows):
// Byte's own Windows full screen takes the frame off the window (no caption, no
// border), puts it on the whole monitor, and gives back the exact style and place
// it had. When BYTE_FS_DIR is set it also saves screenshots of the full-screen
// window, reads the top and bottom 4 pixel rows of each (they must be the page's
// dark background, not white), and writes a result file there.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/ui/app_fullscreen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const int _wsCaption = 0x00C00000;
const int _wsThickFrame = 0x00040000;
const int _wsBorder = 0x00800000;

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

/// Average brightness (0 black .. 255 white) of the top 4 and bottom 4 pixel rows of a PNG.
Future<String> _edges(String path) async {
  final esc = path.replaceAll("'", "''");
  final script = r'''Add-Type -AssemblyName System.Drawing; $bmp=[System.Drawing.Bitmap]::FromFile('ESC'); $w=$bmp.Width; $h=$bmp.Height; function Avg($y0,$y1){ $s=0.0; $n=0; for($y=$y0;$y -lt $y1;$y++){ for($x=0;$x -lt $w;$x+=4){ $c=$bmp.GetPixel($x,$y); $s+=($c.R+$c.G+$c.B)/3.0; $n++ } }; [math]::Round($s/$n,1) }; "top4=$(Avg 0 4) bottom4=$(Avg ($h-4) $h) size=${w}x${h}"; $bmp.Dispose()'''.replaceFirst('ESC', esc);
  final r = await Process.run('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script]);
  return r.exitCode == 0 ? '${r.stdout}'.trim() : 'pixel check failed: ${r.stderr}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows: full screen takes the frame off the window and gives it back', (tester) async {
    AppFullscreen.desktopHook = (on) => AppFullscreen.setWindowsFullScreen(on);
    AppFullscreen.window = AppFullscreen.platform;
    AppFullscreen.active.value = false;
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
    final beforeRect = AppFullscreen.windowsRect();
    final beforeStyle = AppFullscreen.windowsStyle();
    lines.add('screen ${screenW.round()}x${screenH.round()} logical');
    lines.add('before: rect=$beforeRect style=0x${beforeStyle.toRadixString(16)}');

    await tester.runAsync(() async {
      await AppFullscreen.enter();
      await _settle();
    });
    final fullRect = AppFullscreen.windowsRect();
    final fullMon = AppFullscreen.windowsMonitorRect();
    final fullStyle = AppFullscreen.windowsStyle();
    lines.add('full: active=${AppFullscreen.active.value} rect=$fullRect monitor=$fullMon style=0x${fullStyle.toRadixString(16)}');
    if (dir != null) {
      try {
        await tester.runAsync(() => _screenshot('$dir${Platform.pathSeparator}fullscreen.png'));
        lines.add('shot ${await tester.runAsync(() => _edges('$dir${Platform.pathSeparator}fullscreen.png'))}');
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
    final laterRect = AppFullscreen.windowsRect();
    lines.add('full, later: rect=$laterRect');
    if (dir != null) {
      try {
        await tester.runAsync(() => _screenshot('$dir${Platform.pathSeparator}fullscreen-later.png'));
        lines.add('later shot ${await tester.runAsync(() => _edges('$dir${Platform.pathSeparator}fullscreen-later.png'))}');
      } catch (e) {
        lines.add('later screenshot failed: $e');
      }
    }

    await tester.runAsync(() async {
      await AppFullscreen.exit();
      await _settle();
    });
    final afterRect = AppFullscreen.windowsRect();
    final afterStyle = AppFullscreen.windowsStyle();
    lines.add('back: active=${AppFullscreen.active.value} rect=$afterRect style=0x${afterStyle.toRadixString(16)}');
    if (dir != null) {
      await File('$dir${Platform.pathSeparator}result.txt').writeAsString('${lines.join('\n')}\n');
    }

    expect(AppFullscreen.active.value, isFalse, reason: 'the window left full screen');
    expect(fullRect.length, 4);
    expect(fullMon.length, 4);
    expect(fullRect, fullMon, reason: 'the window covers the whole monitor: its rectangle is the monitor rectangle');
    expect(fullStyle & _wsCaption, 0, reason: 'no title bar');
    expect(fullStyle & _wsThickFrame, 0, reason: 'no resize frame');
    expect(fullStyle & _wsBorder, 0, reason: 'no border');
    expect(laterRect, fullRect, reason: 'still the monitor a few frames later');
    expect(afterRect, beforeRect, reason: 'the exact place and size come back');
    expect(afterStyle, beforeStyle, reason: 'the exact style comes back');
  });
}
