import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../lock/handler_lock_player.dart';
import '../../lock/lock_bridge.dart';
import '../../lock/lock_screen_view.dart';
import '../../services.dart';
import '../page.dart';
import '../style.dart';
import '../widgets.dart';

/// Settings → Playback → Lock screen player.
class LockScreenSettingsScreen extends StatefulWidget {
  /// Tests pass a status instead of asking Android.
  final LockScreenStatus? status;
  const LockScreenSettingsScreen({super.key, this.status});

  @override
  State<LockScreenSettingsScreen> createState() => _LockScreenSettingsScreenState();
}

class _LockScreenSettingsScreenState extends State<LockScreenSettingsScreen> with WidgetsBindingObserver {
  LockScreenStatus? _status;

  @override
  void initState() {
    super.initState();
    _status = widget.status;
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from a system settings page: read the permissions again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (widget.status != null) return;
    final s = await LockScreenBridge.status();
    if (mounted && s != null) setState(() => _status = s);
  }

  Future<void> _preview() async {
    final native = await LockScreenBridge.preview();
    if (native || !mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (context, _, _) => const LockScreenPreview(),
        transitionsBuilder: (context, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) {
        final p = BytePalette.of(context);
        final on = st.lockScreenPlayer;
        final s = _status;
        Widget note(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
          child: Text(t, style: BT.sub.copyWith(color: p.secondary)),
        );
        return SubPage(capWidth: true, 
          title: 'Lock screen player',
          showProfile: false,
          slivers: [
            SliverList.list(
              children: [
                GroupCard(
                  children: [
                    GroupRow(
                      key: const ValueKey('lock-toggle'),
                      icon: Icons.lock_rounded,
                      title: 'Lock screen player',
                      subtitle: 'Byte\'s player on the lock screen while music plays',
                      trailing: ByteSwitch(value: on, onChanged: (v) => st.lockScreenPlayer = v),
                      onTap: () => st.lockScreenPlayer = !on,
                    ),
                    GroupRow(
                      key: const ValueKey('lock-preview'),
                      icon: Icons.visibility_rounded,
                      title: 'Preview',
                      subtitle: 'See how it looks',
                      chevron: true,
                      onTap: _preview,
                    ),
                  ],
                ),
                note(
                  on
                      ? 'When you turn the screen on while a song plays, Byte\'s player opens on top of the lock screen. Tap the cover to make it big, tap again to make it small. Swipe up to unlock, swipe down to see your normal lock screen.'
                      : 'Off: Byte doesn\'t open anything on the lock screen. The usual media controls from the notification still work.',
                ),
                if (on && s != null) ...[
                  const SizedBox(height: 22),
                  GroupCard(
                    children: [
                      if (s.sdk >= 34)
                        GroupRow(
                          key: const ValueKey('lock-fsi'),
                          icon: Icons.fullscreen_rounded,
                          title: 'Open over the lock screen',
                          subtitle: s.canFullScreenIntent ? 'Allowed' : 'Not allowed yet: tap to allow',
                          titleColor: s.canFullScreenIntent ? null : p.accent,
                          chevron: true,
                          onTap: LockScreenBridge.openFullScreenSettings,
                        ),
                      if (!s.notificationsEnabled)
                        GroupRow(
                          icon: Icons.notifications_off_rounded,
                          title: 'Notifications are off for Byte',
                          subtitle: 'Turn them on: the lock screen player needs them',
                          titleColor: p.accent,
                          chevron: true,
                          onTap: LockScreenBridge.openNotificationSettings,
                        ),
                      GroupRow(
                        icon: Icons.layers_rounded,
                        title: 'Display over other apps',
                        subtitle: s.canDrawOverlays ? 'Allowed' : 'Optional: makes it open faster on some phones',
                        chevron: true,
                        onTap: LockScreenBridge.openOverlaySettings,
                      ),
                      GroupRow(
                        key: const ValueKey('lock-oem'),
                        icon: Icons.phone_android_rounded,
                        title: s.xiaomi ? 'Xiaomi permissions' : 'Phone permissions',
                        subtitle: s.xiaomi ? 'Show on Lock screen, pop-up windows' : 'Lock screen, background, battery',
                        chevron: true,
                        onTap: LockScreenBridge.openOemSettings,
                      ),
                    ],
                  ),
                  note(oemNote(s)),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The brand-specific hint under the permission rows.
String oemNote(LockScreenStatus s) {
  if (s.xiaomi) {
    return 'Xiaomi, Redmi and POCO phones block apps from the lock screen until you allow it. Tap “Xiaomi permissions” and turn on “Show on Lock screen” and “Display pop-up windows while running in the background”. Also set Battery saver to “No restrictions”.';
  }
  if (s.samsung) {
    return 'Samsung: it works by itself. If the player doesn\'t show, check that notifications are on for Byte and Battery is “Unrestricted” (Settings → Apps → Byte).';
  }
  if (s.vivo) {
    return 'vivo / iQOO: tap “Phone permissions” and allow “Display on lock screen” and “Pop-up windows in background”. Turn on “Background power consumption” for Byte too.';
  }
  if (s.oppo) {
    return 'OPPO, realme and OnePlus: allow “Display over other apps” and “Lock screen display” if you see them, and set Battery to “Allow background activity”.';
  }
  if (s.huawei) {
    return 'Huawei / Honor: allow “Lock screen notifications” and set Byte to “Manage manually” in App launch so it can run in the background.';
  }
  return 'If the player doesn\'t show on your phone, allow Byte to show on the lock screen and to run in the background (battery “unrestricted”).';
}

/// The lock-screen player inside the app, driven by the real player.
class LockScreenPreview extends StatefulWidget {
  const LockScreenPreview({super.key});
  @override
  State<LockScreenPreview> createState() => _LockScreenPreviewState();
}

class _LockScreenPreviewState extends State<LockScreenPreview> {
  late final HandlerLockPlayer _player = HandlerLockPlayer(Services.i.player, route: Services.i.route);

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).maybePop();
    return Scaffold(
      backgroundColor: Colors.black,
      body: LockScreenView(player: _player, onUnlock: close, onHide: close, image: (u) => networkImage(u)),
    );
  }
}

/// Settings → Playback row value.
String lockScreenRowValue() => Services.i.settings.lockScreenPlayer ? 'On' : 'Off';

bool get lockScreenSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
