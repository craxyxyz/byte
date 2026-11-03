import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lock_player.dart';
import 'lock_screen_view.dart';

/// Runs in the lock-screen window's own small engine (no plugins there):
/// everything goes through the `byte/lockplayer` channel.
void runLockScreenApp() {
  WidgetsFlutterBinding.ensureInitialized();
  // The engine may start before its window exists (warmed while the screen is off).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).catchError((Object _) {});
  final player = ChannelLockPlayer();
  runApp(LockScreenApp(player: player, onUnlock: player.unlock, onHide: player.hide));
  player.ready();
}

class LockScreenApp extends StatelessWidget {
  final LockPlayer player;
  final VoidCallback? onUnlock;
  final VoidCallback? onHide;
  final ImageProvider Function(String url) image;
  final DateTime Function() now;
  const LockScreenApp({super.key, required this.player, this.onUnlock, this.onHide, this.image = defaultLockImage, this.now = DateTime.now});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Byte',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(primary: Colors.white),
        fontFamilyFallback: const ['Roboto', 'Noto Sans', 'Noto Sans Devanagari', 'Noto Sans Bengali'],
      ),
      home: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF1E1D24),
          body: LockScreenView(player: player, onUnlock: onUnlock, onHide: onHide, image: image, now: now),
        ),
      ),
    );
  }
}
